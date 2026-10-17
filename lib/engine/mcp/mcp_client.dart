import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'mcp_models.dart';

const mcpProtocolVersion = '2025-06-18';
const _clientName = 'mcp-manager';
const _clientVersion = '1.0.0';

/// Minimal MCP client for the Streamable HTTP transport (JSON or SSE replies).
///
/// It deliberately avoids `dart:io` so it works in the browser. In a browser
/// the target server must send CORS headers that allow `Mcp-Session-Id`,
/// `MCP-Protocol-Version` and any auth header, and expose `Mcp-Session-Id`.
class McpClient {
  McpClient(this.config, {http.Client? httpClient, this.tokenProvider})
    : _http = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final McpServerConfig config;

  /// Supplies an OAuth access token; called with `forceRefresh: true` after a
  /// 401. Returning null means the user must sign in again.
  final Future<String?> Function({bool forceRefresh})? tokenProvider;
  final http.Client _http;
  final bool _ownsClient;

  String? _sessionId;
  String _protocolVersion = mcpProtocolVersion;
  bool _initialized = false;
  int _nextId = 1;

  bool get isConnected => _initialized;

  Future<McpServerInfo> connect() async {
    _sessionId = null;
    _initialized = false;
    final result = await _request('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': _clientName, 'version': _clientVersion},
    }, timeout: const Duration(seconds: 20));

    _protocolVersion =
        result['protocolVersion'] as String? ?? mcpProtocolVersion;
    _initialized = true;
    await _notify('notifications/initialized');

    final server = (result['serverInfo'] as Map?)?.cast<String, dynamic>();
    return McpServerInfo(
      name: server?['name'] as String? ?? config.name,
      version: server?['version'] as String? ?? '?',
      protocolVersion: _protocolVersion,
      instructions: result['instructions'] as String?,
    );
  }

  Future<List<McpTool>> listTools() async {
    final tools = <McpTool>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final result = await _request(
        'tools/list',
        cursor == null ? null : {'cursor': cursor},
      );
      for (final raw in (result['tools'] as List?) ?? const []) {
        tools.add(McpTool.fromJson((raw as Map).cast<String, dynamic>()));
      }
      cursor = result['nextCursor'] as String?;
      if (cursor == null) break;
    }
    return tools;
  }

  Future<McpToolResult> callTool(String name, Json arguments) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    }, timeout: const Duration(minutes: 2));
    return McpToolResult.fromJson(result);
  }

  Future<void> ping() => _request('ping', null);

  void close() {
    final headers = _sessionId == null ? null : _headers();
    _initialized = false;
    _sessionId = null;
    if (headers != null && !_ownsClient) {
      // Best effort: tell the server to drop the session.
      unawaited(
        _http
            .delete(Uri.parse(config.url), headers: headers)
            .then<void>((_) {}, onError: (_) {}),
      );
    }
    if (_ownsClient) _http.close();
  }

  Map<String, String> _headers({String? token}) => {
    'content-type': 'application/json',
    'accept': 'application/json, text/event-stream',
    'authorization': ?(token == null ? null : 'Bearer $token'),
    ...config.headers,
    'mcp-session-id': ?_sessionId,
    if (_initialized) 'mcp-protocol-version': _protocolVersion,
  };

  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    await _post(body, const Duration(seconds: 10));
  }

  Future<Json> _request(
    String method,
    Json? params, {
    Duration timeout = const Duration(seconds: 30),
    bool allowReconnect = true,
    bool allowReauth = true,
  }) async {
    final id = _nextId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': ?params,
    });
    final response = await _post(body, timeout);

    if (response.statusCode == 404 &&
        _sessionId != null &&
        method != 'initialize' &&
        allowReconnect) {
      // The server forgot our session; start a new one and retry once.
      await connect();
      return _request(method, params, timeout: timeout, allowReconnect: false);
    }
    if (response.statusCode == 401 && tokenProvider != null && allowReauth) {
      // The access token may have been revoked or expired early: refresh once.
      if (await tokenProvider!(forceRefresh: true) != null) {
        return _request(
          method,
          params,
          timeout: timeout,
          allowReconnect: allowReconnect,
          allowReauth: false,
        );
      }
    }
    if (response.statusCode == 401) {
      throw McpAuthRequired(
        'Unauthorized (HTTP 401). ${tokenProvider != null || !config.hasStaticAuthorization ? 'Sign-in is required.' : 'Check the server headers/token.'}',
        wwwAuthenticate: response.headers['www-authenticate'],
      );
    }
    if (response.statusCode == 403) {
      throw McpException(
        'Forbidden (HTTP 403). The credentials were accepted but lack access.',
        code: 403,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException(
        'HTTP ${response.statusCode}: ${truncate(response.body, 300)}',
        code: response.statusCode,
      );
    }

    if (method == 'initialize') {
      _sessionId = response.headers['mcp-session-id'] ?? _sessionId;
    }

    final message = parseRpcResponse(response, id);
    final error = message['error'];
    if (error is Map) {
      throw McpException(
        '${error['message'] ?? 'MCP error'}',
        code: error['code'] as int?,
      );
    }
    final result = message['result'];
    return result is Map ? result.cast<String, dynamic>() : <String, dynamic>{};
  }

  Future<http.Response> _post(String body, Duration timeout) async {
    try {
      final token = await tokenProvider?.call(forceRefresh: false);
      return await _http
          .post(
            Uri.parse(config.url),
            headers: _headers(token: token),
            body: body,
          )
          .timeout(timeout);
    } on TimeoutException {
      throw McpException('Timed out after ${timeout.inSeconds}s');
    } on http.ClientException catch (e) {
      throw McpException(
        'Could not reach ${config.url} (${e.message}). '
        'From a browser the server must also allow CORS for this origin.',
      );
    } on FormatException catch (e) {
      throw McpException('Invalid server URL: ${e.message}');
    }
  }
}

/// Extracts the JSON-RPC response for [id] from a JSON or SSE HTTP reply.
Json parseRpcResponse(http.Response response, int id) {
  final contentType = response.headers['content-type'] ?? '';
  final candidates = <Object?>[];

  if (contentType.contains('text/event-stream')) {
    for (final data in parseSseData(response.body)) {
      try {
        candidates.add(jsonDecode(data));
      } catch (_) {
        // Ignore non-JSON events (keep-alives, comments).
      }
    }
  } else {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is List) {
        candidates.addAll(decoded);
      } else {
        candidates.add(decoded);
      }
    } on FormatException {
      throw McpException(
        'Server did not return JSON (content-type: '
        '${contentType.isEmpty ? 'none' : contentType}).',
      );
    }
  }

  for (final c in candidates) {
    if (c is Map &&
        c['id'] == id &&
        (c.containsKey('result') || c.containsKey('error'))) {
      return c.cast<String, dynamic>();
    }
  }
  throw McpException('No response received for request $id.');
}

/// Joins the `data:` lines of every event in an SSE body.
List<String> parseSseData(String body) {
  final events = <String>[];
  final data = <String>[];
  for (final line in const LineSplitter().convert(body)) {
    if (line.isEmpty) {
      if (data.isNotEmpty) events.add(data.join('\n'));
      data.clear();
    } else if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      data.add(value);
    }
  }
  if (data.isNotEmpty) events.add(data.join('\n'));
  return events;
}
