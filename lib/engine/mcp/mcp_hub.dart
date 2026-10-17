import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/audit_log.dart';
import '../audit/audit_models.dart';
import '../core/ids.dart';
import '../core/json.dart';
import '../core/prefs.dart';
import '../core/redact.dart';
import 'mcp_auto_connection.dart';
import 'mcp_connection.dart';
import 'mcp_http.dart';
import 'mcp_models.dart';
import 'oauth/oauth_flow.dart';
import 'oauth/oauth_models.dart';
import 'oauth/oauth_popup.dart';
import 'oauth/oauth_service.dart';

export 'mcp_http.dart' show mcpHttpClientFactoryProvider;

const _storageKey = 'mcpm.servers.v1';

enum ServerStatus { idle, connecting, connected, needsAuth, error, disabled }

class ServerRuntime {
  const ServerRuntime({
    required this.config,
    this.status = ServerStatus.idle,
    this.info,
    this.tools = const [],
    this.error,
    this.latencyMs,
    this.checkedAt,
    this.authChallenge,
  });

  final McpServerConfig config;
  final ServerStatus status;
  final McpServerInfo? info;
  final List<McpTool> tools;
  final String? error;
  final int? latencyMs;
  final DateTime? checkedAt;

  /// `WWW-Authenticate` header from the last 401, used to find the OAuth
  /// metadata when the user signs in.
  final String? authChallenge;

  ServerRuntime copyWith({
    McpServerConfig? config,
    ServerStatus? status,
    McpServerInfo? info,
    List<McpTool>? tools,
    String? error,
    bool clearError = false,
    int? latencyMs,
    DateTime? checkedAt,
    String? authChallenge,
  }) => ServerRuntime(
    config: config ?? this.config,
    status: status ?? this.status,
    info: info ?? this.info,
    tools: tools ?? this.tools,
    error: clearError ? null : error ?? this.error,
    latencyMs: latencyMs ?? this.latencyMs,
    checkedAt: checkedAt ?? this.checkedAt,
    authChallenge: clearError ? null : authChallenge ?? this.authChallenge,
  );
}

class ToolRef {
  const ToolRef(this.server, this.tool);
  final McpServerConfig server;
  final McpTool tool;
}

class McpHubState {
  const McpHubState(this.servers);
  final List<ServerRuntime> servers;

  ServerRuntime? byId(String id) {
    for (final s in servers) {
      if (s.config.id == id) return s;
    }
    return null;
  }

  int get connectedCount =>
      servers.where((s) => s.status == ServerStatus.connected).length;

  /// Tools from connected, enabled servers only.
  List<ToolRef> get availableTools => [
    for (final s in servers)
      if (s.status == ServerStatus.connected)
        for (final t in s.tools) ToolRef(s.config, t),
  ];
}

final mcpHubProvider = NotifierProvider<McpHub, McpHubState>(McpHub.new);

class McpHub extends Notifier<McpHubState> {
  final _clients = <String, McpConnection>{};

  @override
  McpHubState build() {
    ref.onDispose(() {
      for (final client in _clients.values) {
        client.close();
      }
      _clients.clear();
    });

    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    final servers = <ServerRuntime>[];
    if (raw is List) {
      for (final item in raw) {
        try {
          final config = McpServerConfig.fromJson(
            (item as Map).cast<String, dynamic>(),
          );
          servers.add(
            ServerRuntime(
              config: config,
              status: config.enabled
                  ? ServerStatus.idle
                  : ServerStatus.disabled,
            ),
          );
        } catch (_) {
          // Skip entries from an incompatible version.
        }
      }
    }
    Future.microtask(connectAll);
    return McpHubState(servers);
  }

  Future<void> connectAll() async {
    await Future.wait([
      for (final s in state.servers)
        if (s.config.enabled && s.status == ServerStatus.idle)
          connect(s.config.id),
    ]);
  }

  Future<ServerRuntime> addServer({
    required String name,
    required String url,
    Map<String, String> headers = const {},
    bool oauth = false,
    String? oauthClientId,
    String? oauthScope,
    McpTransport transport = McpTransport.auto,
  }) async {
    final config = McpServerConfig(
      id: newId('srv'),
      name: name,
      url: url,
      headers: headers,
      oauth: oauth,
      oauthClientId: oauthClientId,
      oauthScope: oauthScope,
      transport: transport,
    );
    state = McpHubState([...state.servers, ServerRuntime(config: config)]);
    _persist();
    await connect(config.id);
    return state.byId(config.id)!;
  }

  Future<void> updateServer(McpServerConfig config) async {
    final previous = state.byId(config.id)?.config;
    if (previous != null &&
        (previous.url != config.url || (previous.oauth && !config.oauth))) {
      // Tokens are bound to one resource; don't carry them to another server.
      ref.read(oauthServiceProvider).forget(config.id);
    }
    _setRuntime(
      config.id,
      (r) => r.copyWith(config: config, tools: const [], clearError: true),
    );
    _persist();
    _disposeClient(config.id);
    if (config.enabled) {
      await connect(config.id);
    } else {
      _setRuntime(config.id, (r) => r.copyWith(status: ServerStatus.disabled));
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final runtime = state.byId(id);
    if (runtime == null) return;
    await updateServer(runtime.config.copyWith(enabled: enabled));
  }

  void removeServer(String id) {
    _disposeClient(id);
    ref.read(oauthServiceProvider).forget(id);
    state = McpHubState([
      for (final s in state.servers)
        if (s.config.id != id) s,
    ]);
    _persist();
  }

  /// (Re)connects, runs discovery and records the outcome in the audit log.
  Future<void> connect(String id) async {
    final runtime = state.byId(id);
    if (runtime == null || !runtime.config.enabled) return;

    _disposeClient(id);
    _setRuntime(
      id,
      (r) => r.copyWith(status: ServerStatus.connecting, clearError: true),
    );

    final config = runtime.config;
    final oauth = ref.read(oauthServiceProvider);
    final client = createMcpConnection(
      config,
      httpClient: ref.read(mcpHttpClientFactoryProvider)(),
      tokenProvider: config.oauth
          ? ({bool forceRefresh = false}) =>
                oauth.accessToken(id, forceRefresh: forceRefresh)
          : null,
    );
    final watch = Stopwatch()..start();
    try {
      final info = await client.connect();
      final tools = await client.listTools();
      watch.stop();
      if (!ref.mounted) {
        client.close();
        return;
      }
      _clients[id] = client;
      // Remember what auto-detection found (transport, and the endpoint when
      // a bare host:port resolved to /mcp or /sse) so the next connect is
      // direct and the user can see what is in use.
      final resolved = config.copyWith(
        transport: client.transport,
        url: client.endpointUrl,
      );
      final detected =
          resolved.transport != config.transport || resolved.url != config.url;
      _setRuntime(
        id,
        (r) => r.copyWith(
          config: detected ? resolved : null,
          status: ServerStatus.connected,
          info: info,
          tools: tools,
          latencyMs: watch.elapsedMilliseconds,
          checkedAt: DateTime.now(),
          clearError: true,
        ),
      );
      if (detected) _persist();
      ref
          .read(auditLogProvider.notifier)
          .record(
            kind: AuditKind.serverConnect,
            status: AuditStatus.success,
            source: AuditSource.system,
            actor: 'system',
            serverId: id,
            serverName: config.name,
            durationMs: watch.elapsedMilliseconds,
            result: '${info.name} ${info.version} · ${tools.length} tools',
          );
    } on McpAuthRequired catch (e) {
      // A static token that is rejected is a plain error; anything else means
      // the user can sign in with OAuth.
      final needsSignIn = config.oauth || !config.hasStaticAuthorization;
      _failConnect(
        id,
        config,
        client,
        e.message,
        watch,
        needsAuth: needsSignIn,
        challenge: e.wwwAuthenticate,
      );
    } on McpException catch (e) {
      _failConnect(id, config, client, e.message, watch);
    } catch (e) {
      _failConnect(id, config, client, '$e', watch);
    }
  }

  void _failConnect(
    String id,
    McpServerConfig config,
    McpConnection client,
    String message,
    Stopwatch watch, {
    bool needsAuth = false,
    String? challenge,
  }) {
    watch.stop();
    client.close();
    if (!ref.mounted) return;
    _setRuntime(
      id,
      (r) => r.copyWith(
        status: needsAuth ? ServerStatus.needsAuth : ServerStatus.error,
        error: message,
        tools: const [],
        checkedAt: DateTime.now(),
        authChallenge: challenge,
      ),
    );
    ref
        .read(auditLogProvider.notifier)
        .record(
          kind: AuditKind.serverConnect,
          status: AuditStatus.error,
          source: AuditSource.system,
          actor: 'system',
          serverId: id,
          serverName: config.name,
          durationMs: watch.elapsedMilliseconds,
          error: redactText(message),
        );
  }

  /// Signs in to [id] with OAuth using [popup] (opened by the caller inside a
  /// click handler), then reconnects. Returns an error message, or null.
  Future<String?> authorize(String id, OAuthPopup popup) async {
    final runtime = state.byId(id);
    if (runtime == null) {
      popup.close();
      return 'Unknown server.';
    }
    var config = runtime.config;
    if (!config.oauth) {
      config = config.copyWith(oauth: true);
      _setRuntime(id, (r) => r.copyWith(config: config));
      _persist();
    }
    final audit = ref.read(auditLogProvider.notifier);
    final watch = Stopwatch()..start();
    try {
      await ref
          .read(oauthServiceProvider)
          .authorize(
            config: config,
            popup: popup,
            challenge: parseBearerChallenge(runtime.authChallenge),
          );
      watch.stop();
      if (!ref.mounted) return null;
      audit.record(
        kind: AuditKind.authorize,
        status: AuditStatus.success,
        source: AuditSource.system,
        actor: 'user',
        serverId: id,
        serverName: config.name,
        durationMs: watch.elapsedMilliseconds,
        result: 'OAuth sign-in completed',
      );
      await connect(id);
      return null;
    } on OAuthException catch (e) {
      watch.stop();
      if (!ref.mounted) return e.message;
      audit.record(
        kind: AuditKind.authorize,
        status: AuditStatus.error,
        source: AuditSource.system,
        actor: 'user',
        serverId: id,
        serverName: config.name,
        durationMs: watch.elapsedMilliseconds,
        error: redactText(e.message),
      );
      return e.message;
    }
  }

  /// Forgets the OAuth tokens for [id] and disconnects it.
  void signOut(String id) {
    final runtime = state.byId(id);
    if (runtime == null) return;
    ref.read(oauthServiceProvider).signOut(id);
    _disposeClient(id);
    _setRuntime(
      id,
      (r) => r.copyWith(
        status: ServerStatus.needsAuth,
        tools: const [],
        error: 'Signed out.',
      ),
    );
    ref
        .read(auditLogProvider.notifier)
        .record(
          kind: AuditKind.authorize,
          status: AuditStatus.success,
          source: AuditSource.system,
          actor: 'user',
          serverId: id,
          serverName: runtime.config.name,
          result: 'Signed out',
        );
  }

  /// Calls a tool and always records an audit event. Failures come back as an
  /// error [McpToolResult] rather than an exception so callers (the workbench
  /// and the operator agent) can show them uniformly.
  Future<McpToolResult> callTool({
    required String serverId,
    required String toolName,
    required Json args,
    required AuditSource source,
    required String actor,
    String? approval,
  }) async {
    final runtime = state.byId(serverId);
    final audit = ref.read(auditLogProvider.notifier);
    final argsPreview = redactedPreview(args);
    final client = _clients[serverId];

    // A legacy-SSE connection whose stream dropped reconnects by itself on use.
    if (runtime == null || client == null) {
      const message = 'Server is not connected.';
      audit.record(
        kind: AuditKind.toolCall,
        status: AuditStatus.error,
        source: source,
        actor: actor,
        serverId: serverId,
        serverName: runtime?.config.name,
        toolName: toolName,
        args: argsPreview,
        error: message,
        approval: approval,
      );
      return McpToolResult.error(message);
    }

    final watch = Stopwatch()..start();
    try {
      final result = await client.callTool(toolName, args);
      watch.stop();
      if (!ref.mounted) return result;
      audit.record(
        kind: AuditKind.toolCall,
        status: result.isError ? AuditStatus.error : AuditStatus.success,
        source: source,
        actor: actor,
        serverId: serverId,
        serverName: runtime.config.name,
        toolName: toolName,
        durationMs: watch.elapsedMilliseconds,
        args: argsPreview,
        result: redactedPreview(result.text),
        error: result.isError ? redactedPreview(result.text, max: 500) : null,
        approval: approval,
      );
      return result;
    } on McpException catch (e) {
      watch.stop();
      if (!ref.mounted) return McpToolResult.error(e.message);
      audit.record(
        kind: AuditKind.toolCall,
        status: AuditStatus.error,
        source: source,
        actor: actor,
        serverId: serverId,
        serverName: runtime.config.name,
        toolName: toolName,
        durationMs: watch.elapsedMilliseconds,
        args: argsPreview,
        error: redactText(e.message),
        approval: approval,
      );
      return McpToolResult.error(e.message);
    }
  }

  /// Records a call the human refused, so the audit trail shows the attempt.
  void recordDenied({
    required String serverId,
    required String toolName,
    required Json args,
    required String actor,
  }) {
    ref
        .read(auditLogProvider.notifier)
        .record(
          kind: AuditKind.toolCall,
          status: AuditStatus.denied,
          source: AuditSource.operator,
          actor: actor,
          serverId: serverId,
          serverName: state.byId(serverId)?.config.name,
          toolName: toolName,
          args: redactedPreview(args),
          approval: 'denied',
        );
  }

  void _disposeClient(String id) {
    _clients.remove(id)?.close();
  }

  void _setRuntime(String id, ServerRuntime Function(ServerRuntime) update) {
    state = McpHubState([
      for (final s in state.servers) s.config.id == id ? update(s) : s,
    ]);
  }

  void _persist() {
    writeJson(ref.read(sharedPreferencesProvider), _storageKey, [
      for (final s in state.servers) s.config.toJson(),
    ]);
  }
}
