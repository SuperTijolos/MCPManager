import 'package:mcp_core/mcp_core.dart';

/// An MCP server the gateway talks to. Its headers are secrets: they are
/// stored here but never sent back to a client (see [toPublicJson]).
class UpstreamServer {
  const UpstreamServer({
    required this.id,
    required this.name,
    required this.slug,
    required this.url,
    this.headers = const {},
    this.transport = McpTransport.auto,
    this.enabled = true,
  });

  final String id;
  final String name;

  /// Prefix of the tool names it exposes: `<slug>__<tool>`.
  final String slug;
  final String url;
  final Map<String, String> headers;
  final McpTransport transport;
  final bool enabled;

  McpServerConfig toConfig() => McpServerConfig(
    id: id,
    name: name,
    url: url,
    headers: headers,
    enabled: enabled,
    transport: transport,
  );

  UpstreamServer copyWith({
    String? name,
    String? slug,
    String? url,
    Map<String, String>? headers,
    McpTransport? transport,
    bool? enabled,
  }) => UpstreamServer(
    id: id,
    name: name ?? this.name,
    slug: slug ?? this.slug,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    transport: transport ?? this.transport,
    enabled: enabled ?? this.enabled,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'url': url,
    'headers': headers,
    'transport': transport.wire,
    'enabled': enabled,
  };

  /// What an API client may see: header names, never their values.
  Json toPublicJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'url': url,
    'headerNames': headers.keys.toList()..sort(),
    'transport': transport.wire,
    'enabled': enabled,
  };

  factory UpstreamServer.fromJson(Json json) => UpstreamServer(
    id: json['id'] as String,
    name: json['name'] as String,
    slug: json['slug'] as String,
    url: json['url'] as String,
    headers: {
      for (final e in ((json['headers'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    },
    transport: McpTransport.parse(json['transport']),
    enabled: json['enabled'] as bool? ?? true,
  );
}

class PortalServerRef {
  const PortalServerRef(this.serverId, {this.enabled = true});
  final String serverId;
  final bool enabled;

  Json toJson() => {'serverId': serverId, 'enabled': enabled};

  factory PortalServerRef.fromJson(Json json) => PortalServerRef(
    json['serverId'] as String,
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// One MCP endpoint (`/mcp/<slug>`) exposing a chosen set of servers.
class Portal {
  const Portal({
    required this.id,
    required this.slug,
    required this.name,
    this.description = '',
    this.enabled = true,
    this.servers = const [],
    this.excludedTools = const [],
  });

  final String id;
  final String slug;
  final String name;
  final String description;
  final bool enabled;
  final List<PortalServerRef> servers;

  /// Tools left out of this portal only, as `serverId/toolName`.
  final List<String> excludedTools;

  Portal copyWith({
    String? slug,
    String? name,
    String? description,
    bool? enabled,
    List<PortalServerRef>? servers,
    List<String>? excludedTools,
  }) => Portal(
    id: id,
    slug: slug ?? this.slug,
    name: name ?? this.name,
    description: description ?? this.description,
    enabled: enabled ?? this.enabled,
    servers: servers ?? this.servers,
    excludedTools: excludedTools ?? this.excludedTools,
  );

  Json toJson() => {
    'id': id,
    'slug': slug,
    'name': name,
    'description': description,
    'enabled': enabled,
    'servers': [for (final s in servers) s.toJson()],
    'excludedTools': excludedTools,
  };

  factory Portal.fromJson(Json json) => Portal(
    id: json['id'] as String,
    slug: json['slug'] as String,
    name: json['name'] as String,
    description: json['description'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    servers: [
      for (final s in (json['servers'] as List?) ?? const [])
        PortalServerRef.fromJson((s as Map).cast<String, dynamic>()),
    ],
    excludedTools: [
      for (final t in (json['excludedTools'] as List?) ?? const []) '$t',
    ],
  );
}

/// A bearer credential for MCP clients. Only its hash is stored.
class AccessToken {
  const AccessToken({
    required this.id,
    required this.name,
    required this.hash,
    required this.prefix,
    required this.createdAt,
    this.portalIds = const [],
    this.lastUsedAt,
    this.revokedAt,
    this.expiresAt,
  });

  final String id;
  final String name;
  final String hash;

  /// The first characters of the secret, to recognise it in a list.
  final String prefix;

  /// Portals it opens; empty means every portal.
  final List<String> portalIds;
  final DateTime createdAt;
  final DateTime? lastUsedAt;
  final DateTime? revokedAt;
  final DateTime? expiresAt;

  bool get revoked => revokedAt != null;
  bool expired(DateTime now) => expiresAt != null && !expiresAt!.isAfter(now);

  bool allows(String portalId) =>
      portalIds.isEmpty || portalIds.contains(portalId);

  AccessToken copyWith({DateTime? lastUsedAt, DateTime? revokedAt}) =>
      AccessToken(
        id: id,
        name: name,
        hash: hash,
        prefix: prefix,
        createdAt: createdAt,
        portalIds: portalIds,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        revokedAt: revokedAt ?? this.revokedAt,
        expiresAt: expiresAt,
      );

  Json toJson() => {
    'id': id,
    'name': name,
    'hash': hash,
    'prefix': prefix,
    'portalIds': portalIds,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastUsedAt != null) 'lastUsedAt': lastUsedAt!.toUtc().toIso8601String(),
    if (revokedAt != null) 'revokedAt': revokedAt!.toUtc().toIso8601String(),
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
  };

  /// Without the hash.
  Json toPublicJson() => {...toJson()..remove('hash')};

  factory AccessToken.fromJson(Json json) => AccessToken(
    id: json['id'] as String,
    name: json['name'] as String,
    hash: json['hash'] as String,
    prefix: json['prefix'] as String? ?? '',
    portalIds: [for (final p in (json['portalIds'] as List?) ?? const []) '$p'],
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastUsedAt: _date(json['lastUsedAt']),
    revokedAt: _date(json['revokedAt']),
    expiresAt: _date(json['expiresAt']),
  );
}

DateTime? _date(Object? v) => v == null ? null : DateTime.parse('$v');

/// A client registered through OAuth dynamic client registration.
class OAuthClient {
  const OAuthClient({
    required this.clientId,
    required this.clientName,
    required this.redirectUris,
    required this.createdAt,
  });

  final String clientId;
  final String clientName;
  final List<String> redirectUris;
  final DateTime createdAt;

  Json toJson() => {
    'clientId': clientId,
    'clientName': clientName,
    'redirectUris': redirectUris,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  factory OAuthClient.fromJson(Json json) => OAuthClient(
    clientId: json['clientId'] as String,
    clientName: json['clientName'] as String? ?? 'MCP client',
    redirectUris: [
      for (final u in (json['redirectUris'] as List?) ?? const []) '$u',
    ],
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// An OAuth access or refresh token issued to a client. Only hashes are kept.
class OAuthGrant {
  const OAuthGrant({
    required this.hash,
    required this.kind,
    required this.clientId,
    required this.expiresAt,
    required this.createdAt,
    this.portalId,
    this.revokedAt,
  });

  final String hash;

  /// `access` or `refresh`.
  final String kind;
  final String clientId;

  /// The portal the client asked for (RFC 8707 `resource`); null opens all.
  final String? portalId;
  final DateTime expiresAt;
  final DateTime createdAt;
  final DateTime? revokedAt;

  OAuthGrant revoke(DateTime at) => OAuthGrant(
    hash: hash,
    kind: kind,
    clientId: clientId,
    expiresAt: expiresAt,
    createdAt: createdAt,
    portalId: portalId,
    revokedAt: at,
  );

  Json toJson() => {
    'hash': hash,
    'kind': kind,
    'clientId': clientId,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'portalId': ?portalId,
    if (revokedAt != null) 'revokedAt': revokedAt!.toUtc().toIso8601String(),
  };

  factory OAuthGrant.fromJson(Json json) => OAuthGrant(
    hash: json['hash'] as String,
    kind: json['kind'] as String,
    clientId: json['clientId'] as String,
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    createdAt: DateTime.parse(json['createdAt'] as String),
    portalId: json['portalId'] as String?,
    revokedAt: _date(json['revokedAt']),
  );
}
