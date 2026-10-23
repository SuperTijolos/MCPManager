import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'portal_models.dart';

/// The gateway said no, or could not be reached.
class PortalApiException implements Exception {
  PortalApiException(this.message, {this.status, this.code});

  final String message;

  /// The HTTP status, null when the gateway never answered.
  final int? status;
  final String? code;

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

/// A client for the gateway's admin API.
class PortalApi {
  PortalApi({
    required String baseUrl,
    required this.token,
    required this.client,
    this.timeout = const Duration(seconds: 30),
  }) : baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String baseUrl;
  final String token;
  final Duration timeout;
  final http.Client client;

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..headers['authorization'] = 'Bearer $token'
      ..headers['accept'] = 'application/json';
    if (body != null) {
      request.headers['content-type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await client.send(request).timeout(timeout),
      );
    } on http.ClientException catch (e) {
      throw PortalApiException(
        'Could not reach the gateway at $baseUrl (${e.message}). Check that it '
        'is running and, from a browser, that it allows this origin.',
      );
    } on Object catch (e) {
      throw PortalApiException('Could not reach the gateway at $baseUrl ($e).');
    }

    Object? decoded;
    if (response.body.isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (decoded == null && response.body.isNotEmpty) {
        throw PortalApiException(
          '$baseUrl did not answer like an MCP Manager gateway.',
          status: response.statusCode,
        );
      }
      return decoded;
    }
    final map = decoded is Map
        ? decoded.cast<String, dynamic>()
        : const <String, dynamic>{};
    final code = map['error'] as String?;
    throw PortalApiException(
      response.statusCode == 401
          ? 'The gateway rejected the admin token.'
          : (map['message'] as String?) ??
                (code == null
                    ? 'The gateway answered HTTP ${response.statusCode}.'
                    : _explain(code)),
      status: response.statusCode,
      code: code,
    );
  }

  static String _explain(String code) => switch (code) {
    'slug_in_use' => 'Another server already uses that name prefix.',
    'portal_slug_in_use' => 'Another portal already uses that address.',
    'invalid_slug' => 'Use lowercase letters, numbers and hyphens.',
    'invalid_url' => 'The URL must be a valid http(s) address.',
    'unknown_server' => 'A chosen server is not on the gateway.',
    'unknown_portal' => 'A chosen portal does not exist.',
    'server_not_found' => 'That server is not on the gateway.',
    'portal_not_found' => 'That portal does not exist.',
    'token_not_found' => 'That token does not exist.',
    _ => code.replaceAll('_', ' '),
  };

  Json _map(Object? v) => (v as Map).cast<String, dynamic>();
  List<Json> _list(Object? v) => [for (final x in (v as List)) _map(x)];

  Future<GatewayStatus> status() async =>
      GatewayStatus.fromJson(_map(await _send('GET', '/api/status')));

  // ----------------------------------------------------------------- servers

  Future<List<GatewayServer>> servers() async => [
    for (final j in _list(await _send('GET', '/api/servers')))
      GatewayServer.fromJson(j),
  ];

  /// Creates or replaces the server under [id]. [headers] are sent only when
  /// given; leaving them out keeps the ones the gateway has.
  Future<GatewayServer> saveServer({
    required String id,
    required String name,
    required String url,
    Map<String, String>? headers,
    String? transport,
    bool? enabled,
    String? slug,
  }) async => GatewayServer.fromJson(
    _map(
      await _send(
        'PUT',
        '/api/servers/${Uri.encodeComponent(id)}',
        body: {
          'name': name,
          'url': url,
          'headers': ?headers,
          'transport': ?transport,
          'enabled': ?enabled,
          'slug': ?slug,
        },
      ),
    ),
  );

  Future<void> deleteServer(String id) =>
      _send('DELETE', '/api/servers/${Uri.encodeComponent(id)}');

  Future<GatewayTestResult> testServer(String id) async =>
      GatewayTestResult.fromJson(
        _map(
          await _send('POST', '/api/servers/${Uri.encodeComponent(id)}/test'),
        ),
      );

  // ----------------------------------------------------------------- portals

  Future<List<GatewayPortal>> portals() async => [
    for (final j in _list(await _send('GET', '/api/portals')))
      GatewayPortal.fromJson(j),
  ];

  /// Creates a portal (no [id]) or updates one.
  Future<GatewayPortal> savePortal({
    String? id,
    required String name,
    String? slug,
    String? description,
    bool? enabled,
    List<GatewayPortalServer>? servers,
    List<String>? excludedTools,
  }) async {
    final body = {
      'name': name,
      'slug': ?slug,
      'description': ?description,
      'enabled': ?enabled,
      if (servers != null) 'servers': [for (final s in servers) s.toJson()],
      'excludedTools': ?excludedTools,
    };
    final json = id == null
        ? await _send('POST', '/api/portals', body: body)
        : await _send(
            'PUT',
            '/api/portals/${Uri.encodeComponent(id)}',
            body: body,
          );
    return GatewayPortal.fromJson(_map(json));
  }

  Future<void> deletePortal(String id) =>
      _send('DELETE', '/api/portals/${Uri.encodeComponent(id)}');

  Future<GatewayToolList> portalTools(
    String id, {
    bool includeHidden = false,
    bool refresh = false,
  }) async {
    final json = _map(
      await _send(
        'GET',
        '/api/portals/${Uri.encodeComponent(id)}/tools',
        query: {
          if (includeHidden) 'includeHidden': '1',
          if (refresh) 'refresh': '1',
        },
      ),
    );
    return GatewayToolList(
      [for (final t in _list(json['tools'])) GatewayTool.fromJson(t)],
      {
        for (final e in ((json['problems'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
    );
  }

  // ------------------------------------------------------------------ tokens

  Future<List<GatewayToken>> tokens() async => [
    for (final j in _list(await _send('GET', '/api/tokens')))
      GatewayToken.fromJson(j),
  ];

  Future<CreatedToken> createToken({
    required String name,
    List<String> portalIds = const [],
    int? expiresInDays,
  }) async {
    final json = _map(
      await _send(
        'POST',
        '/api/tokens',
        body: {
          'name': name,
          'portalIds': portalIds,
          'expiresInDays': ?expiresInDays,
        },
      ),
    );
    return CreatedToken(
      GatewayToken.fromJson(_map(json['token'])),
      json['secret'] as String,
    );
  }

  Future<void> revokeToken(String id) =>
      _send('DELETE', '/api/tokens/${Uri.encodeComponent(id)}');

  // ------------------------------------------------------------------- rules

  /// Replaces the gateway's rules and overrides (same format the app saves).
  Future<void> putRules(Json document) =>
      _send('PUT', '/api/rules', body: document);

  Future<Json> rules() async => _map(await _send('GET', '/api/rules'));

  // ------------------------------------------------------------------- audit

  Future<List<GatewayEvent>> audit({
    int limit = 100,
    String? portalId,
    String? status,
    String? query,
  }) async {
    final json = _map(
      await _send(
        'GET',
        '/api/audit',
        query: {
          'limit': '$limit',
          'portal': ?portalId,
          'status': ?status,
          if (query != null && query.isNotEmpty) 'q': query,
        },
      ),
    );
    return [for (final e in _list(json['events'])) GatewayEvent.fromJson(e)];
  }
}
