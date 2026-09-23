import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http_parser/http_parser.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../db/database.dart';
import '../outbox/outbox.dart';
import 'image_pipeline.dart';

/// Two-phase upload: binary first, intent second.
///
/// The intent is a few hundred bytes and lands on the worst signal; the image
/// retries on its own. Never inline a photo into an intent body.
class UploadRepository {
  UploadRepository(this._db, this._api);

  final AppDatabase _db;
  final ApiClient _api;
  static const _uuid = Uuid();

  Database get _handle => _db.db;

  /// Stage a captured page locally. Nothing leaves the phone yet.
  ///
  /// [pageIndex] carries the order the intent will quote them in. A signature
  /// uses -1 so it sorts ahead of the optional photos and is easy to find.
  Future<UploadItem> stage(File file, {int pageIndex = 0}) async {
    final item = UploadItem(
      localId: _uuid.v4(),
      filePath: file.path,
      bytes: await file.length(),
      createdAt: DateTime.now(),
      sha256: await ImagePipeline.digest(file),
      pageIndex: pageIndex,
    );
    await _handle.insert('uploads', item.toRow());
    return item;
  }

  Future<void> discard(String localId) async {
    final rows =
        await _handle.query('uploads', where: 'local_id = ?', whereArgs: [localId], limit: 1);
    if (rows.isNotEmpty) {
      await _deleteFile(UploadItem.fromRow(rows.first));
    }
    await _handle.delete('uploads', where: 'local_id = ?', whereArgs: [localId]);
  }

  Future<List<UploadItem>> forIntent(String intentLocalId) async {
    final rows = await _handle.query(
      'uploads',
      where: 'intent_local_id = ?',
      whereArgs: [intentLocalId],
      orderBy: 'page_index ASC, created_at ASC',
    );
    return rows.map(UploadItem.fromRow).toList();
  }

  Future<List<UploadItem>> unattached() async {
    final rows = await _handle.query(
      'uploads',
      where: 'intent_local_id IS NULL',
      orderBy: 'page_index ASC, created_at ASC',
    );
    return rows.map(UploadItem.fromRow).toList();
  }

  Future<void> save(UploadItem item) async {
    await _handle
        .update('uploads', item.toRow(), where: 'local_id = ?', whereArgs: [item.localId]);
  }

  /// Send one staged page. Returns the item with its server `reference`.
  ///
  /// Throws [ApiError]; the caller decides retry-versus-drop.
  Future<UploadItem> push(UploadItem item) async {
    final file = File(item.filePath);
    if (!file.existsSync()) {
      final dead = item.copyWith(
        state: UploadState.failed,
        lastError: 'The photo is no longer on this phone.',
      );
      await save(dead);
      throw ApiError(
        code: ApiError.validation,
        message: 'The photo is no longer on this phone.',
        retryable: false,
      );
    }

    await save(item.copyWith(state: UploadState.uploading));

    final form = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        filename: 'page-${item.pageIndex < 0 ? 'signature' : item.pageIndex}.jpg',
        contentType: MediaType('image', 'jpeg'),
      ),
    });

    final response = await _api.post<Map<String, dynamic>>('/uploads', body: form);
    final data = response.data ?? const {};
    final reference = '${data['reference'] ?? ''}';
    final serverDigest = data['sha256'] as String?;

    // The digest is proof the bytes arrived intact. Only then is the local copy
    // expendable — and even then it stays until the *intent* is acked, because
    // an unconsumed upload is collected server-side after seven days.
    if (serverDigest != null && item.sha256 != null && serverDigest != item.sha256) {
      final bad = item.copyWith(
        state: UploadState.failed,
        lastError: 'The upload did not arrive intact.',
      );
      await save(bad);
      throw ApiError(
        code: ApiError.server,
        message: 'The upload did not arrive intact.',
        retryable: true,
      );
    }

    final done = item.copyWith(reference: reference, state: UploadState.uploaded);
    await save(done);
    return done;
  }

  /// Called once the intent that quoted these is acknowledged.
  Future<void> releaseForIntent(String intentLocalId) async {
    for (final item in await forIntent(intentLocalId)) {
      await _deleteFile(item);
    }
    await _handle
        .delete('uploads', where: 'intent_local_id = ?', whereArgs: [intentLocalId]);
  }

  Future<void> _deleteFile(UploadItem item) async {
    try {
      final file = File(item.filePath);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // A leftover file is a housekeeping problem, never a failed delivery.
    }
  }
}
