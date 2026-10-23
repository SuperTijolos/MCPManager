import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'mcp_client.dart' show mcpProtocolVersion;
import 'mcp_connection.dart';
import 'mcp_models.dart';

const _clientName = 'mcp-manager';
const _clientVersion = '1.0.0';

/// Client for the legacy HTTP+SSE MCP transport (spec 2024-11-05), still used
/// by many servers and IDE bridges:
///
/// 1. `GET <url>` opens a long-lived `text/event-stream`.
/// 2. The first event, `endpoint`, names the URL to POST requests to.
/// 3. Requests are POSTed there (answered with `202 Accepted`); the JSON-RPC
///    responses arrive as `message` events on the stream.
///
/// `fetch` streaming is used instead of `EventSource` so that an
/// `Authorization` header can be sent from a browser.
class McpSseClient implements McpConnection {
  McpSseClient(
    this.config, {
    http.Client? httpClient,
    this.tokenProvider,
    this.endpointTimeout = const Duration(seconds: 15),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _url = Uri.parse(config.url);

  final McpServerConfig config;
  final TokenProvider? tokenProvider;
  final Duration endpointTimeout;

  final http.Client _http;
  final bool _ownsClient;
  final Uri _url;

  final List<String> _trace = [];

  @override
  List<String> get trace => List.unmodifiable(_trace);

  void _log(String line) {
    if (_trace.length < 60) _trace.add(line);
  }

  Uri? _postUrl;
  StreamSubscription<String>? _subscription;
  Completer<Uri>? _endpoint;
  final _pending = <int, Completer<Json>>{};
  final _data = <String>[];
  String? _event;
  bool _connected = false;
  int _nextId = 1;
  String _protocolVersion = mcpProtocolVersion;
  int _generation = 0;

  @override
  bool get isConnected => _connected;

  @override
  McpTransport get transport => McpTransport.sse;

  @override
  String get endpointUrl => _url.toString();

  @override
  Future<McpServerInfo> connect() async {
    _teardown('Reconnecting.');
    _trace.clear();
    await _openStream();
    final result = await _rpc('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, dynamic>{},
      'clientInfo': {'name': _clientName, 'version': _clientVersion},
    }, timeout: const Duration(seconds: 20));
    _protocolVersion =
        result['protocolVersion'] as String? ?? mcpProtocolVersion;
    _connected = true;
    await _post(
      jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
    );

    final server = (result['serverInfo'] as Map?)?.cast<String, dynamic>();
    return McpServerInfo(
      name: server?['name'] as String? ?? config.name,
      version: server?['version'] as String? ?? '?',
      protocolVersion: _protocolVersion,
      instructions: result['instructions'] as String?,
    );
  }

  @override
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

  @override
  Future<McpToolResult> callTool(String name, Json arguments) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': arguments,
    }, timeout: const Duration(minutes: 2));
    return McpToolResult.fromJson(result);
  }

  @override
  Future<void> ping() => _request('ping', null);

  @override
  void close() {
    _teardown('Closed.');
    if (_ownsClient) _http.close();
  }

  // ------------------------------------------------------------------ stream

  Map<String, String> _headers({String? token, bool json = false}) => {
    if (json) 'content-type': 'application/json',
    'accept': json
        ? 'application/json, text/event-stream'
        : 'text/event-stream',
    'authorization': ?(token == null ? null : 'Bearer $token'),
    ...config.headers,
  };

  Future<void> _openStream({bool allowReauth = true}) async {
    final generation = ++_generation;
    final token = await tokenProvider?.call(forceRefresh: false);
    final http.StreamedResponse response;
    try {
      // No query string: some servers match the path exactly.
      response = await _http
          .send(
            http.Request('GET', _url)..headers.addAll(_headers(token: token)),
          )
          .timeout(endpointTimeout);
    } on TimeoutException {
      throw McpException('Timed out opening the event stream at $_url.');
    } on http.ClientException catch (e) {
      throw _networkError(e);
    }

    _log('GET $_url → ${response.statusCode}');
    if (response.statusCode == 401) {
      final challenge = response.headers['www-authenticate'];
      await response.stream.drain<void>().catchError((_) {});
      if (tokenProvider != null &&
          allowReauth &&
          await tokenProvider!(forceRefresh: true) != null) {
        return _openStream(allowReauth: false);
      }
      throw McpAuthRequired(_unauthorizedMessage(), wwwAuthenticate: challenge);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString().catchError((_) => '');
      throw McpException(
        'HTTP ${response.statusCode} opening the event stream at $_url'
        '${body.isEmpty ? '' : ': ${truncate(body, 200)}'}',
        // A success that is not a stream means "this URL does not do SSE";
        // report it like any other wrong-transport answer.
        code: response.statusCode < 300 ? 406 : response.statusCode,
      );
    }
    final type = response.headers['content-type'] ?? '';
    if (!type.contains('text/event-stream')) {
      await response.stream.drain<void>().catchError((_) {});
      throw McpException(
        'Server did not open an event stream at $_url '
        '(content-type: ${type.isEmpty ? 'none' : type}).',
        code: 406,
      );
    }

    _endpoint = Completer<Uri>();
    _data.clear();
    _event = null;
    _subscription = response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _onLine,
          onError: (Object e, StackTrace stack) {
            if (generation != _generation) return;
            _onStreamEnd(generation, '$e');
            // Explicitly handle the cancellation Future. The browser's
            // ReadableStream reader may reject cancel() after a network error.
            _cancelSubscription();
          },
          onDone: () =>
              _onStreamEnd(generation, 'Connection closed by the server.'),
          // Automatic cancellation cannot observe errors from reader.cancel().
          cancelOnError: false,
        );

    try {
      _postUrl = await _endpoint!.future.timeout(
        endpointTimeout,
        onTimeout: () => throw McpException(
          'The server opened the stream but never sent an "endpoint" event.',
        ),
      );
    } on McpException {
      _teardown('No endpoint.');
      rethrow;
    }
  }

  void _onLine(String line) {
    if (line.isEmpty) {
      _dispatch();
      return;
    }
    if (line.startsWith(':')) return; // comment / keep-alive
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _event = value;
    } else if (field == 'data') {
      _data.add(value);
    }
  }

  void _dispatch() {
    final name = _event ?? 'message';
    final data = _data.join('\n');
    final hadData = _data.isNotEmpty;
    _event = null;
    _data.clear();
    if (!hadData) return;

    if (name == 'endpoint') {
      final endpoint = _endpoint;
      if (endpoint == null || endpoint.isCompleted) return;
      final resolved = _url.resolve(data.trim());
      // The POST target receives our credentials, so it must stay on the
      // server we were pointed at.
      if (resolved.scheme != _url.scheme ||
          resolved.host != _url.host ||
          resolved.port != _url.port) {
        endpoint.completeError(
          McpException(
            'The server announced a message endpoint on a different origin '
            '($resolved). Refusing to send credentials there.',
          ),
        );
        return;
      }
      _log('endpoint: ${resolved.path}${resolved.hasQuery ? '?…' : ''}');
      endpoint.complete(resolved);
      return;
    }
    if (name != 'message') return;

    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['id'] is! int) return;
    final pending = _pending[decoded['id']];
    if (pending == null || pending.isCompleted) return;
    if (decoded.containsKey('result') || decoded.containsKey('error')) {
      pending.complete(decoded.cast<String, dynamic>());
    }
  }

  void _onStreamEnd(int generation, String reason) {
    if (generation != _generation) return; // an older stream
    _connected = false;
    _failAll(reason);
  }

  void _failAll(String reason) {
    final endpoint = _endpoint;
    if (endpoint != null && !endpoint.isCompleted) {
      endpoint.completeError(McpException(reason));
    }
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(McpException(reason));
    }
    _pending.clear();
  }

  void _cancelSubscription() {
    final sub = _subscription;
    _subscription = null;
    if (sub == null) return;
    // package:http's BrowserClient uses ReadableStreamDefaultReader.cancel().
    // A reader that already failed or was aborted can reject that request.
    // Cancellation is best-effort; a rejected cleanup Future must not reach
    // the unhandled-async-error handler or repeatedly interrupt the debugger.
    unawaited(sub.cancel().catchError((Object _) {}));
  }

  void _teardown(String reason) {
    _generation++;
    _connected = false;
    _cancelSubscription();
    _failAll(reason);
    _postUrl = null;
  }

  // ---------------------------------------------------------------- requests

  Future<Json> _request(
    String method,
    Json? params, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_connected) {
      // The stream dropped (sleep, proxy timeout…): start a new session once.
      await connect();
    }
    return _rpc(method, params, timeout: timeout);
  }

  Future<Json> _rpc(
    String method,
    Json? params, {
    required Duration timeout,
  }) async {
    final id = _nextId++;
    final completer = Completer<Json>();
    _pending[id] = completer;
    try {
      await _post(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': ?params,
        }),
      );
      final message = await completer.future.timeout(
        timeout,
        onTimeout: () => throw McpException(
          'Timed out after ${timeout.inSeconds}s waiting for "$method".',
        ),
      );
      final error = message['error'];
      if (error is Map) {
        throw McpException(
          '${error['message'] ?? 'MCP error'}',
          code: error['code'] as int?,
        );
      }
      final result = message['result'];
      return result is Map
          ? result.cast<String, dynamic>()
          : <String, dynamic>{};
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> _post(String body, {bool allowReauth = true}) async {
    final target = _postUrl;
    if (target == null) throw McpException('No message endpoint yet.');
    final token = await tokenProvider?.call(forceRefresh: false);
    final http.Response response;
    try {
      response = await _http
          .post(
            target,
            headers: _headers(token: token, json: true),
            body: body,
          )
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw McpException('Timed out sending a request to $target.');
    } on http.ClientException catch (e) {
      throw _networkError(e);
    }

    if (response.statusCode == 401) {
      if (tokenProvider != null &&
          allowReauth &&
          await tokenProvider!(forceRefresh: true) != null) {
        return _post(body, allowReauth: false);
      }
      throw McpAuthRequired(
        _unauthorizedMessage(),
        wwwAuthenticate: response.headers['www-authenticate'],
      );
    }
    if (response.statusCode == 404 || response.statusCode == 410) {
      // The server forgot this session; the stream is useless now.
      _connected = false;
      throw McpException(
        'The server no longer knows this session (HTTP ${response.statusCode}).',
        code: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw McpException(
        'HTTP ${response.statusCode}: ${truncate(response.body, 300)}',
        code: response.statusCode,
      );
    }
  }

  String _unauthorizedMessage() =>
      unauthorizedMessage(config, oauth: tokenProvider != null);

  McpException _networkError(http.ClientException e) => McpException(
    'Could not reach $_url (${e.message}). '
    'From a browser the server must also allow CORS for this origin.',
  );
}
