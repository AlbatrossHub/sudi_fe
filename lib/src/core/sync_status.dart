import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/flavor.dart';
import 'api/api_error.dart';
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

/// Owns the schedule: pull on foreground, flush on connectivity, poll while
/// foregrounded, and stop everything in the background.
///
/// Background sync is **not** promised. iOS grants background execution at its
/// own discretion, so the UX is designed for "flushes when the app is open" and
/// anything more is a bonus — the alternative is an operator who believes a
/// delivery was reported and went home.
class SyncController extends Notifier<SyncStatus> {
  Timer? _poll;
  StreamSubscription<bool>? _netSub;
  AppLifecycleListener? _lifecycle;
  bool _started = false;

  Services get _s => ref.read(servicesProvider);

  @override
  SyncStatus build() {
    ref.onDispose(() {
      _poll?.cancel();
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
      if (online) unawaited(syncNow(flushFirst: true));
    });
    state = state.copyWith(online: _s.net.isOnline);

    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(ref.read(sessionProvider.notifier).refreshIfStale());
        unawaited(syncNow());
        _schedulePoll();
      },
      onPause: _stopPoll,
      onHide: _stopPoll,
    );

    _schedulePoll();
    unawaited(refreshCounters());
    unawaited(syncNow());
  }

  void _schedulePoll() {
    _poll?.cancel();
    _poll = Timer.periodic(
      sudiFlavor.isField ? _s.sync.pollInterval : const Duration(minutes: 2),
      (_) => unawaited(syncNow()),
    );
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  Future<void> refreshCounters() async {
    if (!_s.db.isOpen) return;
    final queued = await _s.outbox.openCount();
    final attention = await _s.outbox.attentionCount();
    final last = await _s.records.lastPulledAt();
    state = state.copyWith(
      queued: queued,
      needsAttention: attention,
      lastSyncedAt: last,
      clockSkewed: _s.clock.isSkewed,
      clockSkewLabel: _s.clock.skewLabel,
    );
    ref.read(dataRevisionProvider.notifier).bump();
  }

  /// Pull then flush on a foreground; flush then pull when the radio returns.
  Future<void> syncNow({bool flushFirst = false}) async {
    if (state.syncing) return;
    state = state.copyWith(syncing: true);
    try {
      if (flushFirst) await _s.flusher.flush();
      // The customer API has no worklists to pull; submission is the whole app.
      if (sudiFlavor.isField) {
        final outcome = await _s.sync.pull();
        if (outcome.error != null && outcome.error!.isWipe) {
          await ref.read(sessionProvider.notifier).handleWipe();
          return;
        }
      }
      if (!flushFirst) await _s.flusher.flush();
      if (_s.wiped) {
        await ref.read(sessionProvider.notifier).handleWipe();
        return;
      }
    } on ApiError catch (e) {
      if (e.isWipe) await ref.read(sessionProvider.notifier).handleWipe();
    } finally {
      state = state.copyWith(syncing: false);
      await refreshCounters();
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
