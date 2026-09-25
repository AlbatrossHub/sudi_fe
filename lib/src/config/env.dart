/// Where the app points, and how to move it.
///
/// The default is production. It is a real hostname with a real certificate, so
/// a build with no `--dart-define` is the one that should ship — the tunnel
/// hostnames that used to live here changed every restart and shipped stale.
///
/// Override for a local server or a tunnel:
///
///   flutter run --dart-define=SUDI_BASE_URL=http://localhost:8069
///   flutter build apk --dart-define=SUDI_BASE_URL=... --dart-define=SUDI_DB=sudi
///
/// The app shows whichever one it was built with under "Powered by Albatross",
/// because "it will not connect" is nearly always the server address.
class Env {
  const Env._();

  static const String baseUrl = String.fromEnvironment(
    'SUDI_BASE_URL',
    defaultValue: 'https://manage.sdppl.com',
  );

  /// Appended as `?db=` on every call — the server hosts several.
  static const String db = String.fromEnvironment('SUDI_DB', defaultValue: 'sudi');

  /// How long the landing screen stays up on a cold start, whether or not the
  /// session was ready sooner. Long enough to read the mark; it is a floor, not
  /// a sleep, so a slow restore does not add to it.
  static const Duration splashMinimum = Duration(seconds: 3);

  /// Pull while foregrounded (brief section 6.3).
  static const Duration pollInterval = Duration(seconds: 60);
  static const Duration pollIntervalBackedOff = Duration(minutes: 5);

  /// Refresh proactively when the access token has less than this left.
  static const Duration refreshWindow = Duration(hours: 1);

  /// The server refuses an event older than this, permanently.
  static const Duration maxBackdate = Duration(hours: 72);
  static const Duration staleWarnAfter = Duration(hours: 24);
  static const Duration staleUrgentAfter = Duration(hours: 48);

  /// Image policy (brief section 9.2). Do not go below 1600.
  static const int imageLongEdge = 1800;
  static const int imageQuality = 80;
  static const int stagedImageCapBytes = 200 * 1024 * 1024;

  static const int syncPageLimit = 200;
}
