import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// One request as the fake server saw it.
class FakeRequest {
  FakeRequest(this.method, this.path, this.query, this.headers, this.body, this.params);

  final String method;

  /// Relative to the flavor's base path: `/pickups/42/confirm`.
  final String path;
  final Map<String, dynamic> query;
  final Map<String, dynamic> headers;

  /// The decoded JSON body, a `FormData`, or null.
  final Object? body;

  /// `{id}`-style captures from the route pattern.
  final Map<String, String> params;

  Map<String, dynamic> get json =>
      body is Map ? Map<String, dynamic>.from(body as Map) : const <String, dynamic>{};

  int param(String name) => int.parse(params[name]!);

  @override
  String toString() => '$method $path';
}

class FakeResponse {
  FakeResponse.json(this.body, {this.status = 200, Map<String, List<String>>? headers})
      : bytes = null,
        headers = {
          'content-type': ['application/json; charset=utf-8'],
          ...?headers,
        };

  FakeResponse.bytes(Uint8List this.bytes, {this.status = 200})
      : body = null,
        headers = {
          'content-type': ['image/jpeg'],
        };

  /// The server's error envelope.
  factory FakeResponse.error(int status, String code, String message,
          {bool retryable = false, List<int> resync = const []}) =>
      FakeResponse.json(
        {'code': code, 'message': message, 'retryable': retryable, 'resync': resync},
        status: status,
      );

  final int status;
  final Object? body;
  final Uint8List? bytes;
  final Map<String, List<String>> headers;
}

typedef FakeHandler = FutureOr<FakeResponse> Function(FakeRequest request);

/// A stand-in for the backend, plugged into Dio as its HTTP adapter. Routes
/// are `METHOD /path/{id}` patterns; anything unrouted answers 404 the way the
/// real server does. [offline] makes every request fail as a dead socket.
class FakeServer implements HttpClientAdapter {
  FakeServer({this.basePath = '/api/field/v1'}) {
    on('GET', '/time', (_) => FakeResponse.json({'server_time': serverTime.toIso8601String()}));
  }

  final String basePath;
  bool offline = false;
  DateTime serverTime = DateTime.utc(2026, 10, 22, 4, 35);
  final List<FakeRequest> requests = [];
  final List<(String, RegExp, List<String>, FakeHandler)> _routes = [];

  void on(String method, String pattern, FakeHandler handler) {
    final names = <String>[];
    final regex = RegExp(
      '^${pattern.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
        names.add(m[1]!);
        return r'([^/]+)';
      })}\$',
    );
    // Later registrations win, so a test can override a default route.
    _routes.insert(0, (method, regex, names, handler));
  }

  List<FakeRequest> sent(String method, [String? pathPrefix]) => [
        for (final r in requests)
          if (r.method == method && (pathPrefix == null || r.path.startsWith(pathPrefix))) r,
      ];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Drain the encoded body so Dio's sink completes.
    if (requestStream != null) await requestStream.drain<void>();
    if (offline) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline (fake)');
    }
    var path = options.uri.path;
    if (path.startsWith(basePath)) path = path.substring(basePath.length);
    Object? body = options.data;
    if (body is String && body.isNotEmpty) {
      try {
        body = jsonDecode(body);
      } catch (_) {}
    }
    for (final (method, regex, names, handler) in _routes) {
      if (method != options.method) continue;
      final m = regex.firstMatch(path);
      if (m == null) continue;
      final request = FakeRequest(
        options.method,
        path,
        Map<String, dynamic>.from(options.uri.queryParameters),
        Map<String, dynamic>.from(options.headers),
        body,
        {for (var i = 0; i < names.length; i++) names[i]: m.group(i + 1)!},
      );
      requests.add(request);
      final response = await handler(request);
      if (response.bytes != null) {
        return ResponseBody.fromBytes(response.bytes!, response.status, headers: response.headers);
      }
      return ResponseBody.fromString(
        jsonEncode(response.body),
        response.status,
        headers: response.headers,
      );
    }
    requests.add(FakeRequest(options.method, path, const {}, const {}, body, const {}));
    return ResponseBody.fromString(
      jsonEncode({'code': 'NOT_FOUND', 'message': 'No route ${options.method} $path', 'retryable': false}),
      404,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
