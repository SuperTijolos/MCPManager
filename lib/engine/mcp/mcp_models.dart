import 'dart:convert';

import '../core/json.dart';

/// How to talk to an MCP server over HTTP.
enum McpTransport {
  /// Try Streamable HTTP, then the legacy HTTP+SSE transport.
  auto('auto', 'Auto-detect'),

  /// Current spec: POST JSON-RPC to one endpoint (replies as JSON or SSE).
  streamableHttp('streamable-http', 'Streamable HTTP'),

  /// Legacy 2024-11-05 spec: GET an SSE stream, POST to the endpoint it names.
  sse('sse', 'Legacy SSE');

  const McpTransport(this.wire, this.label);

  /// Value stored on disk and accepted from the Operator.
  final String wire;
  final String label;

  static McpTransport parse(Object? value) {
    for (final t in values) {
      if (t.wire == '$value') return t;
    }
    return McpTransport.auto;
  }
}

class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
    this.enabled = true,
    this.oauth = false,
    this.oauthClientId,
    this.oauthScope,
    this.transport = McpTransport.auto,
  });

  final String id;
  final String name;

  /// Streamable HTTP endpoint, e.g. `https://example.com/mcp`.
  final String url;

  /// Extra request headers, typically `Authorization: Bearer …`.
  final Map<String, String> headers;
  final bool enabled;

  /// Sign in with OAuth (MCP authorization) instead of a static token.
  final bool oauth;

  /// Pre-registered client id, for servers without dynamic client registration.
  final String? oauthClientId;
  final String? oauthScope;

  /// Which HTTP transport to use; `auto` detects it on connect.
  final McpTransport transport;

  /// A manually configured `Authorization` header (bearer-token mode).
  bool get hasStaticAuthorization =>
      headers.keys.any((k) => k.toLowerCase() == 'authorization');

  McpServerConfig copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
    bool? oauth,
    String? oauthClientId,
    String? oauthScope,
    bool clearOAuthOptions = false,
    McpTransport? transport,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
    oauth: oauth ?? this.oauth,
    oauthClientId: clearOAuthOptions
        ? null
        : oauthClientId ?? this.oauthClientId,
    oauthScope: clearOAuthOptions ? null : oauthScope ?? this.oauthScope,
    transport: transport ?? this.transport,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'headers': headers,
    'enabled': enabled,
    'oauth': oauth,
    'oauthClientId': ?oauthClientId,
    'oauthScope': ?oauthScope,
    'transport': transport.wire,
  };

  factory McpServerConfig.fromJson(Json json) => McpServerConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    url: json['url'] as String,
    headers: ((json['headers'] as Map?) ?? const {}).map(
      (k, v) => MapEntry('$k', '$v'),
    ),
    enabled: json['enabled'] as bool? ?? true,
    oauth: json['oauth'] as bool? ?? false,
    oauthClientId: json['oauthClientId'] as String?,
    oauthScope: json['oauthScope'] as String?,
    transport: McpTransport.parse(json['transport']),
  );
}

class McpServerInfo {
  const McpServerInfo({
    required this.name,
    required this.version,
    required this.protocolVersion,
    this.instructions,
  });

  final String name;
  final String version;
  final String protocolVersion;
  final String? instructions;
}

class McpTool {
  const McpTool({
    required this.name,
    required this.inputSchema,
    this.title,
    this.description,
    this.annotations = const {},
  });

  final String name;
  final String? title;
  final String? description;
  final Json inputSchema;
  final Json annotations;

  factory McpTool.fromJson(Json json) => McpTool(
    name: json['name'] as String,
    title: json['title'] as String?,
    description: json['description'] as String?,
    inputSchema:
        (json['inputSchema'] as Map?)?.cast<String, dynamic>() ??
        {'type': 'object'},
    annotations: (json['annotations'] as Map?)?.cast<String, dynamic>() ?? {},
  );

  String get displayName => title ?? annotations['title'] as String? ?? name;

  /// Only tools that explicitly declare themselves read-only skip approval.
  /// MCP's defaults assume a tool may be destructive, so unannotated tools
  /// are treated as needing a human decision.
  bool get isReadOnly => annotations['readOnlyHint'] == true;

  bool get isDestructive =>
      !isReadOnly && annotations['destructiveHint'] != false;
}

class McpToolResult {
  const McpToolResult({
    required this.text,
    this.isError = false,
    this.structured,
    this.raw,
  });

  factory McpToolResult.error(String message) =>
      McpToolResult(text: message, isError: true);

  final String text;
  final bool isError;
  final Object? structured;
  final Json? raw;

  factory McpToolResult.fromJson(Json json) {
    final parts = <String>[];
    for (final item in (json['content'] as List?) ?? const []) {
      if (item is! Map) continue;
      switch (item['type']) {
        case 'text':
          parts.add('${item['text'] ?? ''}');
        case 'image':
          parts.add('[image: ${item['mimeType'] ?? 'unknown'}]');
        case 'audio':
          parts.add('[audio: ${item['mimeType'] ?? 'unknown'}]');
        case 'resource':
          final resource = item['resource'];
          if (resource is Map && resource['text'] != null) {
            parts.add('${resource['text']}');
          } else {
            parts.add('[resource: ${resource is Map ? resource['uri'] : ''}]');
          }
        case 'resource_link':
          parts.add('[resource link: ${item['uri']}]');
        default:
          parts.add(jsonEncode(item));
      }
    }
    final structured = json['structuredContent'];
    return McpToolResult(
      text: parts.isNotEmpty
          ? parts.join('\n')
          : structured != null
          ? jsonEncode(structured)
          : '',
      isError: json['isError'] == true,
      structured: structured,
      raw: json,
    );
  }
}

class McpException implements Exception {
  McpException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => message;
}

/// The server answered 401: it needs (new) credentials.
class McpAuthRequired extends McpException {
  McpAuthRequired(super.message, {this.wwwAuthenticate}) : super(code: 401);

  /// Raw `WWW-Authenticate` header, when the browser let us read it.
  final String? wwwAuthenticate;
}
