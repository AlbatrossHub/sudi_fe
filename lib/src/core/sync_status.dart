import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/flavor.dart';
import 'api/api_error.dart';
import 'notices/notices.dart';
import 'services.dart';
import 'session.dart';

/// The four things a person must always be able to see, without opening a menu
/// (brief section 4.3): the connection, when the last successful sync was, how
/// many intents are queued, and — one tap away — why each has not gone yet.
class SyncStatus {
  const SyncStatus({
    this.online = true,
    this.lastSyncedAt,
    this.queued = 0,
    this.needsAttention = 0,
    this.syncing = false,
    this.clockSkewed = false,
    this.clockSkewLabel,
  });

  /// The server answered the last request (and the radio is on).
  final bool online;
  final DateTime? lastSyncedAt;
  final int queued;
  final int needsAttention;
  final bool syncing;
  final bool clockSkewed;
  final String? clockSkewLabel;

  SyncStatus copyWith({
    bool? online,
    DateTime? lastSyncedAt,
    int? queued,
    int? needsAttention,
    bool? syncing,
    bool? clockSkewed,
    String? clockSkewLabel,
  }) =>
      SyncStatus(
        online: online ?? this.online,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        queued: queued ?? this.queued,
        needsAttention: needsAttention ?? this.needsAttention,
        syncing: syncing ?? this.syncing,
        clockSkewed: clockSkewed ?? this.clockSkewed,
        clockSkewLabel: clockSkewLabel ?? this.clockSkewLabel,
      );
}

/// A poll that reads its interval afresh before every tick.
///
/// `Timer.periodic` fixes the period when it is created, so the five-minute
/// back-off after a run of 304s never took effect until something recreated
/// the timer. One-shot timers, rescheduled after each tick, pick it up at the
/// very next poll.
class PollScheduler {
  PollScheduler({required this.interval, required this.tick});

  final Duration Function() interval;
  final Future<void> Function() tick;
  Timer? _timer;
  bool _running = false;

  bool get isRunning => _running;

  void start() {
    _running = true;
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (!_running) return;
    _timer = Timer(interval(), () async {
      try {
        await tick();
      } catch (_) {
        // A failed poll is the next poll's problem.
      }
      _schedule();
    });
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }
}

/// Owns the schedule: pull on foreground, flush when the server is reachable
/// again, poll while foregrounded, and stop everything in the background.
///
/// Background sync is **not** promised. iOS grants background execution at its
/// own discretion, so the UX is designed for "flushes when the app is open" and
/// anything more is a bonus — the alternative is an operator who believes a
/// delivery was reported and went home.
class SyncController extends Notifier<SyncStatus> {
  PollScheduler? _poll;
  PollScheduler? _noticePoll;
  StreamSubscription<bool>? _netSub;
  AppLifecycleListener? _lifecycle;
  bool _started = false;
  bool _again = false;

  /// How often the bell asks for news while the app is open.
  static const noticeInterval = Duration(seconds: 45);

  Services get _s => ref.read(servicesProvider);

  /// The server serves change-log rows only once they are a couple of seconds
  /// old (the visibility lag that keeps a slow commit from being skipped), so a
  /// pull straight after our own intent lands misses it — and the record the
  /// intent moved into another worklist (a collected pickup into Office) would
  /// wait for the next poll, five minutes once 304s have backed it off.
  static const followUpAfterOwnChange = Duration(seconds: 3);
  Timer? _followUp;

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _followUp?.cancel();
      _poll?.stop();
      _noticePoll?.stop();
      _netSub?.cancel();
      _lifecycle?.dispose();
    });
    return const SyncStatus();
  }

  void start() {
    if (_started) return;
    _started = true;

    _s.flusher.onChanged = () => unawaited(refreshCounters());

    _netSub = _s.net.changes.listen((online) {
      state = state.copyWith(online: online);
      // The server is back: send what waited, now, not at its backoff slot.
      if (online) unawaited(syncNow(flushFirst: true, ignoreBackoff: true));
    });
    state = state.copyWith(online: _s.net.isOnline);

    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(_onResume());
      },
      onPause: _stopPolls,
      onHide: () {
        _stopPolls();
        // Whatever the person typed is on disk before the phone reclaims us.
        unawaited(_s.drafts.flushAll());
      },
    );

    _poll = PollScheduler(
      interval: () => sudiFlavor.isField ? _s.sync.pollInterval : const Duration(minutes: 2),
      tick: syncNow,
    )..start();
    if (sudiFlavor.isField) {
      NoticeAlerts.instance.init().then((_) => NoticeAlerts.instance.requestPermission());
      _noticePoll = PollScheduler(
        interval: () => noticeInterval,
        tick: () => ref.read(noticesProvider.notifier).refresh(),
      )..start();
    }
    unawaited(refreshCounters());
    unawaited(syncNow());
  }

  Future<void> _onResume() async {
    // The process stopwatch does not count deep sleep; the uptime does.
    await _s.clock.refresh();
    unawaited(ref.read(sessionProvider.notifier).refreshIfStale());
    unawaited(_s.pinClock());
    unawaited(syncNow());
    _poll?.start();
    _noticePoll?.start();
  }

  void _stopPolls() {
    _poll?.stop();
    _noticePoll?.stop();
  }

  Future<void> refreshCounters() async {
    if (!_s.db.isOpen) return;
    final queued = await _s.outbox.openCount();
    final attention = await _s.outbox.attentionCount();
    final last = await _s.records.lastPulledAt();
    state = state.copyWith(
      online: _s.net.isOnline,
      queued: queued,
      needsAttention: attention,
      lastSyncedAt: last,
      clockSkewed: _s.clock.isSkewed,
      clockSkewLabel: _s.clock.skewLabel,
    );
    ref.read(dataRevisionProvider.notifier).bump();
  }

  /// This phone just changed something on the server (a queued intent landed,
  /// or an online-only call such as Mark READY or Finish answered): pull again
  /// once the change is past the server's visibility lag, so a record it moved
  /// to another worklist shows there within seconds.
  void followUpOwnChange() {
    if (!sudiFlavor.isField) return;
    _s.sync.noteLocalChange();
    _followUp?.cancel();
    _followUp = Timer(followUpAfterOwnChange, () => unawaited(syncNow()));
  }

  /// Pull then flush on a foreground; flush then pull when the server returns.
  /// Records the server named in a conflict are re-pulled straight after.
  Future<void> syncNow({bool flushFirst = false, bool ignoreBackoff = false}) async {
    if (state.syncing) {
      _again = true;
      return;
    }
    state = state.copyWith(syncing: true);
    final landedBefore = _s.flusher.landed;
    try {
      if (!_s.clock.pinned) await _s.pinClock();
      if (flushFirst) await _s.flusher.flush(ignoreBackoff: ignoreBackoff);
      var reached = true;
      // The customer API has no worklists to pull; submission is the whole app.
      if (sudiFlavor.isField) {
        final outcome = await _s.sync.pull();
        if (outcome.error != null && outcome.error!.isWipe) {
          await ref.read(sessionProvider.notifier).handleWipe();
          return;
        }
        reached = outcome.error?.code != ApiError.network;
      }
      if (!flushFirst && reached) await _s.flusher.flush();
      if (_s.wiped) {
        await ref.read(sessionProvider.notifier).handleWipe();
        return;
      }
      if (sudiFlavor.isField) {
        final resync = _s.flusher.takeResync();
        if (resync.resync.isNotEmpty) {
          final again = await _s.sync.pull(resyncIds: resync.resync);
          if (again.error == null) {
            // Not ours any more, and the fresh pull did not bring them back.
            await _s.records.removeEverywhere(
              resync.notInScope.where((id) => !again.touched.contains(id)),
            );
          } else {
            // Not reached: try the re-pull again next time.
            _s.flusher.pendingResync.addAll(resync.resync);
            _s.flusher.notInScope.addAll(resync.notInScope);
          }
        }
        unawaited(ref.read(noticesProvider.notifier).refresh());
        if (_s.flusher.landed != landedBefore) followUpOwnChange();
      }
    } on ApiError catch (e) {
      if (e.isWipe) await ref.read(sessionProvider.notifier).handleWipe();
    } finally {
      state = state.copyWith(syncing: false);
      await refreshCounters();
      if (_again) {
        _again = false;
        unawaited(syncNow(flushFirst: true));
      }
    }
  }
}

final syncProvider = NotifierProvider<SyncController, SyncStatus>(SyncController.new);

/// Bumped whenever the local database changes, so list screens re-read without
/// every DAO needing to be a stream.
class DataRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state = state + 1;
}

final dataRevisionProvider = NotifierProvider<DataRevision, int>(DataRevision.new);
