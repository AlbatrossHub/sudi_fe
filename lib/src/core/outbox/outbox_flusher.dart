import 'dart:async';
import 'dart:math';

import '../../models/docs.dart';
import '../api/api_client.dart';
import '../api/api_error.dart';
import '../clock/trusted_clock.dart';
import '../db/records_dao.dart';
import '../store/kv_store.dart';
import '../uploads/upload_repository.dart';
import '../v2_repository.dart';
import 'outbox.dart';
import 'outbox_repository.dart';

/// Replays the outbox.
///
/// Three properties matter more than anything else here:
///
/// * **One chain per record, serial within it, parallel across chains.** A
///   confirm and a cancel on pickup 42 go in capture order whatever their
///   verbs; delivery 1235 is not blocked behind them. A take of five parcels
///   joins those five chains. A conflict stops *that chain* only.
/// * **A chain waits for its oldest intent.** If that one is backing off, the
///   ones behind it wait too -- sending them first would replay the operator's
///   taps out of order.
/// * **The idempotency key is reused on every retry, forever.** It is minted at
///   capture and lives in the outbox row; nothing in this file generates one.
class OutboxFlusher {
  OutboxFlusher({
    required ApiClient api,
    required OutboxRepository outbox,
    required UploadRepository uploads,
    required RecordsDao records,
    required TrustedClock clock,
    required this.myUserId,
    KvStore? store,
  })  : _api = api,
        _outbox = outbox,
        _uploads = uploads,
        _records = records,
        _clock = clock,
        _store = store;

  final ApiClient _api;
  final OutboxRepository _outbox;
  final UploadRepository _uploads;
  final RecordsDao _records;
  final TrustedClock _clock;
  final KvStore? _store;
  final int? Function() myUserId;

  Future<void>? _running;
  bool _again = false;
  bool _againIgnoringBackoff = false;

  /// Fired whenever a row changes state, so the UI can re-read.
  void Function()? onChanged;

  /// Ids the server told us to re-pull after a conflict (`resync` on the error
  /// envelope, the `failed` half of a take). Handed to the next pull.
  final Set<int> pendingResync = {};

  /// Ids the server said are not ours any more. Dropped locally unless the
  /// resync pull brings them back.
  final Set<int> notInScope = {};

  /// What the server answered for a jangad posted on a customer's behalf:
  /// `posted/<local id>` -> `{picking_id, reference}`, read by the "Posted"
  /// screen and by "Collect it now" once the receipt exists.
  static String postedKey(String localId) => 'posted/$localId';

  /// Hand over (and forget) the ids to re-pull.
  ({Set<int> resync, Set<int> notInScope}) takeResync() {
    final out = (resync: {...pendingResync, ...notInScope}, notInScope: {...notInScope});
    pendingResync.clear();
    notInScope.clear();
    return out;
  }

  /// Send what is due. Asked while a run is going, it runs once more
  /// afterwards, so an intent captured mid-run is never left behind.
  ///
  /// [ignoreBackoff]: the server just became reachable again, so everything
  /// waiting on a network failure goes now rather than at its next slot.
  Future<void> flush({bool ignoreBackoff = false}) {
    final running = _running;
    if (running != null) {
      _again = true;
      _againIgnoringBackoff = _againIgnoringBackoff || ignoreBackoff;
      return running;
    }
    final run = () async {
      var ignore = ignoreBackoff;
      do {
        _again = false;
        await _run(ignoreBackoff: ignore);
        ignore = _againIgnoringBackoff;
        _againIgnoringBackoff = false;
      } while (_again);
    }();
    _running = run.whenComplete(() {
      _running = null;
      onChanged?.call();
    });
    return _running!;
  }

  Future<void> _run({required bool ignoreBackoff}) async {
    await _outbox.expireStale();
    final open = await _outbox.open();
    if (!open.any((i) => i.isWaiting)) return;
    final now = _clock.now();
    await Future.wait(
      outboxChains(open).map((chain) => _flushChain(chain, now, ignoreBackoff)),
    );
  }

  bool _due(OutboxItem item, DateTime now, bool ignoreBackoff) {
    if (item.state == OutboxState.pending) return true;
    if (item.state != OutboxState.retrying) return false;
    final next = item.nextAttemptAt;
    return ignoreBackoff || next == null || !next.isAfter(now);
  }

  Future<void> _flushChain(List<OutboxItem> chain, DateTime now, bool ignoreBackoff) async {
    for (final snapshot in chain) {
      // Re-read: an earlier intent in this chain may have just filled in this
      // one's record id (an on-behalf jangad answering with its receipt).
      final item = await _outbox.byId(snapshot.localId);
      if (item == null || item.state == OutboxState.done) continue;
      // Refused for good: shown to the operator, and not in the way of the
      // intents behind it on later runs.
      if (item.state == OutboxState.needsAttention) continue;
      if (item.state == OutboxState.sending) return;
      if (!_due(item, now, ignoreBackoff)) return;
      final keepGoing = await _flushOne(item);
      if (!keepGoing) return;
    }
  }

  /// Returns whether this chain may continue.
  Future<bool> _flushOne(OutboxItem item) async {
    // Chained behind an intent that has not answered with a record id yet.
    if (item.dependsOn != null && item.recordId == null && _needsRecord(item.kind)) {
      final parent = await _outbox.byId(item.dependsOn!);
      if (parent == null || parent.state == OutboxState.needsAttention) {
        await _outbox.save(item.copyWith(
          state: OutboxState.needsAttention,
          lastErrorCode: 'DEPENDENCY',
          lastErrorMessage: 'The jangad it belongs to did not reach the office, so this '
              'cannot be sent. Collect it again once the jangad is in.',
        ));
        onChanged?.call();
      }
      return false;
    }

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

  static bool _needsRecord(IntentKind kind) => switch (kind) {
        IntentKind.submitJangad ||
        IntentKind.submitOnBehalf ||
        IntentKind.takeDeliveries ||
        IntentKind.noticesRead =>
          false,
        _ => true,
      };

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
        IntentKind.logTime => V2Paths.timesheets(item.recordId!),
        IntentKind.submitJangad => '/jangad',
        IntentKind.submitOnBehalf => V2Paths.onBehalfJangad,
        IntentKind.noticesRead => V2Paths.noticesRead,
      };

  String _scopeFor(IntentKind kind) => switch (kind) {
        IntentKind.confirmPickup || IntentKind.cancelPickup || IntentKind.submitOnBehalf =>
          'pickup',
        IntentKind.takeDeliveries ||
        IntentKind.releaseDelivery ||
        IntentKind.markDelivered =>
          'delivery',
        IntentKind.timer || IntentKind.department || IntentKind.logTime => 'jobwork',
        IntentKind.submitJangad => 'jangad',
        IntentKind.noticesRead => 'notice',
      };

  /// Intents the server accepted, ever. The sync controller compares it across
  /// a run to know that this phone itself just changed something.
  int landed = 0;

  Future<void> _succeed(OutboxItem item, Map<String, dynamic> payload) async {
    landed++;
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

    // A manual time entry answers with the receipt as it now stands.
    final jobwork = payload['jobwork'];
    if (item.kind == IntentKind.logTime && jobwork is Map) {
      await _records.upsertJobWork([Map<String, dynamic>.from(jobwork)]);
    }

    // A jangad posted for a customer answers with its receipt: the pickup
    // joins the list, and whatever was chained behind it (the confirm taken
    // straight after posting) now acts on that receipt.
    if (item.kind == IntentKind.submitOnBehalf) {
      final result = OnBehalfResult.from(payload);
      if (result != null) {
        if (result.pickup != null) await _records.upsertPickups([result.pickup!]);
        await _outbox.attachDependents(item.localId, result.pickingId);
        await _store?.writeJson(postedKey(item.localId), {
          'picking_id': result.pickingId,
          'reference': result.reference,
          // The outbox row goes once this lands; the "posted" and "collect it
          // now" screens still need to say what was posted, and when.
          'meta': item.meta,
          'occurred_at': item.occurredAt.toIso8601String(),
        });
      }
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
    if (error.code == ApiError.notInScope) notInScope.addAll(item.touchedIds);
    if (error.isLostRace) pendingResync.addAll(item.touchedIds);

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
