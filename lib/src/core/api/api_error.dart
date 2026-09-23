import 'package:dio/dio.dart';

/// The typed error envelope from the server (brief section 7).
///
/// `code` is the branch, `message` is safe to show verbatim, `retryable` is the
/// only thing that decides retry-versus-drop, `resync` lists ids to re-pull.
/// This is the class the outbox reasons with; nothing else should be inspecting
/// HTTP status codes.
class ApiError implements Exception {
  ApiError({
    required this.code,
    required this.message,
    required this.retryable,
    this.status,
    this.resync = const [],
    this.detail = const {},
  });

  final String code;
  final String message;
  final bool retryable;
  final int? status;
  final List<int> resync;
  final Map<String, dynamic> detail;

  // Codes the client branches on. Anything else falls through to `SERVER`.
  static const validation = 'VALIDATION';
  static const notInScope = 'NOT_IN_SCOPE';
  static const alreadyDone = 'ALREADY_DONE';
  static const alreadyTaken = 'ALREADY_TAKEN';
  static const alreadyConfirmed = 'ALREADY_CONFIRMED';
  static const staleIntent = 'STALE_INTENT';
  static const clockSkew = 'CLOCK_SKEW';
  static const locked = 'LOCKED';
  static const serialization = 'SERIALIZATION';
  static const auth = 'AUTH';
  static const deviceRevoked = 'DEVICE_REVOKED';
  static const server = 'SERVER';
  static const network = 'NETWORK';
  static const otpRateLimited = 'OTP_RATE_LIMITED';
  static const otpInvalid = 'OTP_INVALID';
  static const otpExpired = 'OTP_EXPIRED';
  static const otpNotFound = 'OTP_NOT_FOUND';
  static const otpUndeliverable = 'OTP_UNDELIVERABLE';

  /// A 409 saying somebody else got there first. Not an error dialog — show it
  /// on the record and move on.
  bool get isLostRace => code == alreadyTaken || code == alreadyConfirmed;

  /// The remote-wipe signal: drop tokens and clear the local database.
  bool get isWipe => code == deviceRevoked;

  /// A retry that found its own earlier effect. Treat as success.
  bool get isReplay => code == alreadyDone;

  /// Never succeeds however good the signal becomes.
  bool get isPermanent => !retryable && !isReplay;

  factory ApiError.fromDio(DioException e) {
    final response = e.response;
    final data = response?.data;

    if (data is Map && data['code'] is String) {
      return ApiError(
        code: data['code'] as String,
        message: (data['message'] as String?) ?? 'Something went wrong.',
        retryable: (data['retryable'] as bool?) ?? false,
        status: response?.statusCode,
        resync: ((data['resync'] as List?) ?? const [])
            .map((v) => v is int ? v : int.tryParse('$v') ?? 0)
            .where((v) => v != 0)
            .toList(),
        detail: Map<String, dynamic>.from((data['detail'] as Map?) ?? const {}),
      );
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.unknown:
        return ApiError(
          code: network,
          message: 'No connection.',
          retryable: true,
          status: response?.statusCode,
        );
      case DioExceptionType.cancel:
        return ApiError(code: network, message: 'Cancelled.', retryable: true);
      case DioExceptionType.badCertificate:
        return ApiError(
          code: server,
          message: 'The server certificate was refused.',
          retryable: false,
        );
      case DioExceptionType.badResponse:
        final s = response?.statusCode ?? 0;
        return ApiError(
          code: s == 401 ? auth : server,
          message: s >= 500 ? 'The office system is unavailable.' : 'Request refused.',
          retryable: s >= 500,
          status: s,
        );
    }
  }

  @override
  String toString() => 'ApiError($code, $status): $message';
}
