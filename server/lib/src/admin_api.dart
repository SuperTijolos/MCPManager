import 'dart:async';
import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'api_error.dart';
import 'audit.dart';
import 'catalog.dart';
import 'chats.dart';
import 'events.dart';
import 'health.dart';
import 'llm_api.dart';
import 'login.dart';
import 'mcp_endpoint.dart' show gatewayVersion;
import 'models.dart';
import 'security.dart';
import 'state.dart';
import 'tool_caller.dart';
import 'upstream_oauth.dart';
import 'upstream.dart';

final _slugPattern = RegExp(r'^[a-z0-9][a-z0-9-]{0,62}$');

String slugify(String text) {
  final slug = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.isEmpty
      ? 'server'
      : (slug.length > 63 ? slug.substring(0, 63) : slug);
}

/// The REST API the app (or any script) uses to manage the gateway.
/// Every route needs the admin token.
class AdminApi {
  AdminApi({
    required this.store,
    required this.pool,
    required this.audit,
    required this.auth,
    required this.adminEnvToken,
    required this.baseUrl,
    required this.login,
    required this.bus,
    required this.caller,
    required this.health,
    required this.upstreamOAuth,
    required this.chats,
    required this.llm,
    this.maxChatsPerOwner = 200,
    this.heartbeat = const Duration(seconds: 25),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final StateStore store;
  final UpstreamPool pool;
  final GatewayAuditLog audit;
  final PortalAuthenticator auth;
  final String? adminEnvToken;
  final String Function(Request request) baseUrl;
  final LoginService login;
  final EventBus bus;
  final ToolCaller caller;
  final HealthMonitor health;
  final UpstreamOAuth upstreamOAuth;
  final ChatRepository chats;
  final LlmApi llm;
  final int maxChatsPerOwner;
  final DateTime Function() _now;
  final Duration heartbeat;

  /// Null when [request] is not for this API.
  Future<Response?> handle(Request request) async {
    final path = request.url.path;
    if (!path.startsWith('api/') && path != 'api') return null;

    final header = request.headers['authorization'];
    final isAdmin = auth.isAdmin(header, envToken: adminEnvToken);
    final member = isAdmin ? null : login.memberForToken(bearerToken(header));
    if (!isAdmin && member == null) {
      return _json(401, {
        'error': 'unauthorized',
        'message': 'Sign in, or send the admin token.',
      });
    }
    try {
      final route = path.substring(3).replaceAll(RegExp(r'^/|/$'), '');
      if (route == 'me' && request.method == 'GET') {
        return _json(200, {
          'kind': isAdmin ? 'admin' : 'member',
          if (member != null) 'member': member.toJson(),
        });
      }
      if (route == 'logout' && request.method == 'POST') {
        final token = bearerToken(header);
        if (member != null && token != null) await login.signOut(token);
        return Response(204);
      }
      final who = member != null
          ? Principal(kind: 'member', id: member.id, name: member.login)
          : const Principal(kind: 'admin', id: 'admin', name: 'Admin token');
      return await _route(request.change(context: {'who': who}), route);
    } on ApiError catch (e) {
      return _json(e.status, {'error': e.code, 'message': ?e.message});
    } on FormatException catch (e) {
      return _json(400, {'error': 'invalid_json', 'message': e.message});
    }
  }

  Future<Response> _route(Request request, String path) async {
    final parts = path.isEmpty ? <String>[] : path.split('/');
    final method = request.method;
    final first = parts.isEmpty ? '' : parts.first;

    switch (first) {
      case 'status' when method == 'GET' && parts.length == 1:
        return _json(200, _status(request));
      case 'servers':
        return _servers(request, method, parts);
      case 'portals':
        return _portals(request, method, parts);
      case 'tokens':
        return _tokens(request, method, parts);
      case 'llm':
        return llm.handle(request, method, parts);
      case 'chats':
        return _chats(request, method, parts);
      case 'tools' when method == 'GET' && parts.length == 1:
        return _allTools(request);
      case 'health' when parts.length <= 2:
        return _health(request, method, parts);
      case 'events' when method == 'GET' && parts.length == 1:
        return _events();
      case 'members':
        return _members(request, method, parts);
      case 'rules' when parts.length == 1:
        return _rules(request, method);
      case 'audit' when method == 'POST' && parts.length == 2:
        return parts[1] == 'events'
            ? _auditEvent(request)
            : parts[1] == 'delete'
            ? _auditDelete(request)
            : throw ApiError(404, 'not_found');
      case 'audit' when method == 'GET' && parts.length == 1:
        final q = request.url.queryParameters;
        final events = await audit.recent(
          limit: (int.tryParse(q['limit'] ?? '') ?? 100).clamp(1, 1000),
          portalId: q['portal'],
          status: q['status'],
          query: q['q'],
          source: q['source'],
          conversationId: q['conversation'],
        );
        return _json(200, {
          'events': [for (final e in events) e.toJson()],
        });
    }
    throw ApiError(404, 'not_found');
  }

  /// A Server-Sent Events stream of what happens on the gateway. Nothing is
  /// replayed: a client that reconnects reloads what it shows.
  Response _events() {
    late StreamController<List<int>> out;
    StreamSubscription<GatewayEvent>? subscription;
    Timer? timer;
    var counter = 0;
    out = StreamController<List<int>>(
      onListen: () {
        out.add(utf8.encode('retry: 3000\nevent: ready\ndata: {}\n\n'));
        subscription = bus.stream.listen(
          (e) => out.add(utf8.encode(e.encode(++counter))),
        );
        timer = Timer.periodic(
          heartbeat,
          (_) => out.add(utf8.encode(': keep-alive\n\n')),
        );
      },
      onCancel: () {
        subscription?.cancel();
        timer?.cancel();
      },
    );
    return Response.ok(
      out.stream,
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-transform',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  Future<Response> _members(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1 && method == 'GET') {
      return _json(200, [for (final m in state.members) m.toJson()]);
    }
    if (parts.length == 2 && method == 'DELETE') {
      final id = Uri.decodeComponent(parts[1]);
      if (state.members.every((m) => m.id != id)) {
        throw ApiError(404, 'not_found');
      }
      // Their sessions go with them (the table cascades, the memory does not).
      await store.update((s) {
        s.sessions.removeWhere((x) => x.memberId == id);
        s.members.removeWhere((m) => m.id == id);
      });
      return Response(204);
    }
    throw ApiError(404, 'not_found');
  }

  Json _status(Request request) {
    final s = store.state;
    return {
      'version': gatewayVersion,
      'baseUrl': baseUrl(request),
      'servers': s.servers.length,
      'portals': s.portals.length,
      'tokens': s.tokens.where((t) => !t.revoked).length,
      'rules': s.rules.length,
    };
  }

  // ----------------------------------------------------------------- servers

  Future<Response> _servers(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 2 && parts[1] == 'probe' && method == 'POST') {
      return _probe(request);
    }
    if (parts.length == 1) {
      if (method == 'GET') {
        return _json(200, [for (final s in state.servers) s.toPublicJson()]);
      }
      if (method == 'POST') {
        final body = await _body(request);
        return _json(
          201,
          await _saveServer(newId('srv'), body, creating: true),
        );
      }
    } else if (parts.length == 2) {
      final id = parts[1];
      if (method == 'GET') {
        final server =
            state.server(id) ?? (throw ApiError(404, 'server_not_found'));
        return _json(200, server.toPublicJson());
      }
      if (method == 'PUT') {
        final body = await _body(request);
        return _json(
          200,
          await _saveServer(id, body, creating: state.server(id) == null),
        );
      }
      if (method == 'DELETE') {
        if (state.server(id) == null) throw ApiError(404, 'server_not_found');
        await store.update((s) {
          s.servers.removeWhere((x) => x.id == id);
          s.upstreamOAuth.remove(id);
          for (var i = 0; i < s.portals.length; i++) {
            final p = s.portals[i];
            s.portals[i] = p.copyWith(
              servers: [
                for (final r in p.servers)
                  if (r.serverId != id) r,
              ],
            );
          }
        });
        await pool.invalidate(id);
        return _json(200, {'ok': true});
      }
    } else if (parts.length == 3 && method == 'POST' && parts[2] == 'test') {
      final server =
          state.server(parts[1]) ?? (throw ApiError(404, 'server_not_found'));
      final catalog = await pool.catalog(server, refresh: true);
      health.note(server, catalog);
      return _json(200, {
        'ok': catalog.ok,
        'error': catalog.error,
        'server': catalog.info == null
            ? null
            : {'name': catalog.info!.name, 'version': catalog.info!.version},
        'transport': catalog.transport?.wire,
        'toolCount': catalog.tools.length,
        'tools': [for (final t in catalog.tools) t.name],
      });
    } else if (parts.length == 3 && method == 'GET' && parts[2] == 'tools') {
      final server =
          state.server(parts[1]) ?? (throw ApiError(404, 'server_not_found'));
      final refresh = request.url.queryParameters['refresh'] == '1';
      final catalog = await pool.catalog(server, refresh: refresh);
      // An explicit re-check is a connection attempt: the health record (and
      // the audit log, when the server went up or down) follows it.
      if (refresh) await health.recorded(server, catalog);
      return _json(200, _catalogJson(server, catalog));
    } else if (parts.length == 3 && method == 'POST' && parts[2] == 'call') {
      return _call(request, parts[1]);
    } else if (parts.length >= 3 && parts[2] == 'oauth') {
      return _upstreamOAuth(request, method, parts);
    }
    throw ApiError(405, 'method_not_allowed');
  }

  // ------------------------------------------------------------------ chats

  static final _chatId = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
  static const _maxChatBytes = 16 * 1024 * 1024;

  /// The signed-in member's conversations. Someone else's are invisible.
  Future<Response> _chats(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final owner = (request.context['who'] as Principal).id;

    if (parts.length == 1 && method == 'GET') {
      final list = await chats.list(owner);
      return _json(200, [for (final m in list) m.toJson()]);
    }
    if (parts.length != 2) throw ApiError(405, 'method_not_allowed');
    final id = parts[1];
    if (!_chatId.hasMatch(id)) {
      throw ApiError(400, 'invalid_id', 'Use letters, numbers, - and _.');
    }

    if (method == 'GET') {
      final doc = await chats.get(id);
      if (doc == null || doc.meta.ownerId != owner) {
        throw ApiError(404, 'chat_not_found');
      }
      return _json(200, {
        ...doc.meta.toJson(),
        'items': doc.content.items,
        'history': doc.content.history,
      });
    }
    if (method == 'DELETE') {
      if (!await chats.delete(id, owner)) throw ApiError(404, 'chat_not_found');
      bus.emit('chat', {'id': id});
      return Response(204);
    }
    if (method == 'PUT') {
      final body = await _body(request, maxBytes: _maxChatBytes);
      String? title;
      if (body.containsKey('title')) {
        final t = body['title'];
        if (t is! String || t.trim().isEmpty || t.trim().length > 200) {
          throw ApiError(
            400,
            'invalid_title',
            'The title is 1-200 characters.',
          );
        }
        title = t.trim();
      }
      final auto = body['autoApprove'];
      if (auto != null && auto is! bool) {
        throw ApiError(400, 'invalid_auto_approve');
      }
      List<Json>? objects(String key) {
        if (!body.containsKey(key)) return null;
        final v = body[key];
        if (v is! List || v.any((e) => e is! Map)) {
          throw ApiError(400, 'invalid_$key', '$key must be a list of objects');
        }
        return [for (final e in v) (e as Map).cast<String, dynamic>()];
      }

      final items = objects('items');
      final history = objects('history');
      if ((items == null) != (history == null)) {
        throw ApiError(
          400,
          'invalid_content',
          'Send items and history together.',
        );
      }
      try {
        final meta = await chats.save(
          id,
          owner,
          _now(),
          title: title,
          autoApprove: auto as bool?,
          content: items == null
              ? null
              : ChatContent(items: items, history: history!),
        );
        final dropped = await chats.prune(owner, maxChatsPerOwner);
        for (final d in dropped) {
          bus.emit('chat', {'id': d});
        }
        bus.emit('chat', {'id': id});
        return _json(200, meta.toJson());
      } on ChatOwnerMismatch {
        // Same answer as for an id that does not exist: do not confirm it.
        throw ApiError(404, 'chat_not_found');
      }
    }
    throw ApiError(405, 'method_not_allowed');
  }

  /// Tries a server's settings without saving anything: "Test connection".
  /// With a `serverId` it starts from that server's saved settings (so header
  /// values it already holds, and its sign-in, are used).
  Future<Response> _probe(Request request) async {
    final body = await _body(request);
    final base = body['serverId'] is String
        ? store.state.server(body['serverId'] as String)
        : null;

    final rawUrl = body['url'] ?? base?.url;
    if (rawUrl is! String || rawUrl.trim().isEmpty) {
      throw ApiError(400, 'invalid_url', 'url is required');
    }
    final url = normalizeBaseUrl(rawUrl.trim());
    if (!isValidHttpUrl(url)) {
      throw ApiError(
        400,
        'invalid_url',
        'The URL must be a valid http(s) address',
      );
    }
    var headers = base?.headers ?? const <String, String>{};
    if (body.containsKey('headers')) {
      final raw = body['headers'];
      if (raw is! Map) throw ApiError(400, 'invalid_headers');
      headers = {
        for (final e in raw.entries)
          if (e.value != null)
            '${e.key}': '${e.value}'
          else if (base?.headers['${e.key}'] != null)
            '${e.key}': base!.headers['${e.key}']!,
      };
    }
    final server = UpstreamServer(
      id: base?.id ?? 'probe',
      name: base?.name ?? 'probe',
      slug: 'probe',
      url: url,
      headers: headers,
      transport: body.containsKey('transport')
          ? McpTransport.parse(body['transport'])
          : (base?.transport ?? McpTransport.auto),
      oauth: body['oauth'] as bool? ?? base?.oauth ?? false,
      oauthClientId: body.containsKey('oauthClientId')
          ? _optionalText(body['oauthClientId'])
          : base?.oauthClientId,
      oauthScope: body.containsKey('oauthScope')
          ? _optionalText(body['oauthScope'])
          : base?.oauthScope,
    );
    final r = await pool.probe(server, signedInAs: base?.id);
    return _json(200, {
      'connected': r.connected,
      'needsAuth': r.needsAuth,
      'error': r.error,
      'server': r.info == null
          ? null
          : {'name': r.info!.name, 'version': r.info!.version},
      'toolCount': r.toolCount,
      'transport': r.transport?.wire,
      'endpoint': r.endpoint,
      'latencyMs': r.latencyMs,
      'trace': r.trace,
    });
  }

  /// Signing the gateway in to an upstream server that uses OAuth.
  Future<Response> _upstreamOAuth(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final server =
        store.state.server(parts[1]) ??
        (throw ApiError(404, 'server_not_found'));
    if (parts.length == 3 && method == 'GET') {
      return _json(200, upstreamOAuth.status(server.id));
    }
    if (parts.length == 3 && method == 'DELETE') {
      await upstreamOAuth.signOut(
        server.id,
        forget: request.url.queryParameters['forget'] == '1',
      );
      return _json(200, upstreamOAuth.status(server.id));
    }
    if (parts.length == 4 && parts[3] == 'start' && method == 'POST') {
      final body = await _body(request);
      String? returnTo;
      if (body['returnTo'] != null) {
        returnTo = login.safeReturn('${body['returnTo']}');
        if (returnTo == null) {
          throw ApiError(
            400,
            'invalid_return_to',
            'That return address is not one this server knows.',
          );
        }
      }
      try {
        final url = await upstreamOAuth.begin(
          server,
          redirectUri: '${baseUrl(request)}/oauth/upstream/callback',
          returnTo: returnTo,
        );
        return _json(200, {'authorizeUrl': url.toString()});
      } on OAuthException catch (e) {
        throw ApiError(502, 'oauth_failed', e.message);
      }
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Json _catalogJson(UpstreamServer server, UpstreamCatalog catalog) => {
    'id': server.id,
    'name': server.name,
    'error': catalog.error,
    'fetchedAt': catalog.fetchedAt.toUtc().toIso8601String(),
    'server': catalog.info == null
        ? null
        : {'name': catalog.info!.name, 'version': catalog.info!.version},
    'transport': catalog.transport?.wire,
    'endpoint': catalog.endpoint,
    'trace': catalog.trace,
    'tools': [
      for (final t in catalog.tools)
        {
          'name': t.name,
          'title': t.title,
          'description': t.description,
          'annotations': t.annotations,
          'inputSchema': t.inputSchema,
        },
    ],
  };

  /// The tools of every enabled server, so the dashboard loads them in one go.
  Future<Response> _allTools(Request request) async {
    final refresh = request.url.queryParameters['refresh'] == '1';
    final servers = [
      for (final s in store.state.servers)
        if (s.enabled) s,
    ];
    final catalogs = await Future.wait([
      for (final s in servers) pool.catalog(s, refresh: refresh),
    ]);
    return _json(200, {
      'servers': [
        for (var i = 0; i < servers.length; i++)
          _catalogJson(servers[i], catalogs[i]),
      ],
    });
  }

  Future<Response> _health(
    Request request,
    String method,
    List<String> parts,
  ) async {
    if (parts.length == 1 && method == 'GET') {
      return _json(200, {
        'servers': {
          for (final e in health.snapshot.entries) e.key: e.value.toJson(),
        },
      });
    }
    if (parts.length == 2 && parts[1] == 'check' && method == 'POST') {
      await health.checkAll();
      return _json(200, {
        'servers': {
          for (final e in health.snapshot.entries) e.key: e.value.toJson(),
        },
      });
    }
    throw ApiError(405, 'method_not_allowed');
  }

  /// Calls a tool for the dashboard (its test bench or its chat). Rules apply
  /// and the call is recorded, exactly as for a portal client.
  /// An event the dashboard itself observed: a management action by the
  /// Operator, or a call a person refused. The server stamps the time and
  /// the caller; text is masked and shortened.
  Future<Response> _auditEvent(Request request) async {
    final body = await _body(request);
    final who = request.context['who'] as Principal;
    String? text(String key, {int max = 4000}) {
      final v = body[key];
      if (v == null) return null;
      if (v is! String) throw ApiError(400, 'invalid_$key');
      return v.length > max ? v.substring(0, max) : v;
    }

    final kind = body['kind'] ?? 'manage';
    if (kind != 'manage' && kind != 'toolCall') {
      throw ApiError(400, 'invalid_kind', 'kind is manage or toolCall');
    }
    final source = body['source'] ?? 'chat';
    if (source != 'dashboard' && source != 'chat') {
      throw ApiError(400, 'invalid_source', 'source is dashboard or chat');
    }
    final status = body['status'];
    if (status != 'success' && status != 'error' && status != 'denied') {
      throw ApiError(400, 'invalid_status');
    }
    final duration = body['durationMs'];
    if (duration != null && (duration is! int || duration < 0)) {
      throw ApiError(400, 'invalid_duration');
    }
    final args = text('args');
    final result = text('result');
    final error = text('error', max: 1000);
    final event = GatewayAuditEvent(
      id: newId('evt'),
      timestamp: _now(),
      source: '$source',
      kind: '$kind',
      principal: who.toJson(),
      status: status as String,
      serverId: text('serverId', max: 200),
      serverName: text('serverName', max: 200),
      tool: text('tool', max: 200),
      durationMs: duration as int?,
      args: args == null ? null : redactText(args),
      result: result == null ? null : redactText(result),
      error: error == null ? null : redactText(error),
      actor: _shortText(body['actor']),
      approval: _shortText(body['approval']),
      conversationId: _shortText(body['conversationId']),
    );
    await audit.record(event);
    return _json(201, event.toJson());
  }

  /// Removes recorded events: by id, by age, or all of them.
  Future<Response> _auditDelete(Request request) async {
    final body = await _body(request);
    final ids = body['ids'];
    final before = body['before'];
    final all = body['all'] == true;
    if (ids != null &&
        (ids is! List || ids.length > 5000 || ids.any((e) => e is! String))) {
      throw ApiError(400, 'invalid_ids', 'ids is a list of up to 5000 ids.');
    }
    DateTime? cutoff;
    if (before != null) {
      cutoff = before is String ? DateTime.tryParse(before) : null;
      if (cutoff == null) throw ApiError(400, 'invalid_before');
    }
    if (ids == null && cutoff == null && !all) {
      throw ApiError(400, 'nothing_to_delete', 'Give ids, before, or all.');
    }
    final removed = await audit.delete(
      ids: ids == null ? null : [for (final e in ids as List) '$e'],
      before: cutoff,
      all: all,
    );
    return _json(200, {'removed': removed});
  }

  String? _shortText(Object? v, {int max = 200}) {
    if (v is! String) return null;
    final t = v.trim();
    if (t.isEmpty) return null;
    return t.length > max ? t.substring(0, max) : t;
  }

  Future<Response> _call(Request request, String serverId) async {
    final server =
        store.state.server(serverId) ??
        (throw ApiError(404, 'server_not_found'));
    final body = await _body(request);
    final who = request.context['who'] as Principal;

    final toolName = body['tool'];
    if (toolName is! String || toolName.isEmpty) {
      throw ApiError(400, 'invalid_tool', 'tool is required');
    }
    final source = body['source'] ?? 'dashboard';
    if (source != 'dashboard' && source != 'chat') {
      throw ApiError(400, 'invalid_source', 'source is dashboard or chat');
    }
    final rawArgs = body['arguments'] ?? const {};
    if (rawArgs is! Map) {
      throw ApiError(400, 'invalid_arguments', 'arguments must be an object');
    }
    final args = rawArgs.cast<String, dynamic>();
    final conversationId = body['conversationId'] is String
        ? body['conversationId'] as String
        : null;
    final actor = _shortText(body['actor']);
    final approval = _shortText(body['approval']);
    final applyRules = body['applyRules'] != false;
    if (!applyRules && source != 'dashboard') {
      throw ApiError(
        400,
        'invalid_apply_rules',
        'Only the dashboard may call without the rules.',
      );
    }
    if (!server.enabled) throw ApiError(409, 'server_disabled');

    final catalog = await pool.catalog(server);
    final tool = catalog.tools.where((t) => t.name == toolName).firstOrNull;
    if (tool == null && catalog.tools.isEmpty && catalog.error != null) {
      await caller.record(
        status: 'error',
        who: who,
        source: '$source',
        server: server,
        tool: toolName,
        args: args,
        error: catalog.error,
        conversationId: conversationId,
        actor: actor,
        approval: approval,
      );
      throw ApiError(502, 'server_unreachable', catalog.error);
    }
    if (tool == null) {
      await caller.record(
        status: 'denied',
        who: who,
        source: '$source',
        server: server,
        tool: toolName,
        args: args,
        error: catalog.error ?? 'The server has no such tool',
        conversationId: conversationId,
        actor: actor,
        approval: approval,
      );
      throw ApiError(
        404,
        'tool_not_found',
        catalog.error ?? 'The server has no such tool',
      );
    }
    final key = toolKey(server.id, tool.name);
    final effective = computeEffective(
      server.toConfig(),
      tool,
      store.state.rules,
      store.state.overrides[key],
    );
    // A test run without the rules sends the arguments exactly as typed.
    final callEffective = applyRules
        ? effective
        : computeEffective(server.toConfig(), tool, const [], null);
    // Tools hidden from the Operator stay out of the chat's reach, whatever
    // the dashboard asks for.
    if (source == 'chat' && !effective.visible) {
      await caller.record(
        status: 'denied',
        who: who,
        source: 'chat',
        server: server,
        tool: tool.name,
        args: args,
        rules: effective.rules,
        error: 'This tool is hidden from the Operator',
        conversationId: conversationId,
        actor: actor,
        approval: approval,
      );
      throw ApiError(
        403,
        'tool_hidden',
        'This tool is hidden from the Operator',
      );
    }

    final outcome = await caller.run(
      server: server,
      toolName: tool.name,
      effective: callEffective,
      args: args,
      who: who,
      source: '$source',
      conversationId: conversationId,
      actor: actor,
      approval: approval,
    );
    final result = outcome.result;
    return _json(200, {
      'status': outcome.status,
      'isError': result?.isError ?? true,
      'text': result?.text ?? outcome.rejected ?? outcome.upstreamError ?? '',
      'structured': result?.structured,
      'raw': result?.raw,
      'rejected': outcome.rejected,
      'error': outcome.upstreamError,
      'durationMs': outcome.durationMs,
      'event': outcome.event?.toJson(),
    });
  }

  Future<Json> _saveServer(
    String id,
    Json body, {
    required bool creating,
  }) async {
    final existing = store.state.server(id);

    String text(String key, {String? fallback}) {
      final v = body[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      if (fallback != null) return fallback;
      throw ApiError(400, 'invalid_$key', '$key is required');
    }

    final name = text('name', fallback: existing?.name);
    final url = normalizeBaseUrl(text('url', fallback: existing?.url));
    if (!isValidHttpUrl(url)) {
      throw ApiError(
        400,
        'invalid_url',
        'The URL must be a valid http(s) address',
      );
    }
    final slug = body.containsKey('slug')
        ? text('slug')
        : (existing?.slug ?? _freeServerSlug(slugify(name), id));
    if (!_slugPattern.hasMatch(slug)) {
      throw ApiError(
        400,
        'invalid_slug',
        'Use lowercase letters, numbers and hyphens',
      );
    }
    if (store.state.servers.any((s) => s.id != id && s.slug == slug)) {
      throw ApiError(409, 'slug_in_use');
    }

    Map<String, String> headers = existing?.headers ?? const {};
    if (body.containsKey('headers')) {
      final raw = body['headers'];
      if (raw is! Map) throw ApiError(400, 'invalid_headers');
      // A header sent with a null value keeps the value stored under that name,
      // so the dashboard can edit one header without ever having seen the rest.
      headers = {
        for (final e in raw.entries)
          if (e.value != null)
            '${e.key}': '${e.value}'
          else if (existing?.headers['${e.key}'] != null)
            '${e.key}': existing!.headers['${e.key}']!,
      };
    }

    final server = UpstreamServer(
      id: id,
      name: name,
      slug: slug,
      url: url,
      headers: headers,
      transport: body.containsKey('transport')
          ? McpTransport.parse(body['transport'])
          : (existing?.transport ?? McpTransport.auto),
      enabled: body['enabled'] as bool? ?? existing?.enabled ?? true,
      oauth: body['oauth'] as bool? ?? existing?.oauth ?? false,
      oauthClientId: body.containsKey('oauthClientId')
          ? _optionalText(body['oauthClientId'])
          : existing?.oauthClientId,
      oauthScope: body.containsKey('oauthScope')
          ? _optionalText(body['oauthScope'])
          : existing?.oauthScope,
    );
    await store.update((s) {
      // Tokens belong to one address; a moved or non-OAuth server starts over.
      if (existing != null && (existing.url != url || !server.oauth)) {
        s.upstreamOAuth.remove(id);
      }
      final i = s.servers.indexWhere((x) => x.id == id);
      if (i >= 0) {
        s.servers[i] = server;
      } else {
        s.servers.add(server);
      }
    });
    await pool.invalidate(id);
    return server.toPublicJson();
  }

  String? _optionalText(Object? v) {
    if (v == null) return null;
    final t = '$v'.trim();
    return t.isEmpty ? null : t;
  }

  String _freeServerSlug(String base, String id) {
    var slug = base;
    var n = 2;
    while (store.state.servers.any((s) => s.id != id && s.slug == slug)) {
      slug = '$base-$n';
      n++;
    }
    return slug;
  }

  // ----------------------------------------------------------------- portals

  Json _portalJson(Portal p, Request request) => {
    ...p.toJson(),
    'endpoint': '${baseUrl(request)}/mcp/${p.slug}',
  };

  Future<Response> _portals(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1) {
      if (method == 'GET') {
        return _json(200, [
          for (final p in state.portals) _portalJson(p, request),
        ]);
      }
      if (method == 'POST') {
        final body = await _body(request);
        final saved = await _savePortal(newId('portal'), body, creating: true);
        return _json(201, _portalJson(saved, request));
      }
    } else if (parts.length == 2) {
      final id = parts[1];
      if (method == 'GET') {
        final portal =
            state.portal(id) ?? (throw ApiError(404, 'portal_not_found'));
        return _json(200, _portalJson(portal, request));
      }
      if (method == 'PUT') {
        final body = await _body(request);
        final saved = await _savePortal(
          id,
          body,
          creating: state.portal(id) == null,
        );
        return _json(200, _portalJson(saved, request));
      }
      if (method == 'DELETE') {
        if (state.portal(id) == null) throw ApiError(404, 'portal_not_found');
        await store.update((s) => s.portals.removeWhere((p) => p.id == id));
        return _json(200, {'ok': true});
      }
    } else if (parts.length == 3 && method == 'GET' && parts[2] == 'tools') {
      final portal =
          state.portal(parts[1]) ?? (throw ApiError(404, 'portal_not_found'));
      final q = request.url.queryParameters;
      final catalog = await buildCatalog(
        portal,
        state,
        pool,
        includeHidden: q['includeHidden'] == '1',
        refresh: q['refresh'] == '1',
      );
      return _json(200, {
        'problems': catalog.problems,
        'tools': [
          for (final t in catalog.tools)
            {
              'name': t.exposedName,
              'serverId': t.server.id,
              'serverName': t.server.name,
              'tool': t.tool.name,
              'title': t.tool.title,
              'description': t.effective.description,
              'visible': t.effective.visible,
              'excluded': t.excluded,
              'rules': t.effective.rules,
              'readOnly': t.effective.readOnly,
              'inputSchema': t.effective.inputSchema,
            },
        ],
      });
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Future<Portal> _savePortal(
    String id,
    Json body, {
    required bool creating,
  }) async {
    final existing = store.state.portal(id);
    final name =
        (body['name'] is String && (body['name'] as String).trim().isNotEmpty)
        ? (body['name'] as String).trim()
        : (existing?.name ??
              (throw ApiError(400, 'invalid_name', 'name is required')));
    final slug = body.containsKey('slug')
        ? '${body['slug']}'.trim().toLowerCase()
        : (existing?.slug ?? slugify(name));
    if (!_slugPattern.hasMatch(slug)) {
      throw ApiError(
        400,
        'invalid_slug',
        'Use lowercase letters, numbers and hyphens',
      );
    }
    if (store.state.portals.any((p) => p.id != id && p.slug == slug)) {
      throw ApiError(409, 'portal_slug_in_use');
    }

    List<PortalServerRef> refs = existing?.servers ?? const [];
    if (body.containsKey('servers')) {
      final raw = body['servers'];
      if (raw is! List) throw ApiError(400, 'invalid_servers');
      final seen = <String>{};
      refs = [
        for (final item in raw)
          if (item is String
              ? seen.add(item)
              : item is Map && seen.add('${item['serverId']}'))
            item is String
                ? PortalServerRef(item)
                : PortalServerRef.fromJson(
                    (item as Map).cast<String, dynamic>(),
                  ),
      ];
      for (final r in refs) {
        if (store.state.server(r.serverId) == null) {
          throw ApiError(400, 'unknown_server', 'No server "${r.serverId}"');
        }
      }
    }

    final portal = Portal(
      id: id,
      slug: slug,
      name: name,
      description: body['description'] is String
          ? (body['description'] as String).trim()
          : (existing?.description ?? ''),
      enabled: body['enabled'] as bool? ?? existing?.enabled ?? true,
      servers: refs,
      excludedTools: body.containsKey('excludedTools')
          ? [for (final t in (body['excludedTools'] as List? ?? const [])) '$t']
          : (existing?.excludedTools ?? const []),
    );
    await store.update((s) {
      final i = s.portals.indexWhere((p) => p.id == id);
      if (i >= 0) {
        s.portals[i] = portal;
      } else {
        s.portals.add(portal);
      }
    });
    return portal;
  }

  // ------------------------------------------------------------------ tokens

  Future<Response> _tokens(
    Request request,
    String method,
    List<String> parts,
  ) async {
    final state = store.state;
    if (parts.length == 1 && method == 'GET') {
      return _json(200, [for (final t in state.tokens) t.toPublicJson()]);
    }
    if (parts.length == 1 && method == 'POST') {
      final body = await _body(request);
      final name = '${body['name'] ?? ''}'.trim();
      if (name.isEmpty) throw ApiError(400, 'invalid_name', 'name is required');
      final portalIds = [
        for (final p in (body['portalIds'] as List? ?? const [])) '$p',
      ];
      for (final p in portalIds) {
        if (state.portal(p) == null) {
          throw ApiError(400, 'unknown_portal', 'No portal "$p"');
        }
      }
      final days = body['expiresInDays'];
      final secret = randomSecret(prefix: 'mcp_');
      final token = AccessToken(
        id: newId('tok'),
        name: name,
        hash: hashSecret(secret),
        prefix: secret.substring(0, 8),
        portalIds: portalIds,
        createdAt: DateTime.now(),
        expiresAt: days is int && days > 0
            ? DateTime.now().add(Duration(days: days))
            : null,
      );
      await store.update((s) => s.tokens.add(token));
      // The only time the secret is shown.
      return _json(201, {'token': token.toPublicJson(), 'secret': secret});
    }
    if (parts.length == 2 && method == 'DELETE') {
      final id = parts[1];
      final i = state.tokens.indexWhere((t) => t.id == id);
      if (i < 0) throw ApiError(404, 'token_not_found');
      await store.update((s) {
        s.tokens[i] = s.tokens[i].copyWith(revokedAt: DateTime.now());
      });
      return _json(200, {'ok': true});
    }
    throw ApiError(405, 'method_not_allowed');
  }

  // ------------------------------------------------------------------- rules

  Future<Response> _rules(Request request, String method) async {
    final state = store.state;
    if (method == 'GET') {
      return _json(200, {
        'rules': [for (final r in state.rules) r.toJson()],
        'overrides': {
          for (final e in state.overrides.entries) e.key: e.value.toJson(),
        },
      });
    }
    if (method == 'PUT') {
      final body = await _body(request);
      final List<ToolRule> rules;
      final Map<String, ToolOverride> overrides;
      try {
        rules = [
          for (final r in (body['rules'] as List? ?? const []))
            ToolRule.fromJson((r as Map).cast<String, dynamic>()),
        ];
        overrides = {
          for (final e in ((body['overrides'] as Map?) ?? const {}).entries)
            '${e.key}': ToolOverride.fromJson(
              (e.value as Map).cast<String, dynamic>(),
            ),
        };
      } catch (_) {
        throw ApiError(
          400,
          'invalid_rules',
          'The rules or overrides could not be read',
        );
      }
      await store.update((s) {
        s.rules = rules;
        s.overrides = overrides;
      });
      return _json(200, {'rules': rules.length, 'overrides': overrides.length});
    }
    throw ApiError(405, 'method_not_allowed');
  }

  Future<Json> _body(Request request, {int maxBytes = 1024 * 1024}) async {
    final declared = request.contentLength;
    if (declared != null && declared > maxBytes) {
      throw ApiError(413, 'too_large', 'The request is too large.');
    }
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw ApiError(413, 'too_large', 'The request is too large.');
      }
    }
    final text = utf8.decode(bytes);
    if (text.trim().isEmpty) return {};
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw ApiError(400, 'invalid_body', 'Send a JSON object');
    }
    return decoded.cast<String, dynamic>();
  }
}

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
