/// Where the app points, and how to move it.
///
/// The default is the dev tunnel in front of the Odoo box. Override without
/// editing the file:
///
///   flutter run --dart-define=SUDI_BASE_URL=https://example.trycloudflare.com
///   flutter build apk --dart-define=SUDI_BASE_URL=... --dart-define=SUDI_DB=sudi
///
/// A quick Cloudflare tunnel gets a new hostname every restart, so expect to
/// pass `--dart-define` rather than rebuild this constant.
class Env {
  const Env._();

  static const String baseUrl = String.fromEnvironment(
    'SUDI_BASE_URL',
    defaultValue: 'https://nsw-defend-worlds-sporting.trycloudflare.com',
  );

  /// Appended as `?db=` on every call — the server hosts several.
  static const String db = String.fromEnvironment('SUDI_DB', defaultValue: 'sudi');

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
