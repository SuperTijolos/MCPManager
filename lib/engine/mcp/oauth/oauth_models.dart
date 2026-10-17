import '../../core/json.dart';

/// Endpoints of the authorization server that protects an MCP server.
class OAuthServerMetadata {
  const OAuthServerMetadata({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.registrationEndpoint,
    this.scopesSupported = const [],
  });

  final String issuer;
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? registrationEndpoint;
  final List<String> scopesSupported;

  Json toJson() => {
    'issuer': issuer,
    'authorization_endpoint': authorizationEndpoint,
    'token_endpoint': tokenEndpoint,
    'registration_endpoint': ?registrationEndpoint,
    'scopes_supported': scopesSupported,
  };

  factory OAuthServerMetadata.fromJson(Json json) => OAuthServerMetadata(
    issuer: json['issuer'] as String? ?? '',
    authorizationEndpoint: json['authorization_endpoint'] as String,
    tokenEndpoint: json['token_endpoint'] as String,
    registrationEndpoint: json['registration_endpoint'] as String?,
    scopesSupported: ((json['scopes_supported'] as List?) ?? const [])
        .cast<String>(),
  );
}

class OAuthClientRegistration {
  const OAuthClientRegistration({
    required this.clientId,
    required this.redirectUri,
    this.clientSecret,
  });

  final String clientId;
  final String? clientSecret;

  /// The redirect URI this client was registered with. A registration is only
  /// reusable while the app is served from the same URI.
  final String redirectUri;

  Json toJson() => {
    'clientId': clientId,
    'clientSecret': ?clientSecret,
    'redirectUri': redirectUri,
  };

  factory OAuthClientRegistration.fromJson(Json json) =>
      OAuthClientRegistration(
        clientId: json['clientId'] as String,
        clientSecret: json['clientSecret'] as String?,
        redirectUri: json['redirectUri'] as String,
      );
}

class OAuthTokens {
  const OAuthTokens({
    required this.accessToken,
    this.refreshToken,
    this.expiresAt,
    this.scope,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime? expiresAt;
  final String? scope;

  bool isExpired(DateTime now, {Duration skew = const Duration(seconds: 30)}) =>
      expiresAt != null && now.isAfter(expiresAt!.subtract(skew));

  Json toJson() => {
    'accessToken': accessToken,
    'refreshToken': ?refreshToken,
    'expiresAt': expiresAt?.toIso8601String(),
    'scope': ?scope,
  };

  factory OAuthTokens.fromJson(Json json) => OAuthTokens(
    accessToken: json['accessToken'] as String,
    refreshToken: json['refreshToken'] as String?,
    expiresAt: json['expiresAt'] == null
        ? null
        : DateTime.parse(json['expiresAt'] as String),
    scope: json['scope'] as String?,
  );
}

/// Everything stored for one OAuth-protected MCP server.
class OAuthSession {
  const OAuthSession({
    required this.resource,
    required this.metadata,
    required this.registration,
    this.tokens,
  });

  /// Canonical MCP server URL, sent as the RFC 8707 `resource` parameter.
  final String resource;
  final OAuthServerMetadata metadata;
  final OAuthClientRegistration registration;
  final OAuthTokens? tokens;

  OAuthSession withTokens(OAuthTokens? next) => OAuthSession(
    resource: resource,
    metadata: metadata,
    registration: registration,
    tokens: next,
  );

  Json toJson() => {
    'resource': resource,
    'metadata': metadata.toJson(),
    'registration': registration.toJson(),
    'tokens': tokens?.toJson(),
  };

  factory OAuthSession.fromJson(Json json) => OAuthSession(
    resource: json['resource'] as String,
    metadata: OAuthServerMetadata.fromJson(
      (json['metadata'] as Map).cast<String, dynamic>(),
    ),
    registration: OAuthClientRegistration.fromJson(
      (json['registration'] as Map).cast<String, dynamic>(),
    ),
    tokens: json['tokens'] == null
        ? null
        : OAuthTokens.fromJson((json['tokens'] as Map).cast<String, dynamic>()),
  );
}

class OAuthException implements Exception {
  OAuthException(this.message);
  final String message;

  @override
  String toString() => message;
}
