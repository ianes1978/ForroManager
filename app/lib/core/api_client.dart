import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';
import 'session_store.dart';

/// Client HTTP verso l'API: aggiunge il token, converte le risposte JSON e
/// traduce ogni problema in un [AppException] con un messaggio chiaro.
class ApiClient {
  ApiClient({required this.baseUrl, required this.store, http.Client? client})
      : _http = client ?? http.Client();

  final Uri baseUrl;
  final SessionStore store;
  final http.Client _http;

  /// Chiamato quando il server risponde 401: la sessione non è più valida.
  void Function()? onSessionExpired;

  static const _timeout = Duration(seconds: 20);

  Uri _uri(String path, [Map<String, Object?>? query]) {
    final q = <String, String>{
      for (final e in (query ?? const {}).entries)
        if (e.value != null) e.key: '${e.value}',
    };
    return baseUrl.replace(path: '/api/v1$path', queryParameters: q.isEmpty ? null : q);
  }

  Future<dynamic> get(String path, {Map<String, Object?>? query}) =>
      _send('GET', path, query: query);
  /// [idempotencyKey]: per le operazioni che registrano soldi o merce, così un
  /// nuovo tentativo dopo un errore di rete non le registra due volte.
  Future<dynamic> post(String path, [Object? body, String? idempotencyKey]) =>
      _send('POST', path, body: body ?? const {}, headers: {'Idempotency-Key': ?idempotencyKey});

  /// [version]: la versione (updatedAt) letta; se nel frattempo un altro ha
  /// salvato, il server risponde con un errore invece di sovrascrivere.
  Future<dynamic> put(String path, Object body, {String? version}) => _send('PUT', path, body: body, headers: {'If-Match': ?version});
  Future<dynamic> patch(String path, Object body, {String? version}) => _send('PATCH', path, body: body, headers: {'If-Match': ?version});

  /// Scarica un file (es. CSV) come byte.
  Future<List<int>> download(String path, {Map<String, Object?>? query}) async {
    final res = await _raw('GET', path, query: query);
    return res.bodyBytes;
  }

  Future<dynamic> _send(String method, String path, {Map<String, Object?>? query, Object? body, Map<String, String> headers = const {}}) async {
    final res = await _raw(method, path, query: query, body: body, headers: headers);
    if (res.statusCode == 204 || res.body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw const ServerException();
    }
  }

  Future<http.Response> _raw(String method, String path,
      {Map<String, Object?>? query, Object? body, Map<String, String> headers = const {}}) async {
    final token = await store.read();
    final request = http.Request(method, _uri(path, query));
    request.headers.addAll(headers);
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(request).timeout(_timeout));
    } on TimeoutException {
      throw const NetworkException();
    } on http.ClientException {
      throw const NetworkException();
    } on Exception catch (e) {
      // SocketException su mobile (dart:io non è disponibile sul web).
      if (e.runtimeType.toString() == 'SocketException') throw const NetworkException();
      rethrow;
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    throw _error(res, isLogin: path == '/auth/login');
  }

  AppException _error(http.Response res, {required bool isLogin}) {
    if (res.statusCode >= 500) return const ServerException();
    Map<String, dynamic>? error;
    try {
      error = (jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>)['error'] as Map<String, dynamic>?;
    } catch (_) {
      error = null;
    }
    if (res.statusCode == 401 && !isLogin && error?['code'] != 'invalid_credentials') {
      onSessionExpired?.call();
      return const SessionExpiredException();
    }
    if (error == null) return const ServerException();
    final fields = <String, String>{};
    final details = error['details'];
    if (details is List) {
      for (final d in details) {
        if (d is Map && d['field'] is String && d['message'] is String) {
          fields.putIfAbsent(d['field'] as String, () => d['message'] as String);
        }
      }
    }
    return ApiException(res.statusCode, error['code'] as String? ?? 'error',
        error['message'] as String? ?? 'Operazione non riuscita.', fields: fields);
  }
}
