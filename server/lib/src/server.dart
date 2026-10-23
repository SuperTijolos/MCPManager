import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'access.dart';
import 'admin_api.dart';
import 'audit.dart';
import 'config.dart';
import 'mcp_endpoint.dart';
import 'oauth.dart';
import 'security.dart';
import 'state.dart';
import 'upstream.dart';

/// The whole gateway: portals, admin API and OAuth on one HTTP port.
class GatewayServer {
  GatewayServer._({
    required this.config,
    required this.store,
    required this.audit,
    required this.pool,
    required this.generatedAdminToken,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    final authenticator = PortalAuthenticator(store, clock: clock);
    final adminToken = config.adminToken;
    _endpoint = McpEndpoint(
      store: store,
      pool: pool,
      auth: authenticator,
      audit: audit,
      baseUrl: _baseUrl,
      clock: clock,
    );
    _admin = AdminApi(
      store: store,
      pool: pool,
      audit: audit,
      auth: authenticator,
      adminEnvToken: adminToken,
      baseUrl: _baseUrl,
    );
    _oauth = OAuthServer(
      store: store,
      auth: authenticator,
      baseUrl: _baseUrl,
      adminEnvToken: adminToken,
      clock: clock,
    );
  }

  /// Opens the gateway's files in [GatewayConfig.dataDir] (or keeps everything
  /// in memory when [inMemory]) and prepares the admin credential.
  static Future<GatewayServer> create(
    GatewayConfig config, {
    http.Client Function()? upstreamClient,
    DateTime Function()? clock,
    bool inMemory = false,
  }) async {
    final dir = Directory(config.dataDir);
    final store = inMemory
        ? StateStore.memory()
        : await StateStore.open(File('${dir.path}/state.json'));
    final audit = inMemory
        ? GatewayAuditLog.memory()
        : await GatewayAuditLog.open(File('${dir.path}/audit.jsonl'));

    String? generated;
    final token = config.adminToken;
    if (token != null && token.isNotEmpty && token.length < 16) {
      throw ArgumentError('PORTAL_ADMIN_TOKEN must be at least 16 characters.');
    }
    if ((token == null || token.isEmpty) &&
        store.state.adminTokenHash == null) {
      generated = randomSecret(prefix: 'mcpadmin_');
      await store.update((s) => s.adminTokenHash = hashSecret(generated!));
    }
    return GatewayServer._(
      config: config,
      store: store,
      audit: audit,
      pool: UpstreamPool(clientFactory: upstreamClient, clock: clock),
      generatedAdminToken: generated,
      clock: clock,
    );
  }

  final GatewayConfig config;
  final StateStore store;
  final GatewayAuditLog audit;
  final UpstreamPool pool;
  final DateTime Function() _clock;

  /// Set only on the first start without a configured admin token: the one
  /// moment the generated secret can be shown.
  final String? generatedAdminToken;

  late final McpEndpoint _endpoint;
  late final AdminApi _admin;
  late final OAuthServer _oauth;
  HttpServer? _http;

  /// The origin clients should use for this request.
  String _baseUrl(Request request) {
    final configured = config.publicBaseUrl;
    if (configured != null && configured.isNotEmpty) return configured;
    final uri = request.requestedUri;
    final proto = request.headers['x-forwarded-proto'] ?? uri.scheme;
    final host =
        request.headers['x-forwarded-host'] ??
        request.headers['host'] ??
        uri.authority;
    return '$proto://$host';
  }

  Handler get handler => const Pipeline()
      .addMiddleware(_cors)
      .addMiddleware(_errors)
      .addHandler(_route);

  Future<Response> _route(Request request) async {
    final path = request.url.path;
    if (path == 'health' && request.method == 'GET') {
      return _json(200, {'ok': true, 'version': gatewayVersion});
    }
    final mcp = RegExp(r'^mcp/([^/]+)/?$').firstMatch(path);
    if (mcp != null) return _endpoint.handle(request, mcp.group(1)!);

    final oauth = await _oauth.handle(request);
    if (oauth != null) return oauth;
    final admin = await _admin.handle(request);
    if (admin != null) return admin;
    return _json(404, {'error': 'not_found'});
  }

  Middleware get _errors =>
      (inner) => (request) async {
        try {
          return await inner(request);
        } catch (_) {
          // Never leak internals (or a secret in an exception message) to a caller.
          return _json(500, {'error': 'internal_error'});
        }
      };

  /// MCP and OAuth endpoints are meant for any client, browsers included; the
  /// admin API only answers pages served from localhost or an allowed origin.
  Middleware get _cors =>
      (inner) => (request) async {
        final path = request.url.path;
        final origin = request.headers['origin'];
        final open =
            path.startsWith('mcp/') ||
            path == 'mcp' ||
            path.startsWith('.well-known/') ||
            path == 'oauth/token' ||
            path == 'oauth/register' ||
            path == 'health';
        final admin = path.startsWith('api/');

        Map<String, String> headers = const {};
        if (open) {
          headers = {
            'access-control-allow-origin': '*',
            'access-control-expose-headers': 'WWW-Authenticate',
          };
        } else if (admin && origin != null && _originAllowed(origin)) {
          headers = {'access-control-allow-origin': origin, 'vary': 'Origin'};
        }
        if ((open || admin) && request.method == 'OPTIONS') {
          return Response(
            204,
            headers: {
              ...headers,
              'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
              'access-control-allow-headers':
                  'authorization, content-type, accept, mcp-protocol-version, mcp-session-id',
              'access-control-max-age': '600',
            },
          );
        }
        final response = await inner(request);
        return response.change(
          headers: {...headers, 'x-content-type-options': 'nosniff'},
        );
      };

  bool _originAllowed(String origin) {
    if (config.allowedOrigins.contains(origin)) return true;
    final host = Uri.tryParse(origin)?.host;
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '[::1]' ||
        host == '::1';
  }

  /// Listens on [GatewayConfig.host]:[GatewayConfig.port] (0 picks a free one).
  Future<HttpServer> start() async {
    final server = await shelf_io.serve(handler, config.host, config.port);
    _http = server;
    return server;
  }

  Future<void> close() async {
    await _http?.close(force: true);
    await pool.close();
    await audit.flush();
  }

  /// Exposed for tests that need the same clock.
  DateTime get now => _clock();
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
