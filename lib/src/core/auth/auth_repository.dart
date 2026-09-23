import '../api/api_client.dart';
import '../api/api_error.dart';
import '../../models/docs.dart';
import 'device_identity.dart';
import 'token_store.dart';

class OtpChallenge {
  const OtpChallenge({
    required this.expiresIn,
    required this.resendAfter,
    required this.channel,
  });

  final int expiresIn;
  final int resendAfter;

  /// `whatsapp`. Say so in the UI, or every support call will be "I didn't get
  /// the SMS" — there is no SMS fallback.
  final String channel;

  factory OtpChallenge.fromJson(Map<String, dynamic> j) => OtpChallenge(
        expiresIn: (j['expires_in'] as num?)?.toInt() ?? 300,
        resendAfter: (j['resend_after'] as num?)?.toInt() ?? 60,
        channel: '${j['channel'] ?? 'whatsapp'}',
      );
}

class OtpVerdict {
  const OtpVerdict({required this.registrationRequired, this.registrationToken});
  final bool registrationRequired;

  /// **Not a bearer token.** It lasts 15 minutes and says only "this number
  /// answered a code". Hold it in memory for the name screen.
  final String? registrationToken;
}

class AuthRepository {
  AuthRepository(this._api, this._tokens, this._device);

  final ApiClient _api;
  final TokenStore _tokens;
  final DeviceIdentity _device;

  // -------------------------------------------------------------- staff

  Future<void> login({required String login, required String password}) async {
    final device = await _device.current();
    final response = await _api.post<Map<String, dynamic>>(
      '/auth/login',
      body: {'login': login, 'password': password, 'device': device.toJson()},
      skipAuth: true,
    );
    await _store(response.data ?? const {});
  }

  // ----------------------------------------------------------- customer

  Future<OtpChallenge> requestOtp(String phone) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/auth/otp/request',
      body: {'phone': phone},
      skipAuth: true,
    );
    return OtpChallenge.fromJson(response.data ?? const {});
  }

  Future<OtpVerdict> verifyOtp({required String phone, required String code}) async {
    final device = await _device.current();
    final response = await _api.post<Map<String, dynamic>>(
      '/auth/otp/verify',
      body: {'phone': phone, 'code': code, 'device': device.toJson()},
      skipAuth: true,
    );
    final data = response.data ?? const <String, dynamic>{};
    if (data['registration_required'] == true) {
      return OtpVerdict(
        registrationRequired: true,
        registrationToken: data['registration_token'] as String?,
      );
    }
    await _store(Map<String, dynamic>.from((data['tokens'] as Map?) ?? const {}));
    return const OtpVerdict(registrationRequired: false);
  }

  Future<void> register({
    required String registrationToken,
    required String name,
    String? vat,
  }) async {
    final device = await _device.current();
    final response = await _api.post<Map<String, dynamic>>(
      '/auth/register',
      body: {
        'registration_token': registrationToken,
        'name': name,
        'vat': ?vat,
        'device': device.toJson(),
      },
      skipAuth: true,
    );
    await _store(response.data ?? const {});
  }

  /// A skip is a "not now", never final: `POST /gst` still works afterwards.
  Future<String> submitGst(String vat) async {
    final response = await _api.post<Map<String, dynamic>>('/gst', body: {'vat': vat});
    return '${(response.data ?? const {})['gst_state'] ?? 'present'}';
  }

  Future<String> skipGst() async {
    final response = await _api.post<Map<String, dynamic>>('/gst/skip', body: const {});
    return '${(response.data ?? const {})['gst_state'] ?? 'skipped'}';
  }

  Future<List<AddressSuggestion>> addresses() async {
    final response = await _api.get<List<dynamic>>('/addresses');
    return (response.data ?? const [])
        .whereType<Map>()
        .map((m) => AddressSuggestion.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  // -------------------------------------------------------------- shared

  Future<MeInfo> me() async {
    final response = await _api.get<Map<String, dynamic>>('/auth/me');
    return MeInfo.fromJson(response.data ?? const {});
  }

  /// Returns false when the refresh itself was refused — the caller decides
  /// whether that is a logout. A failed refresh is **not** a logout on its own.
  Future<bool> refresh() async {
    final token = await _tokens.refreshToken();
    if (token == null) return false;
    try {
      final response = await _api.post<Map<String, dynamic>>(
        '/auth/refresh',
        body: {'refresh_token': token},
        skipAuth: true,
      );
      await _store(response.data ?? const {});
      return true;
    } on ApiError catch (e) {
      if (e.isWipe) rethrow;
      return false;
    }
  }

  // ------------------------------------------------------------- devices

  /// Every handset registered to this account, current one flagged.
  Future<List<RegisteredDevice>> devices() async {
    final response = await _api.get<List<dynamic>>('/devices');
    return (response.data ?? const [])
        .whereType<Map>()
        .map((m) => RegisteredDevice.fromJson(Map<String, dynamic>.from(m)))
        .toList();
  }

  /// Sign another of the caller's own handsets out. The server answers the
  /// same "no such device" for a uid belonging to somebody else, so this
  /// cannot be used to probe for other people's phones.
  Future<void> revokeDevice(String deviceUid) async {
    // 204 with no body, so nothing is decoded and the type argument stays
    // dynamic rather than a shape Dio would have to cast an empty body into.
    await _api.post<dynamic>('/devices/$deviceUid/revoke', body: const {});
  }

  /// Tell the server what this handset is running.
  ///
  /// `app_version` is otherwise only ever set at login, so an operator who
  /// updates the app without signing out leaves a stale version on their
  /// device record -- and that record is what support reads when a phone
  /// misbehaves. Sent once per launch, and only when it has actually changed.
  Future<void> reportThisDevice({String? pushToken}) async {
    final device = await _device.current();
    final reported = await _tokens.reportedAppVersion();
    if (reported == device.appVersion && pushToken == null) return;
    try {
      await _api.patch<Map<String, dynamic>>(
        '/devices/me',
        body: {
          'app_version': device.appVersion,
          'push_token': ?pushToken,
        },
      );
      await _tokens.saveReportedAppVersion(device.appVersion);
    } on ApiError {
      // Housekeeping. A phone with no signal still works; it reports next launch.
    }
  }

  /// Does the *office* answer, as opposed to the radio being on? The status
  /// strip deliberately reports the radio, so this is the only way to tell an
  /// operator whether the server itself is reachable.
  Future<bool> health() async {
    try {
      final response = await _api.get<Map<String, dynamic>>(
        '/health',
        skipAuth: true,
      );
      return '${(response.data ?? const {})['status']}' == 'ok';
    } on ApiError {
      return false;
    }
  }

  // -------------------------------------------------------------- session

  /// Best effort: revoking server-side is nice, clearing locally is required.
  Future<void> logout() async {
    try {
      await _api.post<Map<String, dynamic>>('/auth/logout', body: const {});
    } on ApiError {
      // Signing out with no signal still signs you out.
    }
    await _tokens.clearTokens();
  }

  Future<void> _store(Map<String, dynamic> tokens) async {
    final access = tokens['access_token'] as String?;
    final refreshToken = tokens['refresh_token'] as String?;
    if (access == null || refreshToken == null) {
      throw ApiError(
        code: ApiError.server,
        message: 'The server did not return a usable session.',
        retryable: false,
      );
    }
    await _tokens.saveTokens(
      access: access,
      refresh: refreshToken,
      expiresIn: (tokens['expires_in'] as num?)?.toInt() ?? 86400,
      roles: ((tokens['roles'] as List?) ?? const []).map((e) => '$e').toList(),
    );
  }
}
