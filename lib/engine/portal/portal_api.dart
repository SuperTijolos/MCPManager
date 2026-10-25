import '../core/json.dart';
import '../server/server_client.dart';
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

/// The portal part of the server's API, with the signed-in session.
class PortalApi {
  PortalApi(this.client);

  final ServerClient client;

  Future<Object?> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
  }) async {
    try {
      return await client.send(method, path, body: body, query: query);
    } on ServerException catch (e) {
      throw PortalApiException(
        e.unauthorized
            ? 'Your session has ended. Sign in again.'
            : e.unreachable
            ? e.message
            : e.detail ?? _explain(e.code),
        status: e.status == 0 ? null : e.status,
        code: e.code,
      );
    }
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
}
