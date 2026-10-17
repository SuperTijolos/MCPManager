import 'dart:convert';

import '../core/json.dart';

class McpServerConfig {
  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
    this.enabled = true,
  });

  final String id;
  final String name;

  /// Streamable HTTP endpoint, e.g. `https://example.com/mcp`.
  final String url;

  /// Extra request headers, typically `Authorization: Bearer …`.
  final Map<String, String> headers;
  final bool enabled;

  McpServerConfig copyWith({
    String? name,
    String? url,
    Map<String, String>? headers,
    bool? enabled,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    enabled: enabled ?? this.enabled,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'headers': headers,
    'enabled': enabled,
  };

  factory McpServerConfig.fromJson(Json json) => McpServerConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    url: json['url'] as String,
    headers: ((json['headers'] as Map?) ?? const {}).map(
      (k, v) => MapEntry('$k', '$v'),
    ),
    enabled: json['enabled'] as bool? ?? true,
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
