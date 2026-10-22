import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../../models/docs.dart';
import '../clock/odoo_time.dart';
import 'database.dart';

/// Reads and writes the cached worklists.
///
/// `upserts` are whole documents, so every write here is a replace -- but only
/// when the incoming `rev` is at least the stored one. `rev` rises
/// monotonically per record, so an older document arriving late (a slow intent
/// answer racing a pull, a replayed response) must never overwrite a newer one.
/// It is used only to drop an out-of-order write -- never to merge.
class RecordsDao {
  RecordsDao(this._db);

  final AppDatabase _db;
  Database get _handle => _db.db;

  /// `INSERT ... ON CONFLICT(id) DO UPDATE ... WHERE excluded.rev >= rev`.
  static void _upsert(Batch batch, String table, Map<String, Object?> row) {
    final columns = row.keys.toList();
    final updates = [
      for (final c in columns)
        if (c != 'id') '$c = excluded.$c',
    ].join(', ');
    batch.rawInsert(
      'INSERT INTO $table (${columns.join(', ')}) '
      'VALUES (${List.filled(columns.length, '?').join(', ')}) '
      'ON CONFLICT(id) DO UPDATE SET $updates '
      'WHERE excluded.rev >= $table.rev',
      [for (final c in columns) row[c]],
    );
  }

  // ---------------------------------------------------------------- pickups

  Future<void> upsertPickups(List<Map<String, dynamic>> docs) async {
    final batch = _handle.batch();
    for (final json in docs) {
      final doc = PickupDoc.fromJson(json);
      _upsert(batch, 'pickups', {
        'id': doc.id,
        'rev': doc.rev,
        'payload': jsonEncode(json),
        'name': doc.name,
        'stage': doc.stage,
        'customer_name': doc.customer?.name,
        'scheduled_date': doc.scheduledDate?.toIso8601String(),
        'collected_at': doc.collectedAt?.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<PickupDoc>> pickups({String? stage}) async {
    final rows = await _handle.query(
      'pickups',
      where: stage == null ? null : 'stage = ?',
      whereArgs: stage == null ? null : [stage],
      orderBy: 'scheduled_date ASC, id ASC',
    );
    return rows.map(_pickup).toList();
  }

  Future<PickupDoc?> pickup(int id) async {
    final rows = await _handle.query('pickups', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _pickup(rows.first);
  }

  PickupDoc _pickup(Map<String, Object?> row) =>
      PickupDoc.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>);

  // ------------------------------------------------------------- deliveries

  Future<void> upsertDeliveries(List<Map<String, dynamic>> docs, {int? myUserId}) async {
    final batch = _handle.batch();
    for (final json in docs) {
      final doc = DeliveryDoc.fromJson(json);
      _upsert(batch, 'deliveries', {
        'id': doc.id,
        'rev': doc.rev,
        'payload': jsonEncode(json),
        'name': doc.name,
        'stage': doc.stage,
        'customer_name': doc.customer?.name,
        'taken_by_me': (myUserId != null && doc.takenBy?.id == myUserId) ? 1 : 0,
        'delivered_at': doc.deliveredAt?.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<DeliveryDoc>> deliveries({String? stage, bool? mine}) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (stage != null) {
      clauses.add('stage = ?');
      args.add(stage);
    }
    if (mine != null) {
      clauses.add('taken_by_me = ?');
      args.add(mine ? 1 : 0);
    }
    final rows = await _handle.query(
      'deliveries',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'id ASC',
    );
    return rows.map(_delivery).toList();
  }

  Future<DeliveryDoc?> delivery(int id) async {
    final rows = await _handle.query('deliveries', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _delivery(rows.first);
  }

  DeliveryDoc _delivery(Map<String, Object?> row) =>
      DeliveryDoc.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>);

  // ---------------------------------------------------------------- jobwork

  Future<void> upsertJobWork(List<Map<String, dynamic>> docs) async {
    final batch = _handle.batch();
    for (final json in docs) {
      final doc = JobWorkDoc.fromJson(json);
      _upsert(batch, 'jobwork', {
        'id': doc.id,
        'rev': doc.rev,
        'payload': jsonEncode(json),
        'name': doc.name,
        'customer_name': doc.customer?.name,
        'department': doc.currentDepartment?.name,
        'timer_running': doc.timer.running ? 1 : 0,
        'scheduled_date': doc.scheduledDate?.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  Future<List<JobWorkDoc>> jobWork() async {
    final rows = await _handle.query('jobwork', orderBy: 'timer_running DESC, id ASC');
    return rows.map(_jobWork).toList();
  }

  Future<JobWorkDoc?> jobWorkOne(int id) async {
    final rows = await _handle.query('jobwork', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _jobWork(rows.first);
  }

  JobWorkDoc _jobWork(Map<String, Object?> row) =>
      JobWorkDoc.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>);

  // ----------------------------------------------------------------- office

  Future<void> upsertOffice(List<Map<String, dynamic>> docs) async {
    final batch = _handle.batch();
    for (final json in docs) {
      final doc = OfficeDoc.fromJson(json);
      _upsert(batch, 'office', {
        'id': doc.id,
        'rev': doc.rev,
        'payload': jsonEncode(json),
        'name': doc.name,
        'customer_name': doc.customer?.name,
        'collected_at': doc.collectedAt?.toIso8601String(),
      });
    }
    await batch.commit(noResult: true);
  }

  /// Oldest collection first: the office works the queue in arrival order.
  Future<List<OfficeDoc>> office() async {
    final rows = await _handle.query('office', orderBy: 'collected_at ASC, id ASC');
    return rows.map(_office).toList();
  }

  Future<OfficeDoc?> officeOne(int id) async {
    final rows = await _handle.query('office', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : _office(rows.first);
  }

  OfficeDoc _office(Map<String, Object?> row) =>
      OfficeDoc.fromJson(jsonDecode(row['payload'] as String) as Map<String, dynamic>);

  // -------------------------------------------------------------------- all

  /// A record that left the caller's scope must be deleted locally. Skip this
  /// and the phone accumulates work that no longer exists.
  Future<void> removeGone(String scope, List<int> ids) async {
    if (ids.isEmpty) return;
    final String table;
    try {
      table = AppDatabase.tableForScope(scope);
    } on ArgumentError {
      return;
    }
    final placeholders = List.filled(ids.length, '?').join(',');
    await _handle.delete(table, where: 'id IN ($placeholders)', whereArgs: ids);
  }

  /// The server said these are not ours any more (`NOT_IN_SCOPE`), and no pull
  /// brought them back: drop them from every worklist.
  Future<void> removeEverywhere(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    final placeholders = List.filled(list.length, '?').join(',');
    final batch = _handle.batch();
    for (final table in AppDatabase.recordTables) {
      batch.delete(table, where: 'id IN ($placeholders)', whereArgs: list);
    }
    await batch.commit(noResult: true);
  }

  /// A single-record intent answers with the updated document, so the local row
  /// can be replaced without waiting for the next pull.
  Future<void> applyIntentRecord(String scope, Map<String, dynamic> record, {int? myUserId}) {
    return switch (scope) {
      'pickup' => upsertPickups([record]),
      'delivery' => upsertDeliveries([record], myUserId: myUserId),
      'jobwork' => upsertJobWork([record]),
      'office' => upsertOffice([record]),
      _ => Future.value(),
    };
  }

  // ---------------------------------------------------------------- jangads

  /// The customer's own submissions. Offline there is no reference yet — the
  /// server mints it on `POST /jangad` — so the row is written at capture and
  /// filled in when the intent lands.
  Future<void> insertJangad({
    required String localId,
    required List<String> pages,
    required String address,
    required DateTime occurredAt,
    List<Map<String, dynamic>> services = const [],
  }) async {
    await _handle.insert('jangads', {
      'local_id': localId,
      'reference': null,
      'pages': jsonEncode(pages),
      'address': address,
      'occurred_at': occurredAt.toIso8601String(),
      'state': 'queued',
      'submitted_at': null,
      'services': jsonEncode(services),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> updateJangadReference(String localId, String reference) async {
    await _handle.update(
      'jangads',
      {
        'reference': reference,
        'state': 'sent',
        'submitted_at': DateTime.now().toIso8601String(),
      },
      where: 'local_id = ?',
      whereArgs: [localId],
    );
  }

  Future<List<Map<String, Object?>>> jangads() =>
      _handle.query('jangads', orderBy: 'occurred_at DESC');

  // ------------------------------------------------------------------- sync

  Future<Map<String, Object?>?> syncRow(String scope) async {
    final rows = await _handle.query('sync', where: 'scope = ?', whereArgs: [scope], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveCursor(String scope, {String? cursor, String? etag}) async {
    await _handle.insert(
      'sync',
      {
        'scope': scope,
        'cursor': cursor,
        'etag': etag,
        // Stamped with an offset, because `OdooTime.parse` reads a naive
        // string as UTC -- the server's wire format. A bare
        // `toIso8601String()` is naive *local*, so it came back 5h30m in the
        // future here, `ago()` saw a negative delta, and the strip said "just
        // now" forever.
        'last_pulled_at': OdooTime.stamp(DateTime.now()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> touchPulled(String scope) async {
    await _handle.update(
      'sync',
      {'last_pulled_at': OdooTime.stamp(DateTime.now())},
      where: 'scope = ?',
      whereArgs: [scope],
    );
  }

  Future<DateTime?> lastPulledAt() async {
    final rows = await _handle.query(
      'sync',
      columns: ['last_pulled_at'],
      orderBy: 'last_pulled_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return OdooTime.parse(rows.first['last_pulled_at'])?.toLocal() ??
        DateTime.tryParse('${rows.first['last_pulled_at']}');
  }
}
