import 'dart:async';

import 'package:dio/dio.dart';

import '../../config/env.dart';
import '../../config/flavor.dart';
import '../auth/token_store.dart';
import 'api_error.dart';

/// Everything that talks to the server goes through here.
///
/// Two things it guarantees for the rest of the app: every failure surfaces as
/// an [ApiError] with a `code` (never a raw `DioException`), and `db` is on
/// every call because the server hosts several databases.
class ApiClient {
  ApiClient(this._tokens) {
    dio = Dio(
      BaseOptions(
        baseUrl: '${Env.baseUrl}${sudiFlavor.apiPath}',
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 40),
        sendTimeout: const Duration(minutes: 3),
        headers: {'Accept': 'application/json'},
        // Dio throws on 304 by default; a 304 is "nothing changed", not a
        // failure, and /sync/pull relies on it.
        validateStatus: (s) => s != null && ((s >= 200 && s < 300) || s == 304),
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          options.queryParameters = {'db': Env.db, ...options.queryParameters};
          if (options.extra['skipAuth'] != true) {
            final token = await _tokens.accessToken();
            if (token != null) {
              options.headers['Authorization'] = 'Bearer $token';
            }
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          final err = ApiError.fromDio(e);

          // A revoked device is a wipe signal, not a refresh-and-retry.
          if (err.isWipe) {
            _onWipe?.call();
            return handler.reject(e);
          }

          final canRetry = err.code == ApiError.auth &&
              e.requestOptions.extra['retried'] != true &&
              e.requestOptions.extra['skipAuth'] != true;

          if (canRetry) {
            final refreshed = await _refreshOnce();
            if (refreshed) {
              final options = e.requestOptions;
              options.extra = {...options.extra, 'retried': true};
              try {
                final response = await dio.fetch<dynamic>(options);
                return handler.resolve(response);
              } on DioException catch (retryError) {
                return handler.reject(retryError);
              }
            }
          }
          handler.reject(e);
        },
      ),
    );
  }

  final TokenStore _tokens;
  late final Dio dio;

  void Function()? _onWipe;
  Future<bool> Function()? _refresher;
  Future<bool>? _inFlightRefresh;

  /// Wired by the auth layer once, at startup.
  void wire({required Future<bool> Function() refresher, required void Function() onWipe}) {
    _refresher = refresher;
    _onWipe = onWipe;
  }

  /// One refresh at a time — a phone that wakes with ten queued calls must not
  /// fire ten refreshes and invalidate its own new token nine times.
  Future<bool> _refreshOnce() {
    return _inFlightRefresh ??= () async {
      try {
        return await (_refresher?.call() ?? Future.value(false));
      } finally {
        _inFlightRefresh = null;
      }
    }();
  }

  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    bool skipAuth = false,
    ResponseType? responseType,
  }) =>
      _guard(() => dio.get<T>(
            path,
            queryParameters: query,
            options: Options(
              headers: headers,
              responseType: responseType,
              extra: {'skipAuth': skipAuth},
            ),
          ));

  Future<Response<T>> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    String? idempotencyKey,
    bool skipAuth = false,
  }) =>
      _guard(() => dio.post<T>(
            path,
            data: body,
            options: Options(
              headers: {
                'Idempotency-Key': ?idempotencyKey,
                ...?headers,
              },
              extra: {'skipAuth': skipAuth},
            ),
          ));

  Future<Response<T>> patch<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    bool skipAuth = false,
  }) =>
      _guard(() => dio.patch<T>(
            path,
            data: body,
            options: Options(
              headers: headers,
              extra: {'skipAuth': skipAuth},
            ),
          ));

  Future<Response<T>> _guard<T>(Future<Response<T>> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw ApiError.fromDio(e);
    }
  }
}
