import 'dart:async';
import 'dart:math';

import '../api/api_client.dart';
import '../api/api_error.dart';
import '../clock/server_clock.dart';
import '../db/records_dao.dart';
import '../uploads/upload_repository.dart';
import 'outbox.dart';
import 'outbox_repository.dart';

/// Replays the outbox.
///
/// Two properties matter more than anything else here:
///
/// * **Serial per record, parallel across records.** Two intents on delivery
///   1234 go in capture order; delivery 1235 is not blocked behind them. A
///   conflict stops *that record's* chain only.
/// * **The idempotency key is reused on every retry, forever.** It is minted at
///   capture and lives in the outbox row; nothing in this file generates one.
class OutboxFlusher {
  OutboxFlusher({
    required ApiClient api,
    required OutboxRepository outbox,
    required UploadRepository uploads,
    required RecordsDao records,
    required ServerClock clock,
    required this.myUserId,
  })  : _api = api,
        _outbox = outbox,
        _uploads = uploads,
        _records = records,
        _clock = clock;

  final ApiClient _api;
  final OutboxRepository _outbox;
  final UploadRepository _uploads;
  final RecordsDao _records;
  final ServerClock _clock;
  final int? Function() myUserId;

  bool _running = false;

  /// Fired whenever a row changes state, so the UI can re-read.
  void Function()? onChanged;

  /// Ids the server told us to re-pull after a conflict.
  final Set<int> pendingResync = {};

  Future<void> flush() async {
    if (_running) return;
    _running = true;
    try {
      await _outbox.expireStale();
      final now = _clock.now();
      final due = (await _outbox.open()).where((item) {
        if (!item.isWaiting) return false;
        final next = item.nextAttemptAt;
        return next == null || !next.isAfter(now);
      }).toList();

      if (due.isEmpty) {
        onChanged?.call();
        return;
      }

      final chains = <String, List<OutboxItem>>{};
      for (final item in due) {
        (chains[item.chainKey] ??= []).add(item);
      }

      await Future.wait(chains.values.map(_flushChain));
    } finally {
      _running = false;
      onChanged?.call();
    }
  }

  Future<void> _flushChain(List<OutboxItem> chain) async {
    for (final item in chain) {
      final keepGoing = await _flushOne(item);
      if (!keepGoing) return;
    }
  }

  /// Returns whether this record's chain may continue.
  Future<bool> _flushOne(OutboxItem item) async {
    await _outbox.save(item.copyWith(state: OutboxState.sending));
    onChanged?.call();

    Map<String, dynamic> body;
    try {
      body = await _resolveUploads(item);
    } on ApiError catch (e) {
      await _record(item, e);
      return false;
    }

    try {
      final response = await _api.post<Map<String, dynamic>>(
        _routeFor(item),
        body: body,
        idempotencyKey: item.idemKey,
      );
      await _succeed(item, response.data ?? const {});
      return true;
    } on ApiError catch (e) {
      if (e.isReplay) {
        // A retry that found its own earlier effect. That is a success, and
        // the client must not special-case it into a failure.
        await _succeed(item, e.detail);
        return true;
      }
      await _record(item, e);
      return e.retryable ? false : !_stopsChain(e);
    } catch (e) {
      await _record(
        item,
        ApiError(code: ApiError.server, message: '$e', retryable: true),
      );
      return false;
    }
  }

  /// A lost race or a refusal stops the chain for that record: anything queued
  /// behind it was written against a world that no longer exists.
  bool _stopsChain(ApiError e) =>
      e.isLostRace || e.code == ApiError.notInScope || e.code == ApiError.staleIntent;

  /// An intent may depend on an upload, and the upload goes first.
  ///
  /// Offline there is no `reference` for a signature, because references only
  /// exist once `POST /uploads` succeeds. So the outbox holds the image as an
  /// upload task and the intent names it locally; here we send the upload, take
  /// the reference, and patch it into the body.
  Future<Map<String, dynamic>> _resolveUploads(OutboxItem item) async {
    final staged = await _uploads.forIntent(item.localId);
    if (staged.isEmpty) return item.body;

    final resolved = <UploadItem>[];
    for (final upload in staged) {
      if (upload.state == UploadState.uploaded && upload.reference != null) {
        resolved.add(upload);
        continue;
      }
      resolved.add(await _uploads.push(upload));
    }

    final signature = resolved.where((u) => u.pageIndex < 0).firstOrNull;
    final pages = resolved.where((u) => u.pageIndex >= 0).toList()
      ..sort((a, b) => a.pageIndex.compareTo(b.pageIndex));

    return {
      ...item.body,
      if (pages.isNotEmpty) 'upload_ids': [for (final p in pages) p.reference],
      if (signature?.reference != null) 'signature_upload_id': signature!.reference,
    };
  }

  String _routeFor(OutboxItem item) => switch (item.kind) {
        IntentKind.confirmPickup => '/pickups/${item.recordId}/confirm',
        IntentKind.cancelPickup => '/pickups/${item.recordId}/cancel',
        IntentKind.takeDeliveries => '/deliveries/take',
        IntentKind.releaseDelivery => '/deliveries/${item.recordId}/release',
        IntentKind.markDelivered => '/deliveries/${item.recordId}/deliver',
        IntentKind.timer => '/jobwork/${item.recordId}/timer',
        IntentKind.department => '/jobwork/${item.recordId}/department',
        IntentKind.submitJangad => '/jangad',
      };

  String _scopeFor(IntentKind kind) => switch (kind) {
        IntentKind.confirmPickup || IntentKind.cancelPickup => 'pickup',
        IntentKind.takeDeliveries ||
        IntentKind.releaseDelivery ||
        IntentKind.markDelivered =>
          'delivery',
        IntentKind.timer || IntentKind.department => 'jobwork',
        IntentKind.submitJangad => 'jangad',
      };

  Future<void> _succeed(OutboxItem item, Map<String, dynamic> payload) async {
    final scope = _scopeFor(item.kind);

    // Every single-record intent answers with the updated document, so the
    // local row is replaced without waiting for the next pull.
    final record = payload['record'];
    if (record is Map) {
      await _records.applyIntentRecord(
        scope,
        Map<String, dynamic>.from(record),
        myUserId: myUserId(),
      );
    }

    // `take` is the one multi-record intent, and a partial result is normal.
    final taken = payload['taken'];
    if (taken is List && taken.isNotEmpty) {
      await _records.upsertDeliveries(
        taken.whereType<Map>().map((m) => Map<String, dynamic>.from(m)).toList(),
        myUserId: myUserId(),
      );
    }
    final failed = payload['failed'];
    if (failed is List && failed.isNotEmpty) {
      final first = Map<String, dynamic>.from(failed.first as Map);
      pendingResync.addAll(
        failed.whereType<Map>().map((m) => (m['id'] as num?)?.toInt() ?? 0).where((v) => v != 0),
      );
      // Not an error dialog: information the operator has to see, because they
      // may already have put the parcel in their bag.
      await _outbox.save(item.copyWith(
        state: OutboxState.needsAttention,
        lastErrorCode: '${first['code'] ?? ApiError.alreadyTaken}',
        lastErrorMessage: failed.length == 1
            ? '${first['message'] ?? 'Someone else took it.'}'
            : '${failed.length} of these were taken by somebody else.',
      ));
      onChanged?.call();
      return;
    }

    if (item.kind == IntentKind.submitJangad) {
      await _recordJangadReference(item, payload);
    }

    await _uploads.releaseForIntent(item.localId);
    await _outbox.remove(item.localId);
    onChanged?.call();
  }

  Future<void> _recordJangadReference(OutboxItem item, Map<String, dynamic> payload) async {
    final reference = payload['reference'];
    if (reference == null) return;
    await _records.updateJangadReference(item.localId, '$reference');
  }

  Future<void> _record(OutboxItem item, ApiError error) async {
    pendingResync.addAll(error.resync);

    // The server sends `AUTH` with `retryable: false`, which is right for a
    // login attempt and wrong for a queued intent: the interceptor already
    // tried a refresh, so reaching here means "no session right now" — almost
    // always no signal. Treating it as permanent would throw away a morning's
    // work over an expired token, so it waits and tries again instead.
    final shouldRetry = error.retryable || error.code == ApiError.auth;

    if (shouldRetry) {
      final attempts = item.attempts + 1;
      await _outbox.save(item.copyWith(
        state: OutboxState.retrying,
        attempts: attempts,
        nextAttemptAt: _clock.now().add(_backoff(attempts)),
        lastErrorCode: error.code,
        lastErrorMessage: error.message,
      ));
    } else {
      // Never dropped silently: it becomes a visible item the operator can
      // read and dismiss.
      await _outbox.save(item.copyWith(
        state: OutboxState.needsAttention,
        attempts: item.attempts + 1,
        lastErrorCode: error.code,
        lastErrorMessage: error.message,
      ));
    }
    onChanged?.call();
  }

  static final _jitter = Random();

  static Duration _backoff(int attempts) {
    final base = min(pow(2, attempts).toInt(), 300);
    final jitterMs = _jitter.nextInt(1000);
    return Duration(seconds: base, milliseconds: jitterMs);
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
