import 'dart:io';
import 'dart:math';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import 'token_store.dart';

/// The `device` object sent on every login and OTP verify.
class DeviceInfo {
  const DeviceInfo({
    required this.deviceUid,
    required this.platform,
    required this.appVersion,
    this.pushToken,
  });

  final String deviceUid;
  final String platform;
  final String appVersion;
  final String? pushToken;

  Map<String, dynamic> toJson() => {
        'device_uid': deviceUid,
        'platform': platform,
        'app_version': appVersion,
        'push_token': pushToken,
      };
}

class DeviceIdentity {
  DeviceIdentity(this._tokens);

  final TokenStore _tokens;
  DeviceInfo? _cached;

  static final _uuid = Uuid();

  Future<DeviceInfo> current() async {
    if (_cached != null) return _cached!;
    final uid = await _tokens.deviceUid(() => _uuid.v4());
    String version = '1.0.0+1';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Not fatal: a device record with a vague version beats no login.
    }
    return _cached = DeviceInfo(
      deviceUid: uid,
      platform: Platform.isIOS ? 'ios' : 'android',
      appVersion: version,
    );
  }

  /// SQLCipher key material. 32 bytes of `Random.secure`, hex-encoded.
  static String newDatabaseKey() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
