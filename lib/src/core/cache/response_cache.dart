import 'dart:typed_data';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../db/database.dart';
import '../store/kv_store.dart';

/// The last answer to every GET, so each screen still opens with no signal:
/// it shows the saved copy at once and swaps in the server's answer when it
/// lands. One account at a time -- cleared at sign-in and wiped at sign-out.
class ResponseCache {
  ResponseCache(this._store);

  final KvStore _store;

  /// The query is part of the key, in a stable order: the productivity of one
  /// week is not the productivity of another.
  static String keyFor(String path, [Map<String, Object?>? query]) {
    final q = (query == null || query.isEmpty)
        ? ''
        : '?${(query.keys.toList()..sort()).map((k) => '$k=${query[k]}').join('&')}';
    return 'cache/$path$q';
  }

  Future<void> put(String path, Object? data, {Map<String, Object?>? query, String? etag}) =>
      _store.writeJson(keyFor(path, query), {
        'at': DateTime.now().toUtc().toIso8601String(),
        'data': data,
        'etag': ?etag,
      });

  /// The validator the server sent with the saved answer, for `If-None-Match`.
  Future<String?> etag(String path, {Map<String, Object?>? query}) async =>
      (await _store.readJson(keyFor(path, query)))?['etag'] as String?;

  Future<CachedResponse?> get(String path, {Map<String, Object?>? query}) async {
    final j = await _store.readJson(keyFor(path, query));
    if (j == null || !j.containsKey('data')) return null;
    final at = DateTime.tryParse('${j['at']}') ?? DateTime.fromMillisecondsSinceEpoch(0);
    return CachedResponse(j['data'], at.toLocal());
  }

  Future<void> remove(String path, {Map<String, Object?>? query}) =>
      _store.delete(keyFor(path, query));

  Future<void> clear() => _store.deletePrefix('cache/');
}

class CachedResponse {
  const CachedResponse(this.data, this.at);

  final Object? data;

  /// When the server gave this answer.
  final DateTime at;
}

/// Jangad page images: a customer's handwritten slip, so they are kept in the
/// encrypted database and never in a shared image cache on disk. The most
/// recent [keep] pages stay; older ones make room.
class PageCache {
  PageCache(this._db, {this.keep = 80});

  final AppDatabase _db;
  final int keep;

  Database get _handle => _db.db;

  static String keyFor(int pickingId, int page) => 'page/$pickingId/$page';

  Future<Uint8List?> get(int pickingId, int page) async {
    if (!_db.isOpen) return null;
    final rows = await _handle.query(
      'blobs',
      columns: ['data'],
      where: 'key = ?',
      whereArgs: [keyFor(pickingId, page)],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final data = rows.first['data'];
    if (data is Uint8List) return data;
    if (data is List<int>) return Uint8List.fromList(data);
    return null;
  }

  Future<void> put(int pickingId, int page, Uint8List bytes) async {
    if (!_db.isOpen) return;
    await _handle.insert(
      'blobs',
      {
        'key': keyFor(pickingId, page),
        'data': bytes,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _handle.rawDelete(
      'DELETE FROM blobs WHERE key LIKE ? AND key NOT IN '
      '(SELECT key FROM blobs WHERE key LIKE ? ORDER BY updated_at DESC LIMIT ?)',
      ['page/%', 'page/%', keep],
    );
  }
}
