import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'access.dart';
import 'admin_api.dart';
import 'audit.dart';
import 'chats.dart';
import 'config.dart';
import 'events.dart';
import 'health.dart';
import 'llm_api.dart';
import 'login.dart';
import 'db/database.dart';
import 'db/pg_audit.dart';
import 'db/pg_chats.dart';
import 'db/pg_state.dart';
import 'mcp_endpoint.dart';
import 'models.dart';
import 'oauth.dart';
import 'security.dart';
import 'state.dart';
import 'tool_caller.dart';
import 'upstream_oauth.dart';
import 'upstream.dart';

/// The whole gateway: portals, admin API and OAuth on one HTTP port.
class GatewayServer {
  GatewayServer._({
    required this.config,
    required this.store,
    required this.audit,
    required this.pool,
    required this.generatedAdminToken,
    required this.bus,
    required this.health,
    required this.upstreamOAuth,
    required this.chats,
    this.database,
    http.Client Function()? githubClient,
    http.Client Function()? llmClient,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    final authenticator = PortalAuthenticator(store, clock: clock);
    final adminToken = config.adminToken;
    _login = LoginService(
      store: store,
      config: config,
      baseUrl: _baseUrl,
      originAllowed: _originAllowed,
      httpClient: githubClient,
      clock: clock,
    );
    _caller = ToolCaller(pool: pool, audit: audit, clock: clock);
    _endpoint = McpEndpoint(
      store: store,
      pool: pool,
      auth: authenticator,
      caller: _caller,
      baseUrl: _baseUrl,
    );
    _admin = AdminApi(
      store: store,
      pool: pool,
      audit: audit,
      auth: authenticator,
      adminEnvToken: adminToken,
      baseUrl: _baseUrl,
      login: _login,
      bus: bus,
      caller: _caller,
      health: health,
      upstreamOAuth: upstreamOAuth,
      chats: chats,
      llm: LlmApi(store: store, httpClient: llmClient),
      maxChatsPerOwner: config.maxChatsPerOwner,
      heartbeat: config.eventHeartbeat,
      clock: clock,
    );
    _oauth = OAuthServer(
      store: store,
      auth: authenticator,
      baseUrl: _baseUrl,
      adminEnvToken: adminToken,
      login: _login,
      clock: clock,
    );
  }

  /// Connects to Postgres (applying any new migrations), or keeps everything
  /// in memory when [inMemory] (tests), and prepares the admin credential.
  static Future<GatewayServer> create(
    GatewayConfig config, {
    http.Client Function()? upstreamClient,
    http.Client Function()? githubClient,
    http.Client Function()? llmClient,
    DateTime Function()? clock,
    bool inMemory = false,
  }) async {
    Database? db;
    final StateStore store;
    final GatewayAuditLog rawAudit;
    final ChatRepository chats;
    if (inMemory) {
      store = StateStore.memory();
      rawAudit = GatewayAuditLog.memory();
      chats = ChatRepository.memory();
    } else {
      final url = config.databaseUrl;
      if (url == null || url.isEmpty) {
        throw ArgumentError(
          'DATABASE_URL is not set. Point it at a Postgres database, '
          'e.g. postgresql://user:pass@localhost:5432/mcp?sslmode=disable',
        );
      }
      db = Database.connect(url);
      try {
        await db.migrate(migrationsDirectory(config.migrationsDir));
        store = await StateStore.open(PgStatePersistence(db));
      } catch (_) {
        await db.close();
        rethrow;
      }
      rawAudit = PgAuditLog(db);
      chats = PgChatRepository(db);
    }
    final bus = EventBus();
    final audit = BroadcastAuditLog(rawAudit, bus);
    store.onChanged = (changed) =>
        bus.emit('changed', {'collections': changed});

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
    final pool = UpstreamPool(clientFactory: upstreamClient, clock: clock);
    final upstreamOAuth = UpstreamOAuth(
      store: store,
      bus: bus,
      audit: audit,
      onSessionChanged: pool.invalidate,
      httpClient: upstreamClient,
      clock: clock,
    );
    pool.tokenSource = upstreamOAuth.accessToken;
    // Remember what auto-detection found, so the next connect goes straight
    // there and the dashboard shows what is really in use.
    pool.onResolved = (server, transport, endpoint) {
      final current = store.state.server(server.id);
      if (current == null || current.url != server.url) return;
      store.update((s) {
        final i = s.servers.indexWhere((x) => x.id == server.id);
        if (i < 0 || s.servers[i].url != server.url) return;
        s.servers[i] = UpstreamServer(
          id: current.id,
          name: current.name,
          slug: current.slug,
          url: endpoint,
          headers: current.headers,
          transport: transport,
          enabled: current.enabled,
          oauth: current.oauth,
          oauthClientId: current.oauthClientId,
          oauthScope: current.oauthScope,
        );
      });
    };
    return GatewayServer._(
      config: config,
      store: store,
      audit: audit,
      pool: pool,
      upstreamOAuth: upstreamOAuth,
      chats: chats,
      health: HealthMonitor(
        store: store,
        pool: pool,
        bus: bus,
        audit: audit,
        interval: config.healthInterval,
        clock: clock,
      ),
      generatedAdminToken: generated,
      bus: bus,
      database: db,
      githubClient: githubClient,
      llmClient: llmClient,
      clock: clock,
    );
  }

  final GatewayConfig config;
  final StateStore store;
  final GatewayAuditLog audit;
  final UpstreamPool pool;
  final Database? database;
  final EventBus bus;
  final HealthMonitor health;
  final UpstreamOAuth upstreamOAuth;
  final ChatRepository chats;
  final DateTime Function() _clock;

  /// Set only on the first start without a configured admin token: the one
  /// moment the generated secret can be shown.
  final String? generatedAdminToken;

  late final LoginService _login;
  late final ToolCaller _caller;
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

    final login = await _login.handle(request);
    if (login != null) return login;
    final upstream = await upstreamOAuth.handle(request);
    if (upstream != null) return upstream;
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
            path == 'auth/config' ||
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
    health.start();
    return server;
  }

  Future<void> close() async {
    health.stop();
    await _http?.close(force: true);
    await pool.close();
    await audit.flush();
    await bus.close();
    await database?.close();
  }

  /// Exposed for tests that need the same clock.
  DateTime get now => _clock();
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
