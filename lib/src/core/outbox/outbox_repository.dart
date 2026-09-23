import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../clock/server_clock.dart';
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
  final ServerClock _clock;
  static const _uuid = Uuid();

  Database get _handle => _db.db;

  /// Capture. The idempotency key is minted here, once, and never again.
  Future<OutboxItem> enqueue({
    required IntentKind kind,
    int? recordId,
    String? recordLabel,
    Map<String, dynamic> body = const {},
    List<String> uploadLocalIds = const [],
  }) async {
    final now = _clock.now();
    final item = OutboxItem(
      localId: _uuid.v4(),
      kind: kind,
      recordId: recordId,
      recordLabel: recordLabel,
      idemKey: _uuid.v4(),
      occurredAt: now,
      createdAt: now,
      body: {..._clock.envelope(), ...body},
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

  Future<void> remove(String localId) async {
    await _handle.delete('outbox', where: 'local_id = ?', whereArgs: [localId]);
    await _handle.delete('uploads', where: 'intent_local_id = ?', whereArgs: [localId]);
  }

  Future<List<OutboxItem>> all() async {
    final rows = await _handle.query('outbox', orderBy: 'created_at ASC');
    return rows.map(OutboxItem.fromRow).toList();
  }

  /// Everything still owed to the server, oldest first.
  Future<List<OutboxItem>> open() async {
    final rows = await _handle.query(
      'outbox',
      where: 'state != ?',
      whereArgs: [OutboxState.done.name],
      orderBy: 'created_at ASC',
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  Future<int> openCount() async {
    final rows = await _handle.rawQuery(
      'SELECT COUNT(*) AS n FROM outbox WHERE state != ?',
      [OutboxState.done.name],
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
  Future<List<OutboxItem>> pendingFor(int recordId) async {
    final rows = await _handle.query(
      'outbox',
      where: 'record_id = ? AND state != ?',
      whereArgs: [recordId, OutboxState.done.name],
      orderBy: 'created_at ASC',
    );
    return rows.map(OutboxItem.fromRow).toList();
  }

  Future<Map<int, List<OutboxItem>>> pendingByRecord() async {
    final rows = await _handle.query(
      'outbox',
      where: 'record_id IS NOT NULL AND state != ?',
      whereArgs: [OutboxState.done.name],
      orderBy: 'created_at ASC',
    );
    final out = <int, List<OutboxItem>>{};
    for (final row in rows) {
      final item = OutboxItem.fromRow(row);
      (out[item.recordId!] ??= []).add(item);
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
