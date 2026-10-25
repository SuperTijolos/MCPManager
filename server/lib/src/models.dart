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
    this.oauth = false,
    this.oauthClientId,
    this.oauthScope,
  });

  final String id;
  final String name;

  /// Prefix of the tool names it exposes: `<slug>__<tool>`.
  final String slug;
  final String url;
  final Map<String, String> headers;
  final McpTransport transport;
  final bool enabled;

  /// The server asks for an OAuth sign-in instead of a static token. The
  /// gateway holds the tokens (see `UpstreamOAuth`).
  final bool oauth;

  /// A client id registered by hand, for servers without dynamic registration.
  final String? oauthClientId;
  final String? oauthScope;

  McpServerConfig toConfig() => McpServerConfig(
    id: id,
    name: name,
    url: url,
    headers: headers,
    enabled: enabled,
    transport: transport,
    oauth: oauth,
    oauthClientId: oauthClientId,
    oauthScope: oauthScope,
  );

  UpstreamServer copyWith({
    String? name,
    String? slug,
    String? url,
    Map<String, String>? headers,
    McpTransport? transport,
    bool? enabled,
    bool? oauth,
  }) => UpstreamServer(
    id: id,
    name: name ?? this.name,
    slug: slug ?? this.slug,
    url: url ?? this.url,
    headers: headers ?? this.headers,
    transport: transport ?? this.transport,
    enabled: enabled ?? this.enabled,
    oauth: oauth ?? this.oauth,
    oauthClientId: oauthClientId,
    oauthScope: oauthScope,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'slug': slug,
    'url': url,
    'headers': headers,
    'transport': transport.wire,
    'enabled': enabled,
    'oauth': oauth,
    'oauthClientId': ?oauthClientId,
    'oauthScope': ?oauthScope,
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
    'oauth': oauth,
    'oauthClientId': ?oauthClientId,
    'oauthScope': ?oauthScope,
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
    oauth: json['oauth'] as bool? ?? false,
    oauthClientId: json['oauthClientId'] as String?,
    oauthScope: json['oauthScope'] as String?,
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

/// Someone allowed into the dashboard. Today they sign in with GitHub; the
/// id is `<provider>:<provider id>` so other providers can follow.
class Member {
  const Member({
    required this.id,
    required this.login,
    required this.createdAt,
    this.name,
    this.email,
    this.avatarUrl,
    this.orgs = const [],
    this.emails = const [],
    this.provider = 'github',
    this.role = 'admin',
    this.lastSeenAt,
  });

  final String id;
  final String login;
  final String? name;
  final String? email;
  final String? avatarUrl;

  /// The GitHub organisations they belonged to at their last sign-in.
  final List<String> orgs;

  /// Email addresses the sign-in provider says are verified.
  final List<String> emails;

  /// The sign-in provider they came through (its id, e.g. `github`).
  final String provider;
  final String role;
  final DateTime createdAt;
  final DateTime? lastSeenAt;

  Member copyWith({
    String? login,
    String? name,
    String? email,
    String? avatarUrl,
    List<String>? orgs,
    List<String>? emails,
    DateTime? lastSeenAt,
  }) => Member(
    id: id,
    login: login ?? this.login,
    name: name ?? this.name,
    email: email ?? this.email,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    orgs: orgs ?? this.orgs,
    emails: emails ?? this.emails,
    provider: provider,
    role: role,
    createdAt: createdAt,
    lastSeenAt: lastSeenAt ?? this.lastSeenAt,
  );

  Json toJson() => {
    'id': id,
    'login': login,
    'name': ?name,
    'email': ?email,
    'avatarUrl': ?avatarUrl,
    'orgs': orgs,
    'emails': emails,
    'provider': provider,
    'role': role,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (lastSeenAt != null) 'lastSeenAt': lastSeenAt!.toUtc().toIso8601String(),
  };

  factory Member.fromJson(Json json) => Member(
    id: json['id'] as String,
    login: json['login'] as String,
    name: json['name'] as String?,
    email: json['email'] as String?,
    avatarUrl: json['avatarUrl'] as String?,
    orgs: [for (final o in (json['orgs'] as List?) ?? const []) '$o'],
    emails: [for (final e in (json['emails'] as List?) ?? const []) '$e'],
    provider: json['provider'] as String? ?? 'github',
    role: json['role'] as String? ?? 'admin',
    createdAt: DateTime.parse(json['createdAt'] as String),
    lastSeenAt: _date(json['lastSeenAt']),
  );
}

/// A signed-in browser. Only the hash of its token is kept.
class DashSession {
  const DashSession({
    required this.hash,
    required this.memberId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String hash;
  final String memberId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Json toJson() => {
    'hash': hash,
    'memberId': memberId,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  factory DashSession.fromJson(Json json) => DashSession(
    hash: json['hash'] as String,
    memberId: json['memberId'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    expiresAt: DateTime.parse(json['expiresAt'] as String),
  );
}

/// A language-model endpoint the dashboard's chat uses. Its key is a secret:
/// stored here, sent upstream by the proxy, never returned (see [toPublicJson]).
class LlmProviderConfig {
  const LlmProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.apiKey,
    this.models = const [],
    this.contextLength,
  });

  static const kinds = ['ollama', 'openaiCompatible'];

  final String id;
  final String name;

  /// `ollama` or `openaiCompatible`.
  final String kind;

  /// Ollama: `http://host:11434`. OpenAI-compatible: `https://host/v1`.
  final String baseUrl;
  final String? apiKey;

  /// Models enabled for the chat picker.
  final List<String> models;
  final int? contextLength;

  LlmProviderConfig copyWith({
    String? name,
    String? kind,
    String? baseUrl,
    String? apiKey,
    bool clearApiKey = false,
    List<String>? models,
    int? contextLength,
    bool clearContextLength = false,
  }) => LlmProviderConfig(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: clearApiKey ? null : apiKey ?? this.apiKey,
    models: models ?? this.models,
    contextLength: clearContextLength
        ? null
        : contextLength ?? this.contextLength,
  );

  Json toJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'baseUrl': baseUrl,
    'apiKey': ?apiKey,
    'models': models,
    'contextLength': ?contextLength,
  };

  Json toPublicJson() => {
    'id': id,
    'name': name,
    'kind': kind,
    'baseUrl': baseUrl,
    'hasKey': (apiKey ?? '').isNotEmpty,
    'models': models,
    'contextLength': contextLength,
  };

  factory LlmProviderConfig.fromJson(Json json) => LlmProviderConfig(
    id: json['id'] as String,
    name: json['name'] as String,
    kind: json['kind'] as String,
    baseUrl: json['baseUrl'] as String,
    apiKey: json['apiKey'] as String?,
    models: [for (final m in (json['models'] as List?) ?? const []) '$m'],
    contextLength: json['contextLength'] as int?,
  );
}

/// A way to sign in to the dashboard (a GitHub or Google OAuth app) and who it
/// lets in. Its secret is stored here and never returned (see [toPublicJson]).
class AuthProviderConfig {
  const AuthProviderConfig({
    required this.id,
    required this.kind,
    required this.name,
    this.clientId = '',
    this.clientSecret,
    this.enabled = true,
    this.orgs = const [],
    this.users = const [],
    this.domains = const [],
    this.emails = const [],
    this.fromEnvironment = false,
  });

  static const kinds = ['github', 'google'];

  /// The address segment: sign-in starts at `/auth/<id>`.
  final String id;

  /// `github` or `google`.
  final String kind;
  final String name;
  final String clientId;
  final String? clientSecret;
  final bool enabled;

  /// GitHub only: members of these organisations may sign in.
  final List<String> orgs;

  /// GitHub only: these logins may sign in.
  final List<String> users;

  /// Anyone whose verified email is at one of these domains may sign in.
  final List<String> domains;

  /// These verified email addresses may sign in.
  final List<String> emails;

  /// Set by the server's environment (read-only here).
  final bool fromEnvironment;

  bool get configured => clientId.isNotEmpty && (clientSecret ?? '').isNotEmpty;

  /// Whether anyone at all can get in through it.
  bool get hasAllowList =>
      orgs.isNotEmpty ||
      users.isNotEmpty ||
      domains.isNotEmpty ||
      emails.isNotEmpty;

  AuthProviderConfig copyWith({
    String? name,
    String? clientId,
    String? clientSecret,
    bool clearClientSecret = false,
    bool? enabled,
    List<String>? orgs,
    List<String>? users,
    List<String>? domains,
    List<String>? emails,
  }) => AuthProviderConfig(
    id: id,
    kind: kind,
    name: name ?? this.name,
    clientId: clientId ?? this.clientId,
    clientSecret: clearClientSecret ? null : clientSecret ?? this.clientSecret,
    enabled: enabled ?? this.enabled,
    orgs: orgs ?? this.orgs,
    users: users ?? this.users,
    domains: domains ?? this.domains,
    emails: emails ?? this.emails,
    fromEnvironment: fromEnvironment,
  );

  Json toJson() => {
    'id': id,
    'kind': kind,
    'name': name,
    'clientId': clientId,
    'clientSecret': ?clientSecret,
    'enabled': enabled,
    'orgs': orgs,
    'users': users,
    'domains': domains,
    'emails': emails,
  };

  /// What the dashboard may see: never the secret.
  Json toPublicJson(String callbackUrl) => {
    'id': id,
    'kind': kind,
    'name': name,
    'clientId': clientId,
    'hasSecret': (clientSecret ?? '').isNotEmpty,
    'enabled': enabled,
    'orgs': orgs,
    'users': users,
    'domains': domains,
    'emails': emails,
    'source': fromEnvironment ? 'environment' : 'database',
    'callbackUrl': callbackUrl,
  };

  factory AuthProviderConfig.fromJson(Json json) {
    List<String> list(String k) => [
      for (final e in (json[k] as List?) ?? const []) '$e',
    ];
    return AuthProviderConfig(
      id: json['id'] as String,
      kind: json['kind'] as String,
      name: json['name'] as String,
      clientId: json['clientId'] as String? ?? '',
      clientSecret: json['clientSecret'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      orgs: list('orgs'),
      users: list('users'),
      domains: list('domains'),
      emails: list('emails'),
    );
  }
}
