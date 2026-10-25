import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';

/// A failed request to the server. [status] is 0 when it could not be reached.
class ServerException implements Exception {
  ServerException(this.status, this.code, this.message, {this.detail});

  final int status;

  /// What the server itself said about it, when it said anything.
  final String? detail;

  /// The server's error code (`not_found`, `invalid_url`, ...) or
  /// `unreachable`.
  final String code;
  final String message;

  bool get unauthorized => status == 401;
  bool get unreachable => status == 0;

  @override
  String toString() => message;
}

/// One Server-Sent Event from `/api/events`.
class ServerEvent {
  const ServerEvent(this.type, this.data);
  final String type;
  final Json data;
}

/// Talks to the portal server as the signed-in person: every request carries
/// the session (or admin) token.
class ServerClient {
  ServerClient({
    required String baseUrl,
    required this.token,
    required http.Client httpClient,
    this.onUnauthorized,
  }) : baseUrl = normalizeServerUrl(baseUrl),
       _http = httpClient;

  final String baseUrl;
  final String token;
  final http.Client _http;

  /// Called when the server answers 401: the token is no longer good.
  final void Function()? onUnauthorized;

  Map<String, String> get _headers => {
    'authorization': 'Bearer $token',
    'accept': 'application/json',
  };

  Uri uri(String path, [Map<String, String?>? query]) {
    final base = Uri.parse(baseUrl);
    final q = {
      for (final e in (query ?? const {}).entries)
        if (e.value != null) e.key: e.value!,
    };
    return base.replace(
      path: '${base.path}$path'.replaceAll('//', '/'),
      queryParameters: q.isEmpty ? null : q,
    );
  }

  /// Sends a request and returns the decoded JSON (null for an empty reply).
  Future<Object?> send(
    String method,
    String path, {
    Object? body,
    Map<String, String?>? query,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final request = http.Request(method, uri(path, query))
      ..headers.addAll(_headers);
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.StreamedResponse response;
    final String text;
    try {
      response = await _http.send(request).timeout(timeout);
      text = await response.stream.bytesToString().timeout(timeout);
    } on TimeoutException {
      throw ServerException(
        0,
        'unreachable',
        'The server at $baseUrl did not answer in time.',
      );
    } on http.ClientException catch (e) {
      throw ServerException(0, 'unreachable', _unreachable(e.message));
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (text.trim().isEmpty) return null;
      try {
        return jsonDecode(text);
      } catch (_) {
        const message = 'The server sent something that is not JSON.';
        throw ServerException(
          response.statusCode,
          'bad_response',
          message,
          detail: message,
        );
      }
    }
    final decoded = tryDecodeObject(text);
    final error = ServerException(
      response.statusCode,
      decoded?['error'] as String? ?? 'http_${response.statusCode}',
      decoded?['message'] as String? ??
          _describe(response.statusCode, decoded?['error'] as String?),
      detail: decoded?['message'] as String?,
    );
    if (error.unauthorized) onUnauthorized?.call();
    throw error;
  }

  Future<Json> getMap(String path, {Map<String, String?>? query}) async {
    final r = await send('GET', path, query: query);
    if (r is Map) return r.cast<String, dynamic>();
    throw ServerException(
      200,
      'bad_response',
      'Expected an object from $path.',
    );
  }

  Future<List<Json>> getList(String path, {Map<String, String?>? query}) async {
    final r = await send('GET', path, query: query);
    if (r is List) {
      return [
        for (final e in r)
          if (e is Map) e.cast<String, dynamic>(),
      ];
    }
    throw ServerException(200, 'bad_response', 'Expected a list from $path.');
  }

  Future<Json> postMap(String path, [Object? body]) async {
    final r = await send('POST', path, body: body ?? const {});
    return r is Map ? r.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<Json> putMap(String path, Object body) async {
    final r = await send('PUT', path, body: body);
    return r is Map ? r.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<void> delete(String path, {Map<String, String?>? query}) =>
      send('DELETE', path, query: query);

  /// The server's live event stream. Ends when the connection drops; the
  /// caller reconnects (see `ServerEventStream`).
  Stream<ServerEvent> events() async* {
    final request = http.Request('GET', uri('/api/events'))
      ..headers.addAll({..._headers, 'accept': 'text/event-stream'});
    final http.StreamedResponse response;
    try {
      response = await _http.send(request);
    } on http.ClientException catch (e) {
      throw ServerException(0, 'unreachable', _unreachable(e.message));
    }
    if (response.statusCode == 401) {
      onUnauthorized?.call();
      throw ServerException(401, 'unauthorized', 'Sign in again.');
    }
    if (response.statusCode != 200) {
      throw ServerException(
        response.statusCode,
        'http_${response.statusCode}',
        'The event stream answered ${response.statusCode}.',
      );
    }
    var event = 'message';
    final data = StringBuffer();
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) {
          final decoded = tryDecodeObject(data.toString());
          if (decoded != null) yield ServerEvent(event, decoded);
        }
        event = 'message';
        data.clear();
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        data.write(line.substring(5).trim());
      }
    }
  }

  void close() => _http.close();

  String _unreachable(String detail) =>
      'Could not reach the server at $baseUrl ($detail). Check the address, '
      'that it is running, and that it allows this app\'s address '
      '(PORTAL_ALLOWED_ORIGINS).';

  String _describe(int status, String? code) => switch (status) {
    401 => 'Not signed in, or the session has ended.',
    403 => 'You are not allowed to do that.',
    404 => 'Not found.',
    413 => 'That is too large to send.',
    _ => 'The server answered HTTP $status${code == null ? '' : ' ($code)'}.',
  };
}

/// Cleans up an address someone typed: adds `http://` when missing and drops
/// trailing slashes.
String normalizeServerUrl(String raw) {
  var url = raw.trim();
  if (url.isEmpty) return url;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) {
    url = 'http://$url';
  }
  return url.replaceAll(RegExp(r'/+$'), '');
}
