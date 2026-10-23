import '../core/json.dart';

DateTime? _date(Object? v) =>
    v == null ? null : DateTime.tryParse('$v')?.toLocal();

List<String> _strings(Object? v) => [
  for (final x in (v as List?) ?? const []) '$x',
];

/// What the gateway reports about itself.
class GatewayStatus {
  const GatewayStatus({
    required this.version,
    required this.baseUrl,
    this.servers = 0,
    this.portals = 0,
    this.tokens = 0,
    this.rules = 0,
  });

  final String version;
  final String baseUrl;
  final int servers;
  final int portals;
  final int tokens;
  final int rules;

  factory GatewayStatus.fromJson(Json json) => GatewayStatus(
    version: '${json['version'] ?? ''}',
    baseUrl: '${json['baseUrl'] ?? ''}',
    servers: (json['servers'] as num?)?.toInt() ?? 0,
    portals: (json['portals'] as num?)?.toInt() ?? 0,
    tokens: (json['tokens'] as num?)?.toInt() ?? 0,
    rules: (json['rules'] as num?)?.toInt() ?? 0,
  );
}

/// An upstream MCP server held by the gateway. Header values are never sent
/// back, only their names.
class GatewayServer {
  const GatewayServer({
    required this.id,
    required this.name,
    required this.slug,
    required this.url,
    this.headerNames = const [],
    this.transport = 'auto',
    this.enabled = true,
  });

  final String id;
  final String name;
  final String slug;
  final String url;
  final List<String> headerNames;
  final String transport;
  final bool enabled;

  factory GatewayServer.fromJson(Json json) => GatewayServer(
    id: json['id'] as String,
    name: json['name'] as String,
    slug: json['slug'] as String? ?? '',
    url: json['url'] as String? ?? '',
    headerNames: _strings(json['headerNames']),
    transport: json['transport'] as String? ?? 'auto',
    enabled: json['enabled'] as bool? ?? true,
  );
}

class GatewayPortalServer {
  const GatewayPortalServer(this.serverId, {this.enabled = true});
  final String serverId;
  final bool enabled;

  Json toJson() => {'serverId': serverId, 'enabled': enabled};
}

class GatewayPortal {
  const GatewayPortal({
    required this.id,
    required this.slug,
    required this.name,
    required this.endpoint,
    this.description = '',
    this.enabled = true,
    this.servers = const [],
    this.excludedTools = const [],
  });

  final String id;
  final String slug;
  final String name;

  /// The URL MCP clients connect to.
  final String endpoint;
  final String description;
  final bool enabled;
  final List<GatewayPortalServer> servers;

  /// `serverId/toolName` of tools left out of this portal.
  final List<String> excludedTools;

  factory GatewayPortal.fromJson(Json json) => GatewayPortal(
    id: json['id'] as String,
    slug: json['slug'] as String,
    name: json['name'] as String,
    endpoint: json['endpoint'] as String? ?? '',
    description: json['description'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    servers: [
      for (final s in (json['servers'] as List?) ?? const [])
        GatewayPortalServer(
          (s as Map)['serverId'] as String,
          enabled: s['enabled'] as bool? ?? true,
        ),
    ],
    excludedTools: _strings(json['excludedTools']),
  );
}

class GatewayToken {
  const GatewayToken({
    required this.id,
    required this.name,
    required this.prefix,
    required this.createdAt,
    this.portalIds = const [],
    this.lastUsedAt,
    this.revokedAt,
    this.expiresAt,
  });

  final String id;
  final String name;

  /// The first characters of the secret, to recognise it.
  final String prefix;
  final DateTime? createdAt;

  /// Empty means every portal.
  final List<String> portalIds;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;
  final DateTime? expiresAt;

  bool active(DateTime now) =>
      revokedAt == null && (expiresAt == null || expiresAt!.isAfter(now));

  factory GatewayToken.fromJson(Json json) => GatewayToken(
    id: json['id'] as String,
    name: json['name'] as String,
    prefix: json['prefix'] as String? ?? '',
    createdAt: _date(json['createdAt']),
    portalIds: _strings(json['portalIds']),
    lastUsedAt: _date(json['lastUsedAt']),
    revokedAt: _date(json['revokedAt']),
    expiresAt: _date(json['expiresAt']),
  );
}

/// A token just created: the only time its secret is available.
class CreatedToken {
  const CreatedToken(this.token, this.secret);
  final GatewayToken token;
  final String secret;
}

/// One tool as a portal exposes it.
class GatewayTool {
  const GatewayTool({
    required this.name,
    required this.serverId,
    required this.serverName,
    required this.tool,
    this.title,
    this.description = '',
    this.visible = true,
    this.excluded = false,
    this.rules = const [],
    this.readOnly = false,
  });

  /// The name MCP clients see (`<server slug>__<tool>`).
  final String name;
  final String serverId;
  final String serverName;

  /// The server's own name for it.
  final String tool;
  final String? title;
  final String description;
  final bool visible;

  /// Left out of this portal in its settings.
  final bool excluded;
  final List<String> rules;
  final bool readOnly;

  /// `serverId/toolName`, how portals list their exclusions.
  String get key => '$serverId/$tool';

  factory GatewayTool.fromJson(Json json) => GatewayTool(
    name: json['name'] as String,
    serverId: json['serverId'] as String? ?? '',
    serverName: json['serverName'] as String? ?? '',
    tool: json['tool'] as String? ?? '',
    title: json['title'] as String?,
    description: json['description'] as String? ?? '',
    visible: json['visible'] as bool? ?? true,
    excluded: json['excluded'] as bool? ?? false,
    rules: _strings(json['rules']),
    readOnly: json['readOnly'] as bool? ?? false,
  );
}

class GatewayToolList {
  const GatewayToolList(this.tools, this.problems);
  final List<GatewayTool> tools;

  /// Server id → why its tools are missing.
  final Map<String, String> problems;
}

class GatewayTestResult {
  const GatewayTestResult({
    required this.ok,
    this.error,
    this.toolCount = 0,
    this.tools = const [],
    this.serverName,
    this.serverVersion,
    this.transport,
  });

  final bool ok;
  final String? error;
  final int toolCount;
  final List<String> tools;
  final String? serverName;
  final String? serverVersion;
  final String? transport;

  factory GatewayTestResult.fromJson(Json json) {
    final server = json['server'];
    return GatewayTestResult(
      ok: json['ok'] as bool? ?? false,
      error: json['error'] as String?,
      toolCount: (json['toolCount'] as num?)?.toInt() ?? 0,
      tools: _strings(json['tools']),
      serverName: server is Map ? server['name'] as String? : null,
      serverVersion: server is Map ? server['version'] as String? : null,
      transport: json['transport'] as String?,
    );
  }
}

/// One call that went through a portal.
class GatewayEvent {
  const GatewayEvent({
    required this.id,
    required this.timestamp,
    required this.portalId,
    required this.portalSlug,
    required this.callerKind,
    required this.callerName,
    required this.status,
    this.serverName,
    this.tool,
    this.exposedName,
    this.durationMs,
    this.args,
    this.forwarded,
    this.context,
    this.result,
    this.error,
    this.rules = const [],
  });

  final String id;
  final DateTime timestamp;
  final String portalId;
  final String portalSlug;

  /// `token` or `oauth`.
  final String callerKind;
  final String callerName;

  /// `success`, `error` or `denied`.
  final String status;
  final String? serverName;
  final String? tool;
  final String? exposedName;
  final int? durationMs;
  final String? args;
  final String? forwarded;
  final String? context;
  final String? result;
  final String? error;
  final List<String> rules;

  String get title => '${serverName ?? '?'} · ${tool ?? exposedName ?? '?'}';

  factory GatewayEvent.fromJson(Json json) {
    final principal = ((json['principal'] as Map?) ?? const {})
        .cast<String, dynamic>();
    return GatewayEvent(
      id: json['id'] as String,
      timestamp: _date(json['ts']) ?? DateTime.fromMillisecondsSinceEpoch(0),
      portalId: json['portalId'] as String? ?? '',
      portalSlug: json['portalSlug'] as String? ?? '',
      callerKind: principal['kind'] as String? ?? 'token',
      callerName: principal['name'] as String? ?? 'unknown',
      status: json['status'] as String? ?? 'success',
      serverName: json['serverName'] as String?,
      tool: json['tool'] as String?,
      exposedName: json['exposedName'] as String?,
      durationMs: (json['durationMs'] as num?)?.toInt(),
      args: json['args'] as String?,
      forwarded: json['forwarded'] as String?,
      context: json['context'] as String?,
      result: json['result'] as String?,
      error: json['error'] as String?,
      rules: _strings(json['rules']),
    );
  }
}

/// `Dev Tools!` → `dev-tools`: what the gateway would make of a name.
String slugify(String text) {
  final slug = text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  if (slug.isEmpty) return '';
  return slug.length > 63 ? slug.substring(0, 63) : slug;
}
