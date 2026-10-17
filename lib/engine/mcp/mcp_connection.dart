import '../core/json.dart';
import 'mcp_models.dart';

/// A live session with one MCP server, independent of the HTTP transport used.
abstract interface class McpConnection {
  bool get isConnected;

  /// The transport actually in use ([McpTransport.auto] until connected).
  McpTransport get transport;

  /// The URL actually in use; may differ from the configured one when the
  /// endpoint was auto-detected (for example `…/sse` for a bare host:port).
  String get endpointUrl;

  Future<McpServerInfo> connect();
  Future<List<McpTool>> listTools();
  Future<McpToolResult> callTool(String name, Json arguments);
  Future<void> ping();
  void close();
}

typedef TokenProvider = Future<String?> Function({bool forceRefresh});

/// Wording for a 401, depending on how the server is configured.
String unauthorizedMessage(McpServerConfig config, {required bool oauth}) =>
    oauth
    ? 'Unauthorized (HTTP 401). Sign-in is required.'
    : config.hasStaticAuthorization
    ? 'Unauthorized (HTTP 401). Check the server headers/token.'
    : 'Unauthorized (HTTP 401). This server needs credentials: edit it and '
          'add a bearer token, or choose OAuth if it supports it.';
