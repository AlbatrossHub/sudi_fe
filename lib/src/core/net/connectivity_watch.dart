import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// One unobtrusive signal, never a modal.
///
/// "Online" here means the radio says there is a network — not that the server
/// answered. The status strip says when the last successful sync was, which is
/// the honest half of the story.
class ConnectivityWatch {
  ConnectivityWatch([Connectivity? connectivity])
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;
  final _controller = StreamController<bool>.broadcast();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  bool _online = true;
  bool get isOnline => _online;
  Stream<bool> get changes => _controller.stream;

  Future<void> start() async {
    _apply(await _connectivity.checkConnectivity());
    _sub = _connectivity.onConnectivityChanged.listen(_apply);
  }

  void _apply(List<ConnectivityResult> results) {
    final next = results.any((r) => r != ConnectivityResult.none);
    if (next == _online) return;
    _online = next;
    _controller.add(next);
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _controller.close();
  }
}
