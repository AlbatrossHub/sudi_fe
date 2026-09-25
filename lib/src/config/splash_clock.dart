import 'dart:async';

/// When Flutter actually drew something.
///
/// The landing screen has to be held from here, not from `main()`. A cold start
/// on a mid-range phone spends a second or two between the process starting and
/// the first frame — in a debug build it was nearer three — and a hold measured
/// from startup expires before anyone has seen the screen. Measured from the
/// first frame, the mark is on screen for the time it says it is, on a fast
/// phone and a slow one alike.
class SplashClock {
  const SplashClock._();

  static final Completer<DateTime> _firstFrame = Completer<DateTime>();

  static void markFirstFrame() {
    if (!_firstFrame.isCompleted) _firstFrame.complete(DateTime.now());
  }

  /// Completes once [minimum] has passed since the landing screen was drawn.
  /// Runs alongside the work it guards, so it costs its own duration and
  /// nothing more.
  ///
  /// The timeout is the deadlock guard: only the landing screen marks the
  /// frame, so if anything ever routed past it this would otherwise wait on a
  /// frame that is never announced and the app would sit on the native window
  /// for good.
  static Future<void> hold(Duration minimum) async {
    final drawnAt = await _firstFrame.future
        .timeout(const Duration(seconds: 10), onTimeout: DateTime.now);
    final left = minimum - DateTime.now().difference(drawnAt);
    if (left > Duration.zero) await Future<void>.delayed(left);
  }
}
