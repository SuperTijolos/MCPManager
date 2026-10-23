import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../core/json.dart';
import '../core/redact.dart';
import 'oauth_models.dart';

/// Parameters of a `WWW-Authenticate: Bearer …` challenge (RFC 6750 / 9728).
class BearerChallenge {
  const BearerChallenge({this.resourceMetadata, this.scope});
  final String? resourceMetadata;
  final String? scope;
}

BearerChallenge parseBearerChallenge(String? header) {
  if (header == null) return const BearerChallenge();
  String? param(String name) {
    final match = RegExp(
      '$name\\s*=\\s*(?:"([^"]*)"|([^\\s,]+))',
      caseSensitive: false,
    ).firstMatch(header);
    return match == null ? null : (match.group(1) ?? match.group(2));
  }

  return BearerChallenge(
    resourceMetadata: param('resource_metadata'),
    scope: param('scope'),
  );
}

/// RFC 7636 S256 challenge for [verifier].
String pkceChallenge(String verifier) => base64Url
    .encode(sha256.convert(ascii.encode(verifier)).bytes)
    .replaceAll('=', '');

String randomUrlSafe(int bytes, [Random? random]) {
  final r = random ?? Random.secure();
  return base64Url
      .encode([for (var i = 0; i < bytes; i++) r.nextInt(256)])
      .replaceAll('=', '');
}

class AuthorizationRequest {
  const AuthorizationRequest(this.url, this.verifier, this.state);
  final Uri url;
  final String verifier;
  final String state;
}

/// The protocol steps of the MCP authorization spec (OAuth 2.1 + PKCE,
/// protected-resource and authorization-server metadata, dynamic client
/// registration). Pure HTTP logic: no UI, no storage.
///
/// In a browser every endpoint involved must allow CORS for the app's origin.
class OAuthFlow {
  OAuthFlow(this._http, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final http.Client _http;
  final DateTime Function() _now;

  static const _timeout = Duration(seconds: 15);

  /// Finds the authorization server for [mcpUrl]. [challenge] comes from a 401
  /// response when the browser let us read it.
  Future<OAuthServerMetadata> discover(
    Uri mcpUrl, {
    BearerChallenge challenge = const BearerChallenge(),
  }) async {
    final issuer = await _findIssuer(mcpUrl, challenge);
    final candidates = _authServerMetadataUrls(issuer);
    for (final url in candidates) {
      final doc = await _getJson(url);
      if (doc != null &&
          doc['authorization_endpoint'] is String &&
          doc['token_endpoint'] is String) {
        return OAuthServerMetadata.fromJson({
          ...doc,
          'issuer': doc['issuer'] ?? issuer.toString(),
        });
      }
    }
    // MCP 2025-03-26 fallback for servers without metadata documents.
    final base = issuer.origin;
    return OAuthServerMetadata(
      issuer: base,
      authorizationEndpoint: '$base/authorize',
      tokenEndpoint: '$base/token',
      registrationEndpoint: '$base/register',
    );
  }

  Future<Uri> _findIssuer(Uri mcpUrl, BearerChallenge challenge) async {
    final urls = <Uri>[
      if (challenge.resourceMetadata != null)
        Uri.parse(challenge.resourceMetadata!),
      Uri.parse(
        '${mcpUrl.origin}/.well-known/oauth-protected-resource'
        '${mcpUrl.path == '/' ? '' : mcpUrl.path}',
      ),
      Uri.parse('${mcpUrl.origin}/.well-known/oauth-protected-resource'),
    ];
    for (final url in urls) {
      final doc = await _getJson(url);
      final servers = doc?['authorization_servers'];
      if (servers is List && servers.isNotEmpty && servers.first is String) {
        return Uri.parse(servers.first as String);
      }
    }
    return Uri.parse(mcpUrl.origin);
  }

  List<Uri> _authServerMetadataUrls(Uri issuer) {
    final path = issuer.path == '/' ? '' : issuer.path;
    final origin = issuer.origin;
    return [
      Uri.parse('$origin/.well-known/oauth-authorization-server$path'),
      Uri.parse('$origin/.well-known/openid-configuration$path'),
      if (path.isNotEmpty)
        Uri.parse('$origin$path/.well-known/openid-configuration'),
    ];
  }

  Future<OAuthClientRegistration> register(
    OAuthServerMetadata metadata, {
    required String redirectUri,
    String clientName = 'MCP Manager',
  }) async {
    final endpoint = metadata.registrationEndpoint;
    if (endpoint == null) {
      throw OAuthException(
        'This server does not support dynamic client registration. '
        'Register the redirect URI manually and enter a Client ID.',
      );
    }
    final response = await _send(
      () => _http.post(
        Uri.parse(endpoint),
        headers: {
          'content-type': 'application/json',
          'accept': 'application/json',
        },
        body: jsonEncode({
          'client_name': clientName,
          'redirect_uris': [redirectUri],
          'grant_types': ['authorization_code', 'refresh_token'],
          'response_types': ['code'],
          'token_endpoint_auth_method': 'none',
        }),
      ),
      'client registration',
    );
    final doc = tryDecodeObject(response.body);
    if (response.statusCode >= 300 || doc?['client_id'] is! String) {
      throw OAuthException(
        'Client registration was rejected (HTTP ${response.statusCode}): '
        '${truncate(redactText(response.body), 300)}',
      );
    }
    return OAuthClientRegistration(
      clientId: doc!['client_id'] as String,
      clientSecret: doc['client_secret'] as String?,
      redirectUri: redirectUri,
    );
  }

  AuthorizationRequest authorizationRequest({
    required OAuthServerMetadata metadata,
    required OAuthClientRegistration registration,
    required String resource,
    String? scope,
    Random? random,
  }) {
    final verifier = randomUrlSafe(48, random);
    final state = randomUrlSafe(24, random);
    final base = Uri.parse(metadata.authorizationEndpoint);
    final url = base.replace(
      queryParameters: {
        ...base.queryParameters,
        'response_type': 'code',
        'client_id': registration.clientId,
        'redirect_uri': registration.redirectUri,
        'code_challenge': pkceChallenge(verifier),
        'code_challenge_method': 'S256',
        'state': state,
        'resource': resource,
        if (scope != null && scope.isNotEmpty) 'scope': scope,
      },
    );
    return AuthorizationRequest(url, verifier, state);
  }

  Future<OAuthTokens> exchangeCode({
    required OAuthServerMetadata metadata,
    required OAuthClientRegistration registration,
    required String code,
    required String verifier,
    required String resource,
  }) => _token(metadata, registration, {
    'grant_type': 'authorization_code',
    'code': code,
    'redirect_uri': registration.redirectUri,
    'code_verifier': verifier,
    'resource': resource,
  });

  Future<OAuthTokens> refresh({
    required OAuthServerMetadata metadata,
    required OAuthClientRegistration registration,
    required String refreshToken,
    required String resource,
  }) => _token(metadata, registration, {
    'grant_type': 'refresh_token',
    'refresh_token': refreshToken,
    'resource': resource,
  }, keepRefreshToken: refreshToken);

  Future<OAuthTokens> _token(
    OAuthServerMetadata metadata,
    OAuthClientRegistration registration,
    Map<String, String> form, {
    String? keepRefreshToken,
  }) async {
    final response = await _send(
      () => _http.post(
        Uri.parse(metadata.tokenEndpoint),
        headers: {
          'content-type': 'application/x-www-form-urlencoded',
          'accept': 'application/json',
        },
        body: {
          ...form,
          'client_id': registration.clientId,
          'client_secret': ?registration.clientSecret,
        },
      ),
      'token request',
    );
    final doc = tryDecodeObject(response.body);
    if (response.statusCode >= 300 || doc?['access_token'] is! String) {
      final reason =
          doc?['error_description'] ??
          doc?['error'] ??
          truncate(response.body, 200);
      throw OAuthException(
        'Token request failed (HTTP ${response.statusCode}): ${redactText('$reason')}',
      );
    }
    final expiresIn = doc!['expires_in'];
    return OAuthTokens(
      accessToken: doc['access_token'] as String,
      refreshToken: doc['refresh_token'] as String? ?? keepRefreshToken,
      expiresAt: expiresIn is num
          ? _now().add(Duration(seconds: expiresIn.toInt()))
          : null,
      scope: doc['scope'] as String?,
    );
  }

  /// GET that treats any failure (network, CORS, non-200, bad JSON) as "not
  /// here", so discovery can try the next candidate.
  Future<Json?> _getJson(Uri url) async {
    try {
      final response = await _http
          .get(url, headers: {'accept': 'application/json'})
          .timeout(_timeout);
      if (response.statusCode != 200) return null;
      return tryDecodeObject(response.body);
    } catch (_) {
      return null;
    }
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request,
    String what,
  ) async {
    try {
      return await request().timeout(_timeout);
    } on TimeoutException {
      throw OAuthException('The $what timed out.');
    } on http.ClientException catch (e) {
      throw OAuthException(
        'Could not complete the $what (${e.message}). The authorization '
        'server must allow CORS requests from this app\'s origin.',
      );
    }
  }
}
