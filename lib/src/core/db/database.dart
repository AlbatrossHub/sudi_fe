import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

import '../auth/device_identity.dart';
import '../auth/token_store.dart';

/// The local store. It mirrors the sync payloads and nothing more — there is
/// no attempt to model `stock.picking` here.
///
/// Two rules hold the schema together:
///
/// 1. Keep the whole server payload as JSON and project only what list queries
///    actually filter or sort on. The payloads will grow; a migration per added
///    field is a tax we do not need.
/// 2. **The outbox is the only writer of user intent.** A screen never mutates
///    `deliveries` directly; it appends to `outbox`, and the UI reads
///    `cached record + pending intents for that record` as one derived view.
///
/// Encrypted with SQLCipher, key in secure storage. A lost operator phone
/// should not be a lost customer list.
class AppDatabase {
  AppDatabase(this._tokens);

  final TokenStore _tokens;
  Database? _db;

  Database get db {
    final handle = _db;
    if (handle == null) {
      throw StateError('AppDatabase.open() has not completed');
    }
    return handle;
  }

  bool get isOpen => _db != null;

  Future<Database> open() async {
    if (_db != null) return _db!;
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'sudi.db');
    final key = await _tokens.databaseKey(DeviceIdentity.newDatabaseKey);
    return _db = await openDatabase(
      path,
      password: key,
      version: 1,
      onConfigure: (d) => d.execute('PRAGMA foreign_keys = ON'),
      onCreate: (d, _) async {
        final batch = d.batch();
        for (final statement in _schema) {
          batch.execute(statement);
        }
        await batch.commit(noResult: true);
      },
    );
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// `full_resync` and sign-out. Records go; **the outbox and staged uploads
  /// stay** — a resync is the server catching us up on reads, not permission
  /// to throw away work the operator captured.
  Future<void> clearScope(String scope) async {
    await db.delete(_tableForScope(scope));
  }

  Future<void> clearAllRecords() async {
    final batch = db.batch();
    for (final table in ['pickups', 'deliveries', 'jobwork']) {
      batch.delete(table);
    }
    // The cursor and the clock offset go with them: a full resync starts from
    // nothing, and a stale cursor is exactly what caused it.
    batch.update('sync', {'cursor': null, 'etag': null}, where: 'scope = ?', whereArgs: ['_all']);
    await batch.commit(noResult: true);
  }

  /// Device revoked, or an explicit sign-out: everything goes.
  Future<void> wipe() async {
    final batch = db.batch();
    for (final table in [
      'pickups',
      'deliveries',
      'jobwork',
      'jangads',
      'outbox',
      'uploads',
      'sync',
    ]) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }

  static String _tableForScope(String scope) => switch (scope) {
        'pickup' => 'pickups',
        'delivery' => 'deliveries',
        'jobwork' => 'jobwork',
        _ => throw ArgumentError('Unknown scope $scope'),
      };

  static const List<String> _schema = [
    '''
    CREATE TABLE pickups (
      id INTEGER PRIMARY KEY,
      rev INTEGER NOT NULL,
      payload TEXT NOT NULL,
      name TEXT,
      stage TEXT,
      customer_name TEXT,
      scheduled_date TEXT,
      collected_at TEXT
    )''',
    'CREATE INDEX idx_pickups_stage ON pickups (stage, scheduled_date)',
    '''
    CREATE TABLE deliveries (
      id INTEGER PRIMARY KEY,
      rev INTEGER NOT NULL,
      payload TEXT NOT NULL,
      name TEXT,
      stage TEXT,
      customer_name TEXT,
      taken_by_me INTEGER NOT NULL DEFAULT 0,
      delivered_at TEXT
    )''',
    'CREATE INDEX idx_deliveries_stage ON deliveries (stage, taken_by_me)',
    '''
    CREATE TABLE jobwork (
      id INTEGER PRIMARY KEY,
      rev INTEGER NOT NULL,
      payload TEXT NOT NULL,
      name TEXT,
      customer_name TEXT,
      department TEXT,
      timer_running INTEGER NOT NULL DEFAULT 0,
      scheduled_date TEXT
    )''',
    'CREATE INDEX idx_jobwork_timer ON jobwork (timer_running)',
    '''
    CREATE TABLE jangads (
      local_id TEXT PRIMARY KEY,
      reference TEXT,
      pages TEXT NOT NULL,
      address TEXT,
      occurred_at TEXT NOT NULL,
      state TEXT NOT NULL,
      submitted_at TEXT
    )''',
    '''
    CREATE TABLE outbox (
      local_id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      record_id INTEGER,
      record_label TEXT,
      idem_key TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      body TEXT NOT NULL,
      upload_refs TEXT NOT NULL DEFAULT '[]',
      state TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      next_attempt_at TEXT,
      last_error TEXT
    )''',
    'CREATE INDEX idx_outbox_state ON outbox (state, record_id, created_at)',
    '''
    CREATE TABLE uploads (
      local_id TEXT PRIMARY KEY,
      file_path TEXT NOT NULL,
      sha256 TEXT,
      bytes INTEGER NOT NULL DEFAULT 0,
      reference TEXT,
      state TEXT NOT NULL,
      page_index INTEGER NOT NULL DEFAULT 0,
      intent_local_id TEXT,
      created_at TEXT NOT NULL,
      last_error TEXT
    )''',
    'CREATE INDEX idx_uploads_intent ON uploads (intent_local_id, page_index)',
    '''
    CREATE TABLE sync (
      scope TEXT PRIMARY KEY,
      cursor TEXT,
      etag TEXT,
      last_pulled_at TEXT,
      server_offset_ms INTEGER NOT NULL DEFAULT 0
    )''',
  ];
}
