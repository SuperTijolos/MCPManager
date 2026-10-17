import 'package:http/http.dart' as http;

import '../core/json.dart';
import 'mcp_client.dart';
import 'mcp_connection.dart';
import 'mcp_models.dart';
import 'mcp_sse_client.dart';

typedef ConnectionAttempt = ({McpTransport transport, Uri url});

/// Statuses that mean "this endpoint does not speak that transport" rather
/// than "the server is down". The spec tells clients to fall back on 400, 404
/// and 405; 406 covers a GET that did not return an event stream.
const _fallbackCodes = {400, 404, 405, 406};

/// The transport/URL combinations to try for [config], in order.
///
/// - An explicit transport is used as is.
/// - A URL ending in `/sse` tries the legacy transport first.
/// - A bare `host:port` also tries the conventional `/mcp` and `/sse` paths,
///   so `http://localhost:3333` finds `…/sse` without the user knowing it.
List<ConnectionAttempt> connectionCandidates(McpServerConfig config) {
  final url = Uri.parse(config.url);
  if (config.transport != McpTransport.auto) {
    return [(transport: config.transport, url: url)];
  }
  final bare = url.path.isEmpty || url.path == '/';
  final origin = Uri(
    scheme: url.scheme,
    host: url.host,
    port: url.hasPort ? url.port : null,
  );
  // `/mcp` and `/sse` are the conventional pair of endpoints; servers such as
  // Cloudflare's offer both, so try the sibling of whichever was given.
  Uri? sibling(String from, String to) => url.path.endsWith('/$from')
      ? url.replace(
          path: '${url.path.substring(0, url.path.length - from.length)}$to',
        )
      : null;
  final siblingSse = sibling('mcp', 'sse');
  final siblingMcp = sibling('sse', 'mcp');
  final list = <ConnectionAttempt>[
    if (url.path.endsWith('/sse')) ...[
      (transport: McpTransport.sse, url: url),
      (transport: McpTransport.streamableHttp, url: url),
    ] else ...[
      (transport: McpTransport.streamableHttp, url: url),
      (transport: McpTransport.sse, url: url),
    ],
    if (siblingSse != null) (transport: McpTransport.sse, url: siblingSse),
    if (siblingMcp != null)
      (transport: McpTransport.streamableHttp, url: siblingMcp),
    if (bare) ...[
      (
        transport: McpTransport.streamableHttp,
        url: origin.replace(path: '/mcp'),
      ),
      (transport: McpTransport.sse, url: origin.replace(path: '/sse')),
    ],
  ];
  final seen = <String>{};
  return [
    for (final a in list)
      if (seen.add('${a.transport.wire} ${a.url}')) a,
  ];
}

McpConnection createMcpConnection(
  McpServerConfig config, {
  required http.Client httpClient,
  TokenProvider? tokenProvider,
}) => switch (config.transport) {
  McpTransport.streamableHttp => McpClient(
    config,
    httpClient: httpClient,
    tokenProvider: tokenProvider,
  ),
  McpTransport.sse => McpSseClient(
    config,
    httpClient: httpClient,
    tokenProvider: tokenProvider,
  ),
  McpTransport.auto => AutoMcpConnection(
    config,
    httpClient: httpClient,
    tokenProvider: tokenProvider,
  ),
};

/// Tries each candidate transport/URL until one completes the handshake.
class AutoMcpConnection implements McpConnection {
  AutoMcpConnection(
    this.config, {
    required http.Client httpClient,
    this.tokenProvider,
  }) : _http = httpClient;

  final McpServerConfig config;
  final TokenProvider? tokenProvider;
  final http.Client _http;

  McpConnection? _active;
  List<McpTool>? _discovered;
  final List<String> _trace = [];

  @override
  List<String> get trace => List.unmodifiable(_trace);

  @override
  bool get isConnected => _active?.isConnected ?? false;

  @override
  McpTransport get transport => _active?.transport ?? McpTransport.auto;

  @override
  String get endpointUrl => _active?.endpointUrl ?? config.url;

  @override
  Future<McpServerInfo> connect() async {
    _active?.close();
    _active = null;
    _discovered = null;
    _trace.clear();
    final attempts = <String>[];
    McpException? last;

    for (final candidate in connectionCandidates(config)) {
      final attemptConfig = config.copyWith(
        url: candidate.url.toString(),
        transport: candidate.transport,
      );
      final connection = candidate.transport == McpTransport.sse
          ? McpSseClient(
              attemptConfig,
              httpClient: _http,
              tokenProvider: tokenProvider,
            )
          : McpClient(
              attemptConfig,
              httpClient: _http,
              tokenProvider: tokenProvider,
            );
      _trace.add('— ${candidate.transport.label} at ${candidate.url} —');
      try {
        final info = await connection.connect();
        // Completing the handshake is not enough: some servers accept
        // `initialize` and then refuse everything (for example when they
        // cannot keep the session). Only a transport that can also list the
        // tools is accepted; otherwise the next one is tried.
        final tools = await connection.listTools();
        _trace.addAll(connection.trace);
        _active = connection;
        _discovered = tools;
        return info;
      } on McpAuthRequired {
        _trace.addAll(connection.trace);
        connection.close();
        rethrow; // reached the right endpoint; it just needs credentials
      } on McpException catch (e) {
        _trace
          ..addAll(connection.trace)
          ..add('failed: ${e.message}');
        connection.close();
        // Anything other than "wrong endpoint/transport" (network error,
        // timeout, server error) will not be fixed by trying another path.
        if (!_fallbackCodes.contains(e.code)) rethrow;
        last = e;
        attempts.add(
          '${candidate.transport.label} at ${candidate.url} (${e.message})',
        );
      }
    }
    throw McpException(
      'No MCP transport worked. Tried: ${attempts.join('; ')}. '
      'Check the endpoint path (commonly /mcp for Streamable HTTP or /sse for '
      'legacy SSE servers).',
      code: last?.code,
    );
  }

  McpConnection get _connection =>
      _active ?? (throw McpException('Not connected.'));

  @override
  Future<List<McpTool>> listTools() async {
    // The first call returns what the handshake already discovered.
    final cached = _discovered;
    if (cached != null) {
      _discovered = null;
      return cached;
    }
    return _connection.listTools();
  }

  @override
  Future<McpToolResult> callTool(String name, Json arguments) =>
      _connection.callTool(name, arguments);

  @override
  Future<void> ping() => _connection.ping();

  @override
  void close() {
    _active?.close();
    _active = null;
  }
}
