import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The server answered with an error (GraphQL `extensions.code`, or a REST `{ error }`).
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.status});
  final String message;
  final String? code;
  final int? status;
  @override
  String toString() => message;
}

/// The request never reached the app server (offline, DNS failure, the backend restarting behind nginx).
class NetworkException implements Exception {
  NetworkException([this.message = "Couldn't reach the server. Check your connection and try again."]);
  final String message;
  @override
  String toString() => message;
}

/// The server's refusal because WhatsApp's 24-hour window has closed (GraphQL code or the upload routes' text).
bool isWindowClosedError(Object err) =>
    (err is ApiException && err.code == 'WINDOW_CLOSED') || RegExp('24-hour window closed', caseSensitive: false).hasMatch(err.toString());

/// Human text for any error thrown by the API layer.
String errorText(Object err) {
  if (err is ApiException) return err.message;
  if (err is NetworkException) return err.message;
  if (err is TimeoutException) return 'The server took too long to answer. Try again.';
  return 'Something went wrong. Try again.';
}

/// One client for everything the website calls: GraphQL at /graphql and the REST upload/download routes.
/// Same base address as the website (its Next.js server forwards these paths to the API).
class Api {
  Api({required this.baseUrl, this.onUnauthorized});

  String baseUrl;
  String? token;

  /// Called when the server says the token is no longer valid (expired, password changed, removed from workspace).
  void Function()? onUnauthorized;

  final http.Client _client = http.Client();

  Map<String, String> get authHeaders => token == null ? {} : {'Authorization': 'Bearer $token'};

  Uri uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final u = Uri.parse('$base$path');
    return query == null || query.isEmpty ? u : u.replace(queryParameters: {...u.queryParameters, ...query});
  }

  Future<http.Response> _send(Future<http.Response> Function() request, {Duration timeout = const Duration(seconds: 30)}) async {
    try {
      return await request().timeout(timeout);
    } on SocketException {
      throw NetworkException();
    } on http.ClientException {
      throw NetworkException();
    } on HandshakeException {
      throw NetworkException('Secure connection failed. Check the server address.');
    }
  }

  dynamic _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    if (text.isEmpty) return <String, dynamic>{};
    try {
      return jsonDecode(text);
    } catch (_) {
      // nginx's HTML 502 page or Next's plain-text 500 while the API restarts: the API itself always answers JSON
      if (res.statusCode >= 200 && res.statusCode < 300) return <String, dynamic>{};
      throw NetworkException('The server is temporarily unavailable (it may be restarting). Please try again in a moment.');
    }
  }

  /// GraphQL: returns `data`, or throws the first error with its code.
  Future<Map<String, dynamic>> gql(String query, [Map<String, dynamic>? variables]) async {
    final res = await _send(() => _client.post(
          uri('/graphql'),
          headers: {'Content-Type': 'application/json', ...authHeaders},
          body: jsonEncode({'query': query, 'variables': ?variables}),
        ));
    final json = _decode(res);
    final errors = json is Map ? json['errors'] : null;
    if (errors is List && errors.isNotEmpty) {
      final e = errors.first as Map;
      final code = (e['extensions'] as Map?)?['code'] as String?;
      if (code == 'UNAUTHENTICATED' && token != null) onUnauthorized?.call();
      throw ApiException(e['message']?.toString() ?? 'Request failed', code: code, status: res.statusCode);
    }
    final data = json is Map ? json['data'] : null;
    if (res.statusCode >= 400 || data is! Map) throw ApiException('Request failed (${res.statusCode})', status: res.statusCode);
    return Map<String, dynamic>.from(data);
  }

  /// POST a raw file body (the upload routes read the bytes as they are; the type is the Content-Type header).
  Future<Map<String, dynamic>> upload(String path, Uint8List bytes, String mime, {Map<String, String>? query}) async {
    final res = await _send(
      () => _client.post(uri(path, query), headers: {'Content-Type': mime, ...authHeaders}, body: bytes),
      timeout: const Duration(minutes: 10), // a 100 MB document is stored and sent on to WhatsApp before the answer
    );
    final json = _decode(res);
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode >= 400) {
      throw ApiException((json is Map ? json['error'] : null)?.toString() ?? 'Upload failed (${res.statusCode})', status: res.statusCode);
    }
    return Map<String, dynamic>.from(json as Map);
  }

  /// GET a protected file (message media, note files): the bytes and their type.
  Future<({Uint8List bytes, String mime})> download(String path) async {
    final res = await _send(() => _client.get(uri(path), headers: authHeaders), timeout: const Duration(minutes: 5));
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode >= 400) {
      String msg = res.statusCode == 404 ? 'File not available' : "Couldn't load the file (${res.statusCode})";
      try {
        final j = jsonDecode(utf8.decode(res.bodyBytes));
        if (j is Map && j['error'] is String) msg = j['error'];
      } catch (_) {}
      throw ApiException(msg, status: res.statusCode);
    }
    return (bytes: res.bodyBytes, mime: res.headers['content-type'] ?? 'application/octet-stream');
  }

  Future<bool> health() async {
    try {
      final res = await _client.get(uri('/health')).timeout(const Duration(seconds: 8));
      return res.statusCode == 200 && utf8.decode(res.bodyBytes).contains('ok');
    } catch (_) {
      return false;
    }
  }
}
