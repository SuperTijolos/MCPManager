import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audit/audit_log.dart';
import '../audit/audit_models.dart';
import '../core/json.dart';
import '../core/redact.dart';
import '../server/platform.dart';
import '../server/server_client.dart';
import '../server/server_events.dart';
import '../server/session.dart';
import 'mcp_models.dart';

/// What the dashboard shows for a header value: the server keeps the real
/// value and never sends it back. Sending this back means "leave it as it is".
const maskedHeaderValue = '••••••••';

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
    this.trace = const [],
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

  /// Requests and statuses of the last connection attempt, for diagnosis.
  final List<String> trace;

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
    List<String>? trace,
  }) => ServerRuntime(
    config: config ?? this.config,
    status: status ?? this.status,
    info: info ?? this.info,
    tools: tools ?? this.tools,
    error: clearError ? null : error ?? this.error,
    latencyMs: latencyMs ?? this.latencyMs,
    checkedAt: checkedAt ?? this.checkedAt,
    authChallenge: clearError ? null : authChallenge ?? this.authChallenge,
    trace: trace ?? this.trace,
  );
}

class ToolRef {
  const ToolRef(this.server, this.tool);
  final McpServerConfig server;
  final McpTool tool;
}

/// What a trial connection found, without saving anything.
class ProbeResult {
  const ProbeResult({
    this.connected = false,
    this.needsAuth = false,
    this.error,
    this.info,
    this.toolCount = 0,
    this.transport,
    this.endpoint,
    this.latencyMs,
    this.trace = const [],
  });

  /// The handshake and tool listing both worked.
  final bool connected;

  /// The server answered but wants credentials (so it is reachable).
  final bool needsAuth;
  final String? error;
  final McpServerInfo? info;
  final int toolCount;
  final McpTransport? transport;
  final String? endpoint;
  final int? latencyMs;
  final List<String> trace;
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

  /// Enabled servers that are neither connected nor already connecting.
  List<ServerRuntime> get unavailable => [
    for (final s in servers)
      if (s.config.enabled &&
          s.status != ServerStatus.connected &&
          s.status != ServerStatus.connecting)
        s,
  ];

  /// Tools from connected, enabled servers only.
  List<ToolRef> get availableTools => [
    for (final s in servers)
      if (s.status == ServerStatus.connected)
        for (final t in s.tools) ToolRef(s.config, t),
  ];
}

final mcpHubProvider = NotifierProvider<McpHub, McpHubState>(McpHub.new);

/// The servers the gateway holds, and what it knows about them. The dashboard
/// never talks to an MCP server itself: it asks the gateway, which connects,
/// signs in, lists tools and runs calls, and records every call.
class McpHub extends Notifier<McpHubState> {
  ServerClient? _client;
  final _connecting = <String>{};
  final _oauthWaiters = <String, Completer<void>>{};
  Completer<void>? _loaded;
  Timer? _debounce;

  /// Bumped by every change made here, so a reload that started before the
  /// change does not put the old list back.
  var _generation = 0;

  /// Completes when the first load from the server has finished.
  Future<void> get loaded => (_loaded ??= Completer<void>()).future;

  @override
  McpHubState build() {
    _client = ref.watch(serverClientProvider);
    ref.onDispose(() => _debounce?.cancel());
    listenToServer(ref, _onEvent);
    _loaded = Completer<void>();
    if (_client != null) {
      Future.microtask(() async {
        await refresh();
        if (ref.mounted && !(_loaded?.isCompleted ?? true)) {
          _loaded!.complete();
        }
      });
    } else {
      _loaded!.complete();
    }
    return const McpHubState([]);
  }

  ServerClient get _api =>
      _client ?? (throw StateError('Not signed in to a server.'));

  void _onEvent(ServerEvent e) {
    switch (e.type) {
      case 'ready':
      case 'health':
        _later(refresh);
      case 'changed':
        final what = (e.data['collections'] as List?) ?? const [];
        if (what.contains('servers') || what.contains('upstreamOAuth')) {
          _later(refresh);
        }
      case 'oauth':
        final id = '${e.data['serverId']}';
        _oauthWaiters[id]?.complete();
        _later(refresh);
    }
  }

  /// Several events in a burst cause one reload.
  void _later(Future<void> Function() reload) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 150), () {
      if (ref.mounted) unawaited(reload());
    });
  }

  /// Reloads the servers, their health and their tools from the server.
  /// [refresh] asks the gateway to look at the servers again first.
  Future<void> refresh({bool recheck = false}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final generation = _generation;
      if (await _refreshOnce(recheck: recheck, generation: generation)) return;
    }
  }

  /// Returns false when a local change made the result stale.
  Future<bool> _refreshOnce({
    required bool recheck,
    required int generation,
  }) async {
    final client = _client;
    if (client == null) return true;
    try {
      if (recheck) {
        await client.send('POST', '/api/health/check');
      }
      final list = await client.getList('/api/servers');
      if (!ref.mounted) return true;
      if (generation != _generation) return false;
      final previous = {for (final s in state.servers) s.config.id: s};
      // Show the servers at once; the tools follow.
      state = McpHubState([
        for (final j in list)
          _runtimeFor(j, previous[j['id']], connecting: j['enabled'] != false),
      ]);
      final tools = await client.getMap('/api/tools');
      final health = await client.getMap('/api/health');
      if (!ref.mounted) return true;
      if (generation != _generation) return false;
      final byId = {
        for (final t in (tools['servers'] as List? ?? const []))
          (t as Map)['id'] as String: t.cast<String, dynamic>(),
      };
      final healthById = ((health['servers'] as Map?) ?? const {})
          .cast<String, dynamic>();
      final signedIn = <String, bool>{};
      await Future.wait([
        for (final j in list)
          if (j['oauth'] == true)
            client
                .getMap('/api/servers/${j['id']}/oauth')
                .then((r) => signedIn['${j['id']}'] = r['signedIn'] == true)
                .catchError((_) => false),
      ]);
      if (!ref.mounted) return true;
      if (generation != _generation) return false;
      state = McpHubState([
        for (final j in list)
          _withCatalog(
            _runtimeFor(j, previous[j['id']]),
            byId[j['id']],
            healthById[j['id']] as Map?,
            oauthSignedIn: signedIn[j['id']],
          ),
      ]);
      return true;
    } on ServerException {
      // Keep what is shown; the next event or refresh tries again.
      return true;
    }
  }

  ServerRuntime _runtimeFor(
    Json j,
    ServerRuntime? previous, {
    bool connecting = false,
  }) {
    final config = _configFrom(j);
    final enabled = config.enabled;
    return (previous ?? ServerRuntime(config: config)).copyWith(
      config: config,
      status: !enabled
          ? ServerStatus.disabled
          : connecting
          ? ServerStatus.connecting
          : previous?.status ?? ServerStatus.idle,
    );
  }

  ServerRuntime _withCatalog(
    ServerRuntime base,
    Json? catalog,
    Map? health, {
    bool? oauthSignedIn,
  }) {
    final config = base.config;
    if (!config.enabled) return base.copyWith(status: ServerStatus.disabled);
    if (catalog == null) return base;
    final tools = [
      for (final t in (catalog['tools'] as List? ?? const []))
        McpTool.fromJson((t as Map).cast<String, dynamic>()),
    ];
    final error = catalog['error'] as String?;
    final info = catalog['server'] as Map?;
    final checked = DateTime.tryParse('${health?['checkedAt'] ?? ''}');
    // The server keeps listing a failing server's last tools for its portals;
    // the dashboard shows it as down.
    if (error != null) {
      final needsAuth =
          (config.oauth && oauthSignedIn != true) ||
          RegExp(
            r'sign-?in is required|HTTP 401',
            caseSensitive: false,
          ).hasMatch(error);
      return base.copyWith(
        trace: [for (final t in (catalog['trace'] as List? ?? const [])) '$t'],
        status: needsAuth && !config.hasStaticAuthorization
            ? ServerStatus.needsAuth
            : needsAuth && config.oauth
            ? ServerStatus.needsAuth
            : ServerStatus.error,
        error: error,
        tools: const [],
        checkedAt: checked ?? DateTime.now(),
      );
    }
    return base.copyWith(
      status: ServerStatus.connected,
      info: info == null
          ? null
          : McpServerInfo(
              name: '${info['name'] ?? config.name}',
              version: '${info['version'] ?? ''}',
              protocolVersion: '',
            ),
      tools: tools,
      checkedAt: checked ?? DateTime.now(),
      clearError: true,
      trace: [for (final t in (catalog['trace'] as List? ?? const [])) '$t'],
      config: _resolved(
        config,
        catalog['transport'] as String?,
        catalog['endpoint'] as String?,
      ),
    );
  }

  /// What auto-detection found (the transport, and the address when a bare
  /// host resolved to a path), so the dialog shows what is in use.
  McpServerConfig _resolved(
    McpServerConfig c,
    String? transport,
    String? endpoint,
  ) => c.copyWith(
    transport: transport == null ? null : McpTransport.parse(transport),
    url: endpoint,
  );

  McpServerConfig _configFrom(Json j) => McpServerConfig(
    id: j['id'] as String,
    name: j['name'] as String,
    url: j['url'] as String,
    headers: {
      for (final n in (j['headerNames'] as List? ?? const []))
        '$n': maskedHeaderValue,
    },
    enabled: j['enabled'] as bool? ?? true,
    oauth: j['oauth'] as bool? ?? false,
    oauthClientId: j['oauthClientId'] as String?,
    oauthScope: j['oauthScope'] as String?,
    transport: McpTransport.parse(j['transport']),
  );

  Json _bodyFor(McpServerConfig c, {bool withName = true}) => {
    if (withName) 'name': c.name,
    'url': c.url,
    // A value left masked is sent as null: the server keeps what it has.
    'headers': {
      for (final e in c.headers.entries)
        e.key: e.value == maskedHeaderValue ? null : e.value,
    },
    'transport': c.transport.wire,
    'enabled': c.enabled,
    'oauth': c.oauth,
    'oauthClientId': c.oauthClientId,
    'oauthScope': c.oauthScope,
  };

  Future<void> connectAll() => refresh();

  /// Asks the gateway to look at one server again.
  Future<void> connect(String id) async {
    final client = _client;
    final runtime = state.byId(id);
    if (client == null || runtime == null || !runtime.config.enabled) return;
    _connecting.add(id);
    _setRuntime(id, (r) => r.copyWith(status: ServerStatus.connecting));
    final watch = Stopwatch()..start();
    try {
      final catalog = await client.getMap(
        '/api/servers/$id/tools',
        query: {'refresh': '1'},
      );
      watch.stop();
      if (!ref.mounted) return;
      var signedIn = true;
      if (runtime.config.oauth) {
        signedIn =
            (await client.getMap('/api/servers/$id/oauth'))['signedIn'] == true;
      }
      _setRuntime(
        id,
        (r) => _withCatalog(
          r,
          catalog,
          null,
          oauthSignedIn: signedIn,
        ).copyWith(latencyMs: watch.elapsedMilliseconds),
      );
      await ref.read(auditLogProvider.notifier).catchUp();
    } on ServerException catch (e) {
      if (!ref.mounted) return;
      _setRuntime(
        id,
        (r) => r.copyWith(
          status: ServerStatus.error,
          error: e.message,
          tools: const [],
          checkedAt: DateTime.now(),
        ),
      );
    } finally {
      _connecting.remove(id);
    }
  }

  /// Retries the servers that are down. When everything is up it re-checks
  /// every enabled server instead, so a refresh never disturbs a working
  /// server while another one needs a retry.
  Future<void> reconnectUnavailable() async {
    final down = state.unavailable;
    if (down.isEmpty) return refresh(recheck: true);
    await Future.wait([for (final s in down) connect(s.config.id)]);
  }

  /// Has the gateway look at every server again now.
  Future<void> checkHealth() => refresh(recheck: true);

  Future<ServerRuntime> addServer({
    required String name,
    required String url,
    Map<String, String> headers = const {},
    bool oauth = false,
    String? oauthClientId,
    String? oauthScope,
    McpTransport transport = McpTransport.auto,
  }) async {
    await loaded;
    _generation++;
    final created = await _api.postMap('/api/servers', {
      'name': name,
      'url': url,
      'headers': headers,
      'oauth': oauth,
      'oauthClientId': oauthClientId,
      'oauthScope': oauthScope,
      'transport': transport.wire,
    });
    final config = _configFrom(created);
    state = McpHubState([...state.servers, ServerRuntime(config: config)]);
    await connect(config.id);
    return state.byId(config.id)!;
  }

  Future<void> updateServer(McpServerConfig config) async {
    _generation++;
    final updated = await _api.putMap(
      '/api/servers/${config.id}',
      _bodyFor(config),
    );
    final fresh = _configFrom(updated);
    _setRuntime(
      fresh.id,
      (r) => r.copyWith(config: fresh, tools: const [], clearError: true),
    );
    if (fresh.enabled) {
      await connect(fresh.id);
    } else {
      _setRuntime(fresh.id, (r) => r.copyWith(status: ServerStatus.disabled));
    }
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final runtime = state.byId(id);
    if (runtime == null) return;
    await updateServer(runtime.config.copyWith(enabled: enabled));
  }

  Future<void> removeServer(String id) async {
    _generation++;
    await _api.delete('/api/servers/$id');
    state = McpHubState([
      for (final s in state.servers)
        if (s.config.id != id) s,
    ]);
  }

  /// Tries [config] without saving it: "Test connection" in the server
  /// dialog. [signedInAs] lets an existing OAuth server reuse its sign-in
  /// (and the header values the gateway already holds).
  Future<ProbeResult> probe(
    McpServerConfig config, {
    String? signedInAs,
  }) async {
    try {
      final r = await _api.postMap('/api/servers/probe', {
        'serverId': ?signedInAs,
        ..._bodyFor(config, withName: false),
      });
      final info = (r['server'] as Map?)?.cast<String, dynamic>();
      return ProbeResult(
        connected: r['connected'] == true,
        needsAuth: r['needsAuth'] == true,
        error: r['error'] as String?,
        info: info == null
            ? null
            : McpServerInfo(
                name: '${info['name'] ?? ''}',
                version: '${info['version'] ?? ''}',
                protocolVersion: '',
              ),
        toolCount: (r['toolCount'] as num?)?.toInt() ?? 0,
        transport: r['transport'] == null
            ? null
            : McpTransport.parse(r['transport']),
        endpoint: r['endpoint'] as String?,
        latencyMs: (r['latencyMs'] as num?)?.toInt(),
        trace: [for (final t in (r['trace'] as List? ?? const [])) '$t'],
      );
    } on ServerException catch (e) {
      return ProbeResult(error: e.message);
    }
  }

  /// Signs the gateway in to [id] with OAuth. [popup] was opened by the caller
  /// inside a click handler; it is pointed at the server's sign-in page, and
  /// this waits for the gateway to report the sign-in (or the window to be
  /// closed). Returns an error message, or null.
  Future<String?> authorize(String id, AuthPopup popup) async {
    final runtime = state.byId(id);
    if (runtime == null) {
      popup.close();
      return 'Unknown server.';
    }
    try {
      if (!runtime.config.oauth) {
        await updateServer(runtime.config.copyWith(oauth: true));
      }
      final started = await _api.postMap('/api/servers/$id/oauth/start');
      final url = started['authorizeUrl'] as String?;
      if (url == null) return 'The server gave no sign-in address.';
      popup.navigate(Uri.parse(url));

      final waiter = _oauthWaiters[id] = Completer<void>();
      var closedByPerson = false;
      unawaited(popup.closed.then((_) => closedByPerson = true));
      final deadline = DateTime.now().add(const Duration(minutes: 5));
      while (DateTime.now().isBefore(deadline)) {
        await Future.any([
          waiter.future,
          Future<void>.delayed(const Duration(seconds: 1)),
        ]);
        if (!ref.mounted) return null;
        final status = await _api.getMap('/api/servers/$id/oauth');
        if (status['signedIn'] == true) {
          await connect(id);
          await ref.read(auditLogProvider.notifier).catchUp();
          return null;
        }
        if (closedByPerson) {
          return 'The sign-in window was closed before finishing.';
        }
      }
      return 'Sign-in timed out.';
    } on ServerException catch (e) {
      return e.message;
    } finally {
      _oauthWaiters.remove(id);
      popup.close();
    }
  }

  /// Forgets the gateway's OAuth tokens for [id].
  Future<void> signOut(String id) async {
    if (state.byId(id) == null) return;
    await _api.delete('/api/servers/$id/oauth');
    await ref.read(auditLogProvider.notifier).catchUp();
    _setRuntime(
      id,
      (r) => r.copyWith(
        status: ServerStatus.needsAuth,
        tools: const [],
        error: 'Signed out.',
      ),
    );
  }

  /// Calls a tool through the gateway, which applies the rules and records the
  /// call. Failures come back as an error [McpToolResult], so the workbench
  /// and the Operator show them the same way.
  ///
  /// The gateway applies the rules to what the caller sent ([clientArgs], or
  /// [args] when that is not given) and refuses a call that misses a required
  /// argument; [context] is worked out there too. Only a call from the Tools
  /// page that gives no [clientArgs] skips the rules, and goes as written.
  Future<McpToolResult> callTool({
    required String serverId,
    required String toolName,
    required Json args,
    required AuditSource source,
    required String actor,
    String? approval,
    Json? clientArgs,
    Json? context,
    String? conversationId,
  }) async {
    final client = _client;
    if (client == null) return McpToolResult.error('Not signed in.');
    try {
      final r = await client.postMap('/api/servers/$serverId/call', {
        'tool': toolName,
        'arguments': clientArgs ?? args,
        'source': source == AuditSource.operator ? 'chat' : 'dashboard',
        'actor': actor,
        'approval': ?approval,
        'conversationId': ?conversationId,
        // Only a test run on the Tools page may skip the rules.
        if (clientArgs == null && source != AuditSource.operator)
          'applyRules': false,
      });
      final event = r['event'];
      if (event is Map) {
        ref
            .read(auditLogProvider.notifier)
            .add(AuditEvent.fromServer(event.cast<String, dynamic>()));
      }
      return McpToolResult(
        text: r['text'] as String? ?? '',
        isError: r['isError'] == true,
        structured: r['structured'],
        raw: (r['raw'] as Map?)?.cast<String, dynamic>(),
      );
    } on ServerException catch (e) {
      return McpToolResult.error(e.message);
    }
  }

  /// Records a call the human refused, so the audit trail shows the attempt.
  Future<void> recordDenied({
    required String serverId,
    required String toolName,
    required Json args,
    required String actor,
    String? conversationId,
  }) async {
    final client = _client;
    if (client == null) return;
    try {
      final stored = await client.postMap('/api/audit/events', {
        'kind': 'toolCall',
        'status': 'denied',
        'source': 'chat',
        'serverId': serverId,
        'serverName': state.byId(serverId)?.config.name,
        'tool': toolName,
        'args': redactedArgs(args),
        'actor': actor,
        'approval': 'denied',
        'conversationId': ?conversationId,
      });
      if (stored.isNotEmpty && ref.mounted) {
        ref.read(auditLogProvider.notifier).add(AuditEvent.fromServer(stored));
      }
    } on ServerException {
      // The refusal still stands; only its record is missing.
    }
  }

  void _setRuntime(String id, ServerRuntime Function(ServerRuntime) update) {
    state = McpHubState([
      for (final s in state.servers) s.config.id == id ? update(s) : s,
    ]);
  }
}

/// Arguments as text for the audit log (the server masks secrets again).
String redactedArgs(Json args) => redactedPreview(args);
