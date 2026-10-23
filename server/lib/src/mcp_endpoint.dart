import 'dart:async';
import 'dart:convert';

import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'access.dart';
import 'audit.dart';
import 'catalog.dart';
import 'models.dart';
import 'state.dart';
import 'upstream.dart';

const gatewayVersion = '1.0.0';

/// Protocol versions the portals speak, newest first.
const supportedProtocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

const _maxBodyBytes = 4 * 1024 * 1024;

/// The MCP side of a portal: Streamable HTTP, answering with plain JSON.
///
/// It keeps no session: every request carries its credential and stands on its
/// own, which is what lets a client use it behind any proxy or tunnel.
class McpEndpoint {
  McpEndpoint({
    required this.store,
    required this.pool,
    required this.auth,
    required this.audit,
    required this.baseUrl,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final StateStore store;
  final UpstreamPool pool;
  final PortalAuthenticator auth;
  final GatewayAuditLog audit;

  /// The public origin for this request, for the OAuth discovery pointer.
  final String Function(Request request) baseUrl;
  final DateTime Function() _now;

  Future<Response> handle(Request request, String slug) async {
    final portal = store.state.portalBySlug(slug);
    if (portal == null || !portal.enabled) {
      return _json(404, {'error': 'portal_not_found'});
    }

    final result = await auth.authenticate(
      request.headers['authorization'],
      portal,
    );
    final failure = result.failure;
    if (failure == AuthFailure.invalid) {
      return Response(
        401,
        body: jsonEncode({'error': 'invalid_token'}),
        headers: {
          'content-type': 'application/json',
          'www-authenticate':
              'Bearer resource_metadata="${baseUrl(request)}'
              '/.well-known/oauth-protected-resource/mcp/${portal.slug}"',
        },
      );
    }
    if (failure == AuthFailure.forbidden) {
      return _json(403, {'error': 'portal_access_denied'});
    }
    final principal = result.principal!;

    if (request.method != 'POST') {
      // No server-initiated stream and no session to end.
      return Response(405, headers: {'allow': 'POST'});
    }

    final Object? decoded;
    try {
      final body = await _readBody(request);
      decoded = jsonDecode(body);
    } on _TooLarge {
      return _json(413, _rpcError(null, -32600, 'Request is too large'));
    } on FormatException {
      return _json(400, _rpcError(null, -32700, 'Parse error'));
    }

    if (decoded is List) {
      if (decoded.isEmpty) {
        return _json(400, _rpcError(null, -32600, 'Empty batch'));
      }
      final replies = <Json>[];
      for (final item in decoded) {
        final reply = await _message(item, portal, principal);
        if (reply != null) replies.add(reply);
      }
      return replies.isEmpty ? Response(202) : _json(200, replies);
    }
    final reply = await _message(decoded, portal, principal);
    return reply == null ? Response(202) : _json(200, reply);
  }

  Future<String> _readBody(Request request) async {
    final length = request.contentLength;
    if (length != null && length > _maxBodyBytes) throw _TooLarge();
    final bytes = <int>[];
    await for (final chunk in request.read()) {
      bytes.addAll(chunk);
      if (bytes.length > _maxBodyBytes) throw _TooLarge();
    }
    return utf8.decode(bytes);
  }

  /// One JSON-RPC message; null for a notification (nothing to answer).
  Future<Json?> _message(Object? message, Portal portal, Principal who) async {
    if (message is! Map || message['jsonrpc'] != '2.0') {
      return _rpcError(null, -32600, 'Invalid request');
    }
    final id = message['id'];
    final method = message['method'];
    final params = ((message['params'] as Map?) ?? const {})
        .cast<String, dynamic>();
    if (method is! String) {
      // A response to something we never asked.
      return id == null ? null : _rpcError(id, -32600, 'Invalid request');
    }
    if (id == null) return null; // notifications/initialized and friends

    try {
      switch (method) {
        case 'initialize':
          return _rpcResult(id, _initialize(params, portal));
        case 'ping':
          return _rpcResult(id, <String, dynamic>{});
        case 'tools/list':
          return _rpcResult(id, await _listTools(portal));
        case 'tools/call':
          return await _callTool(id, params, portal, who);
        default:
          return _rpcError(id, -32601, 'Method not found: $method');
      }
    } catch (e) {
      return _rpcError(id, -32603, 'Internal error');
    }
  }

  Json _initialize(Json params, Portal portal) {
    final asked = params['protocolVersion'];
    final version = supportedProtocolVersions.contains(asked)
        ? asked as String
        : supportedProtocolVersions.first;
    return {
      'protocolVersion': version,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': portal.name, 'version': gatewayVersion},
      if (portal.description.isNotEmpty) 'instructions': portal.description,
    };
  }

  Future<Json> _listTools(Portal portal) async {
    final catalog = await buildCatalog(portal, store.state, pool);
    return {
      'tools': [for (final t in catalog.tools) t.toMcpJson()],
    };
  }

  Future<Json> _callTool(
    Object id,
    Json params,
    Portal portal,
    Principal who,
  ) async {
    final name = params['name'];
    if (name is! String) {
      return _rpcError(id, -32602, 'A tool name is required');
    }
    final args = ((params['arguments'] as Map?) ?? const {})
        .cast<String, dynamic>();

    final catalog = await buildCatalog(portal, store.state, pool);
    final exposed = catalog.find(name);
    if (exposed == null) {
      await _record(
        portal,
        who,
        'denied',
        tool: null,
        exposedName: name,
        args: args,
        error: 'Tool is not available in this portal',
      );
      return _rpcError(id, -32602, 'Unknown tool: $name');
    }

    final prepared = prepareCall(exposed.effective, args);
    if (prepared.error != null) {
      await _record(
        portal,
        who,
        'error',
        exposed: exposed,
        args: args,
        error: 'Rejected before forwarding: ${prepared.error}',
      );
      return _rpcResult(id, _errorResult(prepared.error!));
    }

    final watch = Stopwatch()..start();
    try {
      final result = await pool.call(
        exposed.server,
        exposed.tool.name,
        prepared.forwarded,
      );
      watch.stop();
      await _record(
        portal,
        who,
        result.isError ? 'error' : 'success',
        exposed: exposed,
        args: args,
        forwarded: prepared.forwarded,
        context: prepared.context,
        result: result.text,
        error: result.isError ? result.text : null,
        durationMs: watch.elapsedMilliseconds,
      );
      return _rpcResult(
        id,
        result.raw ??
            {
              'content': [
                {'type': 'text', 'text': result.text},
              ],
              if (result.isError) 'isError': true,
            },
      );
    } catch (e) {
      watch.stop();
      final message = e is McpException ? e.message : '$e';
      await _record(
        portal,
        who,
        'error',
        exposed: exposed,
        args: args,
        forwarded: prepared.forwarded,
        context: prepared.context,
        error: message,
        durationMs: watch.elapsedMilliseconds,
      );
      return _rpcResult(id, _errorResult('Upstream error: $message'));
    }
  }

  Future<void> _record(
    Portal portal,
    Principal who,
    String status, {
    ExposedTool? exposed,
    String? tool,
    String? exposedName,
    required Json args,
    Json? forwarded,
    Json? context,
    String? result,
    String? error,
    int? durationMs,
  }) {
    final argsPreview = redactedPreview(args);
    final forwardedPreview =
        forwarded != null && jsonEncode(forwarded) != jsonEncode(args)
        ? redactedPreview(forwarded)
        : null;
    return audit.record(
      GatewayAuditEvent(
        id: newId('evt'),
        timestamp: _now(),
        portalId: portal.id,
        portalSlug: portal.slug,
        principal: who.toJson(),
        status: status,
        serverId: exposed?.server.id,
        serverName: exposed?.server.name,
        tool: exposed?.tool.name ?? tool,
        exposedName: exposed?.exposedName ?? exposedName,
        durationMs: durationMs,
        args: argsPreview,
        forwarded: forwardedPreview,
        context: context == null || context.isEmpty
            ? null
            : redactedPreview(context),
        result: result == null ? null : redactedPreview(result),
        error: error == null ? null : redactText(error),
        rules: exposed?.effective.rules ?? const [],
      ),
    );
  }
}

class _TooLarge implements Exception {}

Json _errorResult(String message) => {
  'content': [
    {'type': 'text', 'text': message},
  ],
  'isError': true,
};

Json _rpcResult(Object id, Object result) => {
  'jsonrpc': '2.0',
  'id': id,
  'result': result,
};

Json _rpcError(Object? id, int code, String message) => {
  'jsonrpc': '2.0',
  'id': id,
  'error': {'code': code, 'message': message},
};

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: {'content-type': 'application/json'},
);
