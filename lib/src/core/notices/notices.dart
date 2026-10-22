import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/docs.dart';
import '../api/api_error.dart';
import '../services.dart';

/// The bell: in-app notices from `GET /notices`, polled while the app is open
/// (about every 45 s, and after every pull), kept on the phone so the list
/// opens offline, and raised as a phone notification while the app is open.
/// Push (FCM) plugs into the same notices later.
class NoticesState {
  const NoticesState({
    this.items = const [],
    this.lastId = 0,
    this.seenId = 0,
    this.fetched = false,
  });

  /// Newest first.
  final List<NoticeInfo> items;

  /// Sent back as `after` on the next poll.
  final int lastId;

  /// The newest notice already announced on this phone: a cold start never
  /// re-announces old ones.
  final int seenId;

  /// The server has answered at least once (so the next answer only holds
  /// what is new, and is worth announcing).
  final bool fetched;

  int get unread => items.where((n) => !n.read).length;

  /// The `jobwork_ready` notices not read yet: those cards say "READY · new".
  Set<int> get unreadPickings => {
        for (final n in items)
          if (!n.read && n.pickingId != null) n.pickingId!,
      };

  NoticesState copyWith({List<NoticeInfo>? items, int? lastId, int? seenId, bool? fetched}) =>
      NoticesState(
        items: items ?? this.items,
        lastId: lastId ?? this.lastId,
        seenId: seenId ?? this.seenId,
        fetched: fetched ?? this.fetched,
      );

  Map<String, dynamic> toJson() => {
        'items': [for (final n in items) n.toJson()],
        'last_id': lastId,
        'seen_id': seenId,
        'fetched': fetched,
      };

  factory NoticesState.fromJson(Map<String, dynamic> j) => NoticesState(
        items: [
          for (final m in ((j['items'] as List?) ?? const []).whereType<Map>())
            NoticeInfo.fromJson(Map<String, dynamic>.from(m)),
        ],
        lastId: (j['last_id'] as num?)?.toInt() ?? 0,
        seenId: (j['seen_id'] as num?)?.toInt() ?? 0,
        fetched: j['fetched'] == true,
      );
}

class NoticesController extends Notifier<NoticesState> {
  static const _key = 'notices/feed';
  static const _keep = 100;

  Services get _s => ref.read(servicesProvider);
  bool _busy = false;
  bool _loaded = false;

  @override
  NoticesState build() {
    scheduleMicrotask(_loadSaved);
    return const NoticesState();
  }

  Future<void> _loadSaved() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = await _s.kv.readJson(_key);
      if (j != null && ref.mounted) state = NoticesState.fromJson(j);
    } catch (_) {
      // An unreadable copy: the next poll rebuilds it.
    }
  }

  Future<void> _persist() => _s.kv.writeJson(_key, state.toJson());

  /// Ask the server for what is new. Quiet on failure: offline the bell keeps
  /// what it last had.
  Future<void> refresh({bool announce = true}) async {
    if (_busy) return;
    _busy = true;
    try {
      await _loadSaved();
      final first = !state.fetched;
      var after = first ? null : state.lastId;
      final fresh = <NoticeInfo>[];
      var lastId = state.lastId;
      for (var page = 0; page < 10; page++) {
        final list = await _s.v2.notices(after: after);
        fresh.addAll(list.notices);
        lastId = max(lastId, list.lastId);
        // The first answer is the newest page and is enough for a bell.
        if (first || !list.hasMore) break;
        after = list.lastId;
      }

      final byId = {for (final n in state.items) n.id: n};
      for (final n in fresh) {
        final mine = byId[n.id];
        // A read mark made on this phone and not yet sent stands.
        byId[n.id] = (mine != null && mine.read && !n.read) ? n.asRead() : n;
      }
      final items = byId.values.toList()..sort((a, b) => b.id.compareTo(a.id));

      final newest = items.isEmpty ? 0 : items.first.id;
      final toAnnounce = first
          ? const <NoticeInfo>[]
          : [for (final n in fresh) if (!n.read && n.id > state.seenId) n];

      state = state.copyWith(
        items: items.take(_keep).toList(),
        lastId: lastId,
        seenId: max(state.seenId, newest),
        fetched: true,
      );
      await _persist();

      if (announce) {
        for (final n in toAnnounce.take(3)) {
          await NoticeAlerts.instance.show(n);
        }
      }
    } on ApiError {
      // Offline: try again on the next tick.
    } catch (_) {
      // Never let the bell break a sync.
    } finally {
      _busy = false;
    }
  }

  Future<void> markRead(Iterable<int> ids) async {
    final wanted = ids.toSet();
    final unread = [for (final n in state.items) if (wanted.contains(n.id) && !n.read) n.id];
    if (unread.isEmpty) return;
    state = state.copyWith(items: [
      for (final n in state.items) wanted.contains(n.id) ? n.asRead() : n,
    ]);
    await _persist();
    await _s.field.markNoticesRead(ids: unread);
    unawaited(_s.flusher.flush());
  }

  Future<void> markAllRead() async {
    if (state.unread == 0) return;
    final upTo = state.items.fold<int>(0, (a, n) => max(a, n.id));
    state = state.copyWith(items: [for (final n in state.items) n.asRead()]);
    await _persist();
    await _s.field.markNoticesRead(upTo: upTo);
    unawaited(_s.flusher.flush());
  }
}

final noticesProvider = NotifierProvider<NoticesController, NoticesState>(NoticesController.new);

/// Where tapping a notice goes.
String routeForNotice({String? scope, int? pickingId}) {
  if (pickingId == null) return '/notices';
  return switch (scope) {
    'pickup' => '/pickup/$pickingId',
    'office' => '/office/$pickingId',
    'jobwork' => '/jobwork/$pickingId',
    'delivery' => '/deliveries',
    _ => '/notices',
  };
}

/// Phone notifications for notices that arrive while the app is open.
///
/// The small icon is `res/drawable-*/ic_stat_sudi.png`, a white silhouette,
/// kept through resource shrinking by `res/raw/keep.xml`: a wrong name here
/// silently disables every notification.
class NoticeAlerts {
  NoticeAlerts._();
  static final NoticeAlerts instance = NoticeAlerts._();

  /// Created once per install with sound and vibration; Android freezes a
  /// channel's settings when it is created, so a change needs a new id.
  static const channelId = 'sudi_notices_v1';
  static const _channelName = 'Work notifications';
  static const _channelDescription = 'New pickups, job work and jangads to validate';
  static const _color = Color(0xFF01579B);

  /// Off in tests: there is no platform to show anything on.
  static bool enabled = true;

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  /// Called with the route to open when a notification is tapped.
  void Function(String route)? onOpen;

  Future<void> init() async {
    if (_ready || !enabled || kIsWeb) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@drawable/ic_stat_sudi'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final route = r.payload;
          if (route != null && route.isNotEmpty) onOpen?.call(route);
        },
      );
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
              playSound: true,
              enableVibration: true,
            ),
          );
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  /// Android 13+ asks once; later calls are free.
  Future<void> requestPermission() async {
    if (!enabled) return;
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Refused or unavailable: the bell in the app still works.
    }
  }

  Future<void> show(NoticeInfo notice) async {
    if (!enabled) return;
    if (!_ready) await init();
    if (!_ready) return;
    final body = notice.body ?? '';
    try {
      await _plugin.show(
        id: 0x40000000 | (notice.id & 0x3fffffff),
        title: notice.title,
        body: body,
        payload: routeForNotice(scope: notice.scope, pickingId: notice.pickingId),
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            color: _color,
            playSound: true,
            enableVibration: true,
            styleInformation: BigTextStyleInformation(body),
            ticker: notice.title,
          ),
          iOS: const DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentSound: true,
          ),
        ),
      );
    } catch (_) {
      // A notification that cannot be shown is not worth failing a poll over.
    }
  }
}
