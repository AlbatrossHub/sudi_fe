import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Tokens and the device identity, in platform secure storage.
///
/// Lifetimes are long on purpose (24 h access, 90 d refresh): an operator out
/// of coverage all morning has to be able to flush at 14:00 without a round
/// trip they cannot make. **Never gate the UI on any of this.**
class TokenStore {
  TokenStore([FlutterSecureStorage? storage])
      // v11 defaults are already AES-GCM with RSA key wrapping; there is
      // nothing left to opt into.
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kAccess = 'sudi.access_token';
  static const _kRefresh = 'sudi.refresh_token';
  static const _kExpiry = 'sudi.access_expires_at';
  static const _kDeviceUid = 'sudi.device_uid';
  static const _kDbKey = 'sudi.db_key';
  static const _kPin = 'sudi.pin_hash';
  static const _kRoles = 'sudi.roles';
  static const _kReportedVersion = 'sudi.reported_app_version';

  String? _accessCache;
  DateTime? _expiryCache;

  Future<String?> accessToken() async {
    _accessCache ??= await _storage.read(key: _kAccess);
    return _accessCache;
  }

  Future<String?> refreshToken() => _storage.read(key: _kRefresh);

  Future<DateTime?> accessExpiry() async {
    if (_expiryCache != null) return _expiryCache;
    final raw = await _storage.read(key: _kExpiry);
    if (raw == null) return null;
    return _expiryCache = DateTime.tryParse(raw);
  }

  Future<void> saveTokens({
    required String access,
    required String refresh,
    required int expiresIn,
    List<String>? roles,
  }) async {
    _accessCache = access;
    _expiryCache = DateTime.now().add(Duration(seconds: expiresIn));
    await Future.wait([
      _storage.write(key: _kAccess, value: access),
      _storage.write(key: _kRefresh, value: refresh),
      _storage.write(key: _kExpiry, value: _expiryCache!.toIso8601String()),
      if (roles != null) _storage.write(key: _kRoles, value: jsonEncode(roles)),
    ]);
  }

  Future<List<String>> roles() async {
    final raw = await _storage.read(key: _kRoles);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    return decoded is List ? decoded.map((e) => '$e').toList() : const [];
  }

  Future<bool> get hasSession async => (await refreshToken()) != null;

  /// Clears tokens but keeps the device uid — the phone is still the same
  /// phone, and regenerating the uid would orphan its server-side record.
  Future<void> clearTokens() async {
    _accessCache = null;
    _expiryCache = null;
    await Future.wait([
      _storage.delete(key: _kAccess),
      _storage.delete(key: _kRefresh),
      _storage.delete(key: _kExpiry),
      _storage.delete(key: _kRoles),
    ]);
  }

  /// Sign-out or a revoked device. Drops the PIN and the database key too, so
  /// the encrypted store on disk becomes unreadable.
  ///
  /// The device uid survives. `_sudi_register` brings a revoked handset back
  /// when it authenticates again, so keeping the uid lets this phone reclaim
  /// its own server-side record; a `deleteAll()` here orphaned that row and
  /// minted a fresh one on every sign-out, so an operator's device list filled
  /// up with ghosts of the same phone.
  Future<void> wipe() async {
    _accessCache = null;
    _expiryCache = null;
    final deviceUid = await _storage.read(key: _kDeviceUid);
    // The database file outlives a sign-out (its rows are cleared, the file
    // stays open), so its key must too: dropping it left a file no later
    // launch could open -- a blank screen until the app data was cleared.
    final dbKey = await _storage.read(key: _kDbKey);
    await _storage.deleteAll();
    if (deviceUid != null && deviceUid.isNotEmpty) {
      await _storage.write(key: _kDeviceUid, value: deviceUid);
    }
    if (dbKey != null && dbKey.isNotEmpty) {
      await _storage.write(key: _kDbKey, value: dbKey);
    }
  }

  /// Only when the database file it opens has been deleted.
  Future<void> forgetDatabaseKey() => _storage.delete(key: _kDbKey);

  /// The app version last accepted by `PATCH /devices/me`, so the report is
  /// sent when it changes rather than on every launch.
  Future<String?> reportedAppVersion() => _storage.read(key: _kReportedVersion);

  Future<void> saveReportedAppVersion(String version) =>
      _storage.write(key: _kReportedVersion, value: version);

  /// Generated once on first launch and never regenerated — not from androidId,
  /// not from a vendor id that changes on reinstall. It is the identity behind
  /// per-device revocation and the server's record of this phone's cursor.
  Future<String> deviceUid(String Function() generate) async {
    final existing = await _storage.read(key: _kDeviceUid);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = generate();
    await _storage.write(key: _kDeviceUid, value: fresh);
    return fresh;
  }

  /// The SQLCipher key. Same rule: created once, never rotated in place.
  Future<String> databaseKey(String Function() generate) async {
    final existing = await _storage.read(key: _kDbKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final fresh = generate();
    await _storage.write(key: _kDbKey, value: fresh);
    return fresh;
  }

  Future<String?> pinHash() => _storage.read(key: _kPin);
  Future<void> savePinHash(String hash) => _storage.write(key: _kPin, value: hash);
  Future<void> clearPin() => _storage.delete(key: _kPin);
}
