import 'dart:async';
import 'dart:io';

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
  AppDatabase(this._tokens, {Future<Database> Function()? opener}) : _opener = opener;

  /// A database somebody else already opened -- tests hand in an in-memory
  /// SQLite built with [configure], [create] and [upgrade].
  AppDatabase.withDatabase(Database db)
      : _tokens = null,
        _opener = null,
        _db = db;

  static const int schemaVersion = 2;

  final TokenStore? _tokens;
  final Future<Database> Function()? _opener;
  Database? _db;

  Database get db {
    final handle = _db;
    if (handle == null) {
      throw StateError('AppDatabase.open() has not completed');
    }
    return handle;
  }

  bool get isOpen => _db != null;

  /// Set when [open] found a file it could not decrypt and started a new one:
  /// whatever the phone held is gone, so the session must start over too.
  bool recovered = false;

  Future<Database> open() async {
    if (_db != null) return _db!;
    final opener = _opener;
    if (opener != null) return _db = await opener();
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'sudi.db');
    Future<Database> attempt() async => openDatabase(
          path,
          password: await _tokens!.databaseKey(DeviceIdentity.newDatabaseKey),
          version: schemaVersion,
          onConfigure: configure,
          onCreate: create,
          onUpgrade: upgrade,
        );
    try {
      return _db = await attempt();
    } on DatabaseException catch (e) {
      // A file this key cannot open (an earlier sign-out dropped the key while
      // keeping the file, or storage was damaged) used to fail before the
      // first frame: a blank screen on every launch until the app's data was
      // cleared by hand. Its contents are unreadable either way, so start a
      // new one under a new key; Services sends the person back to sign-in.
      if (!e.isOpenFailedError() && !'$e'.contains('not a database')) rethrow;
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final f = File('$path$suffix');
        if (f.existsSync()) f.deleteSync();
      }
      await _tokens!.forgetDatabaseKey();
      recovered = true;
      return _db = await attempt();
    }
  }

  static Future<void> configure(Database d) => d.execute('PRAGMA foreign_keys = ON');

  static Future<void> create(Database d, int version) async {
    final batch = d.batch();
    for (final statement in _schemaV1) {
      batch.execute(statement);
    }
    for (var v = 2; v <= version; v++) {
      for (final statement in _migrations[v] ?? const <String>[]) {
        batch.execute(statement);
      }
    }
    await batch.commit(noResult: true);
  }

  static Future<void> upgrade(Database d, int from, int to) async {
    final batch = d.batch();
    for (var v = from + 1; v <= to; v++) {
      for (final statement in _migrations[v] ?? const <String>[]) {
        batch.execute(statement);
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// `full_resync` and sign-out. Records go; **the outbox and staged uploads
  /// stay** — a resync is the server catching us up on reads, not permission
  /// to throw away work the operator captured.
  Future<void> clearScope(String scope) async {
    await db.delete(tableForScope(scope));
  }

  Future<void> clearAllRecords() async {
    final batch = db.batch();
    for (final table in recordTables) {
      batch.delete(table);
    }
    // The cursor goes with them: a full resync starts from nothing, and a
    // stale cursor is exactly what caused it.
    batch.update('sync', {'cursor': null, 'etag': null}, where: 'scope = ?', whereArgs: ['_all']);
    await batch.commit(noResult: true);
  }

  /// Device revoked, or an explicit sign-out: everything goes -- except the
  /// clock anchor, which says nothing about anybody and keeps the next
  /// sign-in's first capture correctly dated.
  Future<void> wipe() async {
    final batch = db.batch();
    for (final table in [
      ...recordTables,
      'jangads',
      'outbox',
      'uploads',
      'sync',
      'blobs',
    ]) {
      batch.delete(table);
    }
    batch.delete('kv', where: "substr(key, 1, 6) != 'clock/'");
    await batch.commit(noResult: true);
  }

  static const recordTables = ['pickups', 'deliveries', 'jobwork', 'office'];

  static String tableForScope(String scope) => switch (scope) {
        'pickup' => 'pickups',
        'delivery' => 'deliveries',
        'jobwork' => 'jobwork',
        'office' => 'office',
        _ => throw ArgumentError('Unknown scope $scope'),
      };

  static const List<String> _schemaV1 = [
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

  /// Applied in order on top of v1, on a fresh install and on an upgrade alike.
  static const Map<int, List<String>> _migrations = {
    2: [
      // One chain per record: a multi-record intent (take) names every record
      // it touches, an on-behalf jangad and the confirm chained after it share
      // an explicit chain, and the confirm waits on the jangad (depends_on).
      "ALTER TABLE outbox ADD COLUMN record_ids TEXT NOT NULL DEFAULT '[]'",
      'ALTER TABLE outbox ADD COLUMN chain TEXT',
      'ALTER TABLE outbox ADD COLUMN depends_on TEXT',
      // What the screens draw for an intent that has no record yet (the
      // customer and services of a jangad posted offline). Never sent.
      "ALTER TABLE outbox ADD COLUMN meta TEXT NOT NULL DEFAULT '{}'",
      // Capture order, independent of any clock: a re-pinned clock must not
      // reorder two taps.
      'ALTER TABLE outbox ADD COLUMN seq INTEGER NOT NULL DEFAULT 0',
      'CREATE INDEX idx_outbox_seq ON outbox (seq, created_at)',
      // Scope `office`: collected jangads awaiting validation.
      '''
      CREATE TABLE office (
        id INTEGER PRIMARY KEY,
        rev INTEGER NOT NULL,
        payload TEXT NOT NULL,
        name TEXT,
        customer_name TEXT,
        collected_at TEXT
      )''',
      // The customer's services, kept with their submission.
      'ALTER TABLE jangads ADD COLUMN services TEXT',
      // Clock anchor, resume point, drafts, the saved copy of every GET.
      '''
      CREATE TABLE kv (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )''',
      // Jangad page images, kept encrypted here rather than in an image cache.
      '''
      CREATE TABLE blobs (
        key TEXT PRIMARY KEY,
        data BLOB NOT NULL,
        updated_at TEXT NOT NULL
      )''',
    ],
  };
}
