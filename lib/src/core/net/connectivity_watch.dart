import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// One unobtrusive signal, never a modal.
///
/// **Online means the server answered**, not that the radio is on. A phone on
/// a hotel Wi-Fi with a login page, a SIM with no data left, a server being
/// restarted: the radio says yes to all three and nothing will send. So the
/// radio is only a hint -- when it comes back the app asks the server
/// ([probe], which is `GET /time`), and every request reports whether it got an
/// answer ([reportServer], wired from `ApiClient.onReachability`). The outbox
/// flushes the moment the answer is yes again.
class ConnectivityWatch {
  ConnectivityWatch([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity(),
        _manual = false;

  /// No platform plugin: the radio is whatever [setRadio] says. For tests.
  ConnectivityWatch.manual({bool radio = true})
      : _connectivity = null,
        _manual = true,
        _radio = radio;

  final Connectivity? _connectivity;
  final bool _manual;
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _radio = true;

  /// Optimistic until a request says otherwise: at a cold start with the radio
  /// on, the first pull settles it within a second.
  bool _server = true;

  /// Asks the server whether it is there (and pins the clock while it is at
  /// it). Wired by `Services`.
  Future<bool> Function()? probe;

  bool get radio => _radio;
  bool get serverAnswered => _server;
  bool get isOnline => _radio && _server;
  Stream<bool> get changes => _controller.stream;

  Future<void> start() async {
    if (_manual) return;
    try {
      _applyRadio(_hasNetwork(await _connectivity!.checkConnectivity()));
      _sub = _connectivity.onConnectivityChanged.listen((r) => _applyRadio(_hasNetwork(r)));
    } catch (_) {
      // No plugin (a test, a desktop build): assume a radio and let the
      // requests themselves say whether the server is there.
    }
  }

  static bool _hasNetwork(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);

  void setRadio(bool on) => _applyRadio(on);

  void _applyRadio(bool on) {
    final before = isOnline;
    final cameBack = on && !_radio;
    _radio = on;
    _emitIfChanged(before);
    if (cameBack) {
      // The radio is back; whether the server is, only asking will tell.
      unawaited(_ask());
    }
  }

  Future<void> _ask() async {
    final ask = probe;
    if (ask == null) return;
    try {
      reportServer(await ask());
    } catch (_) {
      reportServer(false);
    }
  }

  /// Called after every request.
  void reportServer(bool answered) {
    final before = isOnline;
    _server = answered;
    _emitIfChanged(before);
  }

  void _emitIfChanged(bool before) {
    if (isOnline != before && !_controller.isClosed) _controller.add(isOnline);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
