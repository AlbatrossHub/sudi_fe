import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../clock/trusted_clock.dart';
import '../db/database.dart';
import 'outbox.dart';

/// The only writer of user intent.
///
/// A screen never mutates `deliveries` or `pickups`; it appends here, and the
/// UI reads `cached record + pending intents for that record` as one derived
/// view. That is the difference between a queue you can reason about and a
/// cache you cannot.
class OutboxRepository {
  OutboxRepository(this._db, this._clock);

  final AppDatabase _db;
  final TrustedClock _clock;
  static const _uuid = Uuid();

  Database get _handle => _db.db;

  static const _order = 'seq ASC, created_at ASC';

  /// Capture. The idempotency key is minted here, once, and never again; the
  /// time comes from the trusted clock, read now.
  Future<OutboxItem> enqueue({
    required IntentKind kind,
    int? recordId,
    List<int> recordIds = const [],
    String? recordLabel,
    Map<String, dynamic> body = const {},
    List<String> uploadLocalIds = const [],
    String? chain,
    String? dependsOn,
    Map<String, dynamic> meta = const {},
  }) async {
    final stamp = await _clock.stamp();
    final localId = _uuid.v4();
    final seqRows = await _handle.rawQuery('SELECT COALESCE(MAX(seq), 0) + 1 AS n FROM outbox');
    final item = OutboxItem(
      localId: localId,
      kind: kind,
      recordId: recordId,
      recordIds: recordIds,
      recordLabel: recordLabel,
      // A jangad posted for a customer opens a chain of its own, so the confirm
      // taken straight after it can join it before either has a record id.
      chain: chain ?? (kind == IntentKind.submitOnBehalf ? 'local:$localId' : null),
      dependsOn: dependsOn,
      meta: meta,
      seq: (seqRows.first['n'] as num?)?.toInt() ?? 1,
      idemKey: _uuid.v4(),
      occurredAt: stamp.utc,
      createdAt: stamp.utc,
      body: {..._clock.envelopeFor(stamp), ...body},
    );
    await _handle.insert('outbox', item.toRow());
    if (uploadLocalIds.isNotEmpty) {
      final batch = _handle.batch();
      for (final id in uploadLocalIds) {
        batch.update(
          'uploads',
          {'intent_local_id': item.localId},
          where: 'local_id = ?',
          whereArgs: [id],
        );
      }
      await batch.commit(noResult: true);
    }
    return item;
  }

  Future<void> save(OutboxItem item) async {
    await _handle.update(
      'outbox',
      item.toRow(),
      where: 'local_id = ?',
      whereArgs: [item.localId],
    );
  }

  /// Removes the intent, its staged pages, and anything chained behind it that
  /// can now never go (a confirm waiting on a jangad that was dismissed).
  Future<void> remove(String localId) async {
    final dependents = await _handle.query(
      'outbox',
      columns: ['local_id'],
      where: 'depends_on = ? AND record_id IS NULL',
      whereArgs: [localId],
    );
    await _handle.delete('outbox', where: 'local_id = ?', whereArgs: [localId]);
    await _handle.delete('uploads', where: 'intent_local_id = ?', whereArgs: [localId]);
    for (final row in dependents) {
      await remove(row['local_id'] as String);
    }
  }

  Future<OutboxItem?> byId(String localId) async {
    final rows =
        await _handle.query('outbox', where: 'local_id = ?', whereArgs: [localId], limit: 1);
    return rows.isEmpty ? null : OutboxItem.fromRow(rows.first);
  }

  Future<List<OutboxItem>> all() async {
    final rows = await _handle.query('outbox', orderBy: _order);
    return rows.map(OutboxItem.fromRow).toList();
  }

  /// Everything still owed to the server, in capture order.
  Future<List<OutboxItem>> open() async {
    final rows = await _handle.query(
      'outbox',
      where: 'state != ?',
      whereArgs: [OutboxState.done.name],
      orderBy: _order,
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  Future<List<OutboxItem>> openOfKind(IntentKind kind) async {
    final rows = await _handle.query(
      'outbox',
      where: 'state != ? AND kind = ?',
      whereArgs: [OutboxState.done.name, kind.wire],
      orderBy: _order,
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  /// The intents chained behind [localId] (an on-behalf jangad's confirm).
  Future<List<OutboxItem>> dependentsOf(String localId) async {
    final rows = await _handle.query(
      'outbox',
      where: 'depends_on = ? AND state != ?',
      whereArgs: [localId, OutboxState.done.name],
      orderBy: _order,
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  /// The jangad behind [parentLocalId] landed and the server named its
  /// receipt: everything chained behind it now acts on that record, and joins
  /// that record's own chain.
  Future<int> attachDependents(String parentLocalId, int recordId) => _handle.update(
        'outbox',
        {'record_id': recordId, 'chain': null},
        where: 'depends_on = ? AND record_id IS NULL',
        whereArgs: [parentLocalId],
      );

  /// Boot. A row left in `sending` was cut off by a killed app mid-request;
  /// whether the server got it is unknown, and the idempotency key makes
  /// sending it again safe -- so it goes back in the queue. Left alone, it
  /// would never be retried: a flush only picks up pending and retrying rows.
  Future<int> recoverInterrupted() => _handle.update(
        'outbox',
        {'state': OutboxState.pending.name},
        where: 'state = ?',
        whereArgs: [OutboxState.sending.name],
      );

  Future<int> openCount() async {
    final rows = await _handle.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE state != ? AND kind != ?',
      [OutboxState.done.name, IntentKind.noticesRead.wire],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<int> attentionCount() async {
    final rows = await _handle.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE state = ?',
      [OutboxState.needsAttention.name],
    );
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  /// What the UI overlays on a cached record so the operator sees the world as
  /// they left it.
  Future<List<OutboxItem>> pendingFor(int recordId) async =>
      (await pendingByRecord())[recordId] ?? const [];

  /// Every open intent, under every record it touches -- a take of five
  /// parcels shows queued on all five.
  Future<Map<int, List<OutboxItem>>> pendingByRecord() async {
    final out = <int, List<OutboxItem>>{};
    for (final item in await open()) {
      for (final id in item.touchedIds) {
        (out[id] ??= []).add(item);
      }
    }
    return out;
  }

  /// An outbox row older than 72 h will never succeed, however good the signal
  /// becomes. Expire it loudly rather than letting it retry into the void.
  Future<int> expireStale() async {
    final items = await open();
    var expired = 0;
    for (final item in items) {
      if (item.state == OutboxState.needsAttention) continue;
      if (_clock.remainingFor(item.occurredAt) > Duration.zero) continue;
      await save(item.copyWith(
        state: OutboxState.needsAttention,
        lastErrorCode: 'STALE_INTENT',
        lastErrorMessage:
            'Captured more than three days ago. The office will not accept it now.',
      ));
      expired++;
    }
    return expired;
  }
}
