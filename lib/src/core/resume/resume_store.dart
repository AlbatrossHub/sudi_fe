import 'dart:async';

import '../store/kv_store.dart';

/// Where the person was when the app went away -- swiped off, or closed by the
/// phone to save memory. Signed in, the app opens right there again: no intro,
/// no waiting for the server, the same tab underneath and the same form on top
/// (its content comes back from its draft).
class ResumePoint {
  const ResumePoint({required this.location, required this.tab, this.segments = const {}});

  /// The page on top: a tab root (`/jobwork`) or a page pushed over it
  /// (`/pickup/42/confirm`).
  final String location;

  /// The tab underneath, as its root path (`/pickups`, `/home`).
  final String tab;

  /// The segmented control each screen was left on (`pickups` -> 1 is the
  /// "Collected" side), so the list comes back the way it was read.
  final Map<String, int> segments;

  /// A page on top of the tab, which has to be pushed over it on restore so
  /// Back still goes where it went before.
  bool get hasPage => location != tab;

  ResumePoint copyWith({String? location, String? tab, Map<String, int>? segments}) => ResumePoint(
        location: location ?? this.location,
        tab: tab ?? this.tab,
        segments: segments ?? this.segments,
      );

  Map<String, dynamic> toJson() => {'location': location, 'tab': tab, 'segments': segments};
}

/// Saves every page and tab change, one write at a time.
///
/// [isResumable] and [isTab] are the router's knowledge of which locations are
/// worth coming back to (a form, a list) and which are not (sign-in, the lock
/// screen, a one-off acknowledgement).
class ResumeStore {
  ResumeStore(
    this._store, {
    required this.home,
    required this.isResumable,
    required this.isTab,
  }) : _point = ResumePoint(location: home, tab: home);

  final KvStore _store;
  final String home;
  final bool Function(String location) isResumable;
  final bool Function(String location) isTab;

  static const _key = 'ui/resume';

  ResumePoint _point;
  Future<void> _writing = Future.value();
  bool _loaded = false;

  ResumePoint get point => _point;
  bool get loaded => _loaded;

  Future<ResumePoint> load() async {
    final j = await _store.readJson(_key);
    final location = j?['location'] as String? ?? home;
    final tab = j?['tab'] as String? ?? home;
    final segments = <String, int>{
      for (final e in ((j?['segments'] as Map?) ?? const {}).entries)
        if (e.value is num) '${e.key}': (e.value as num).toInt(),
    };
    _point = ResumePoint(
      location: isResumable(location) ? location : (isTab(tab) ? tab : home),
      tab: isTab(tab) ? tab : home,
      segments: segments,
    );
    _loaded = true;
    return _point;
  }

  /// The router moved. A tab root also becomes the tab.
  void location(String location) {
    if (!isResumable(location)) return;
    final tab = isTab(location) ? location : _point.tab;
    if (location == _point.location && tab == _point.tab) return;
    _save(_point.copyWith(location: location, tab: tab));
  }

  void tab(String tabRoot) {
    if (!isTab(tabRoot) || tabRoot == _point.tab) return;
    _save(_point.copyWith(tab: tabRoot));
  }

  int segment(String screen) => _point.segments[screen] ?? 0;

  void setSegment(String screen, int index) {
    if (segment(screen) == index) return;
    _save(_point.copyWith(segments: {..._point.segments, screen: index}));
  }

  void _save(ResumePoint next) {
    _point = next;
    _writing = _writing.then(
      (_) => _store.writeJson(_key, next.toJson()).catchError((_) {}),
    );
  }

  /// Wait for pending writes (tests, and before a sign-out clears the store).
  Future<void> flush() => _writing;

  /// Signing out: the next person starts at home.
  Future<void> clear() async {
    _point = ResumePoint(location: home, tab: home);
    await _writing;
    await _store.delete(_key);
  }
}
