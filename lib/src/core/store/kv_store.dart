import 'dart:convert';

import 'package:sqflite_sqlcipher/sqflite.dart';

import '../db/database.dart';

/// Small key -> text store: the clock anchor, the resume point, form drafts and
/// the saved copy of every GET.
///
/// It lives in the encrypted database rather than in loose files, because what
/// goes in it is customer data -- a directory of names and phone numbers, the
/// half-filled confirm form of a parcel -- and a lost phone must not hand that
/// over. Keys are paths (`draft/confirm_pickup:42`), so a prefix is a folder.
abstract class KvStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Keys under [prefix], sorted.
  Future<List<String>> keys(String prefix);

  Future<void> deletePrefix(String prefix) async {
    for (final key in await keys(prefix)) {
      await delete(key);
    }
  }

  Future<Map<String, dynamic>?> readJson(String key) async {
    final text = await read(key);
    if (text == null) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      // A value written by a crash halfway through: treat it as missing.
      return null;
    }
  }

  Future<void> writeJson(String key, Object? json) => write(key, jsonEncode(json));
}

class SqlKvStore extends KvStore {
  SqlKvStore(this._db);

  final AppDatabase _db;
  Database get _handle => _db.db;

  @override
  Future<String?> read(String key) async {
    if (!_db.isOpen) return null;
    final rows = await _handle.query(
      'kv',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  @override
  Future<void> write(String key, String value) async {
    if (!_db.isOpen) return;
    await _handle.insert(
      'kv',
      {'key': key, 'value': value, 'updated_at': DateTime.now().toUtc().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String key) async {
    if (!_db.isOpen) return;
    await _handle.delete('kv', where: 'key = ?', whereArgs: [key]);
  }

  @override
  Future<List<String>> keys(String prefix) async {
    if (!_db.isOpen) return const [];
    // substr rather than LIKE: a key may legitimately contain `_` or `%`.
    final rows = await _handle.query(
      'kv',
      columns: ['key'],
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [prefix.length, prefix],
      orderBy: 'key ASC',
    );
    return [for (final row in rows) row['key'] as String];
  }

  @override
  Future<void> deletePrefix(String prefix) async {
    if (!_db.isOpen) return;
    await _handle.delete(
      'kv',
      where: 'substr(key, 1, ?) = ?',
      whereArgs: [prefix.length, prefix],
    );
  }
}

/// For tests, and for anything that must work before the database is open.
class MemoryKvStore extends KvStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<List<String>> keys(String prefix) async =>
      data.keys.where((k) => k.startsWith(prefix)).toList()..sort();
}
