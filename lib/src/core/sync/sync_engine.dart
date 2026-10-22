import 'dart:async';

import 'package:dio/dio.dart';

import '../../config/env.dart';
import '../api/api_client.dart';
import '../api/api_error.dart';
import '../clock/odoo_time.dart';
import '../clock/trusted_clock.dart';
import '../db/database.dart';
import '../db/records_dao.dart';

class SyncOutcome {
  const SyncOutcome({
    required this.changed,
    required this.notModified,
    this.fullResync = false,
    this.error,
    this.touched = const {},
  });

  final bool changed;
  final bool notModified;
  final bool fullResync;
  final ApiError? error;

  /// Every record id this pull upserted or removed.
  final Set<int> touched;
}

/// The read side.
///
/// `scopes` is deliberately omitted from the request: that means "every scope
/// my roles allow", and naming a scope the token does not hold is a 403 rather
/// than an empty answer.
class SyncEngine {
  SyncEngine({
    required ApiClient api,
    required AppDatabase db,
    required RecordsDao records,
    required TrustedClock clock,
    required int? Function() myUserId,
  })  : _api = api,
        _db = db,
        _records = records,
        _clock = clock,
        _myUserId = myUserId;

  final ApiClient _api;
  final AppDatabase _db;
  final RecordsDao _records;
  final TrustedClock _clock;
  final int? Function() _myUserId;

  static const _cursorScope = '_all';
  static const scopes = ['pickup', 'delivery', 'jobwork', 'office'];

  bool _running = false;
  int _consecutiveNotModified = 0;

  /// Back off to five minutes after a run of 304s, per brief section 6.3. Read
  /// afresh before every poll, so the back-off takes effect at the next one.
  Duration get pollInterval =>
      _consecutiveNotModified >= 3 ? Env.pollIntervalBackedOff : Env.pollInterval;

  /// This phone just changed something: whatever the 304 run said, the next
  /// pull has news (that change, and anything it moved between worklists).
  void noteLocalChange() => _consecutiveNotModified = 0;

  /// [resyncIds]: records the server told us (on an error or a partial take)
  /// to re-pull right away. The pull has no per-record form, so a non-empty set
  /// means this pull goes out without `If-None-Match`: a 304 must not hide the
  /// change that made the server name them.
  Future<SyncOutcome> pull({Set<int> resyncIds = const {}}) async {
    if (_running) {
      return const SyncOutcome(changed: false, notModified: true);
    }
    _running = true;
    try {
      return await _pullLoop(forceFresh: resyncIds.isNotEmpty);
    } on ApiError catch (e) {
      return SyncOutcome(changed: false, notModified: false, error: e);
    } finally {
      _running = false;
    }
  }

  Future<SyncOutcome> _pullLoop({required bool forceFresh}) async {
    final row = await _records.syncRow(_cursorScope);
    var cursor = row?['cursor'] as String?;
    final etag = forceFresh ? null : row?['etag'] as String?;

    String? afterScope;
    int? afterId;
    var changed = false;
    var sawFullResync = false;
    String? nextEtag;
    String? nextCursor;
    final touched = <int>{};

    // `has_more` means "call again immediately"; one response is not the world.
    for (var page = 0; page < 200; page++) {
      final isContinuation = afterScope != null || afterId != null;
      final before = await _clock.reading();
      final response = await _api.get<Map<String, dynamic>>(
        '/sync/pull',
        query: {
          'cursor': ?cursor,
          'limit': Env.syncPageLimit,
          'after_scope': ?afterScope,
          'after_id': ?afterId,
        },
        // Only an incremental first page may be answered with a 304. A 304 in
        // place of a full resync would leave a freshly wiped phone empty.
        headers: (etag != null && !isContinuation && !sawFullResync)
            ? {'If-None-Match': etag}
            : null,
      );
      final after = await _clock.reading();

      if (response.statusCode == 304) {
        _consecutiveNotModified++;
        await _records.touchPulled(_cursorScope);
        return const SyncOutcome(changed: false, notModified: true);
      }
      _consecutiveNotModified = 0;

      final data = response.data ?? const <String, dynamic>{};

      // `GET /time` is the anchor; this is the fallback for a phone that has
      // not managed to pin since it restarted.
      final serverTime = OdooTime.parse(data['server_time']);
      if (serverTime != null && !_clock.pinned) {
        await _clock.pin(serverTime, before, after);
      }

      final fullResync = data['full_resync'] == true;
      if (fullResync && !sawFullResync) {
        // One code path, no clever repair: wipe and pull from nothing.
        sawFullResync = true;
        await _db.clearAllRecords();
        changed = true;
      }

      final parts = data['scopes'];
      if (parts is Map) {
        for (final scope in scopes) {
          final part = parts[scope];
          if (part is! Map) continue;
          final upserts = ((part['upserts'] as List?) ?? const [])
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList();
          final gone = ((part['gone'] as List?) ?? const [])
              .map((v) => (v as num?)?.toInt() ?? 0)
              .where((v) => v != 0)
              .toList();

          if (upserts.isNotEmpty) {
            changed = true;
            touched.addAll(upserts.map((u) => (u['id'] as num?)?.toInt() ?? 0));
            switch (scope) {
              case 'pickup':
                await _records.upsertPickups(upserts);
              case 'delivery':
                await _records.upsertDeliveries(upserts, myUserId: _myUserId());
              case 'jobwork':
                await _records.upsertJobWork(upserts);
              case 'office':
                await _records.upsertOffice(upserts);
            }
          }
          if (gone.isNotEmpty) {
            changed = true;
            touched.addAll(gone);
            await _records.removeGone(scope, gone);
          }
        }
      }

      nextCursor = data['cursor']?.toString() ?? cursor;
      nextEtag = _etagOf(response);

      if (data['has_more'] != true) break;

      if (sawFullResync) {
        // Hand the SAME cursor back plus the keyset position, so a change
        // committed while we page is not skipped — it carries a higher id and
        // arrives on the next incremental pull.
        afterScope = data['next_after_scope'] as String?;
        afterId = (data['next_after_id'] as num?)?.toInt();
        if (afterScope == null && afterId == null) break;
      } else {
        // The cursor has already been advanced to the last change handed over.
        cursor = nextCursor;
        afterScope = null;
        afterId = null;
      }
    }

    // Store the cursor only once `has_more` is false.
    await _records.saveCursor(_cursorScope, cursor: nextCursor, etag: nextEtag);
    return SyncOutcome(
      changed: changed,
      notModified: false,
      fullResync: sawFullResync,
      touched: touched,
    );
  }

  String? _etagOf(Response<dynamic> response) {
    final values = response.headers.map['etag'] ?? response.headers.map['ETag'];
    return (values == null || values.isEmpty) ? null : values.first;
  }
}
