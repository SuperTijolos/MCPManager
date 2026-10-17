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
  final list = <ConnectionAttempt>[
    if (url.path.endsWith('/sse')) ...[
      (transport: McpTransport.sse, url: url),
      (transport: McpTransport.streamableHttp, url: url),
    ] else ...[
      (transport: McpTransport.streamableHttp, url: url),
      (transport: McpTransport.sse, url: url),
    ],
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
      try {
        final info = await connection.connect();
        _active = connection;
        return info;
      } on McpAuthRequired {
        connection.close();
        rethrow; // reached the right endpoint; it just needs credentials
      } on McpException catch (e) {
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
  Future<List<McpTool>> listTools() => _connection.listTools();

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
