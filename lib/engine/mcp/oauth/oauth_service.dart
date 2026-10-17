import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/prefs.dart';
import '../mcp_hub.dart';
import '../mcp_models.dart';
import 'oauth_flow.dart';
import 'oauth_models.dart';
import 'oauth_popup.dart';

const _storageKey = 'mcpm.oauth.v1';
const _authorizeTimeout = Duration(minutes: 5);

/// Path of the static page (`web/oauth_callback.html`) that receives the
/// authorization response and hands it back to the app.
const oauthCallbackFile = 'oauth_callback.html';

/// The redirect URI to register with an authorization server, derived from
/// where the app is currently served. Overridden in tests.
final oauthRedirectUriProvider = Provider<Uri>((ref) {
  final base = currentAppUri();
  final path = base.path;
  final dir = path.substring(0, path.lastIndexOf('/') + 1);
  return Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: '$dir$oauthCallbackFile',
  );
});

/// Opens the sign-in window. Must be called directly from a click handler.
final oauthPopupOpenerProvider = Provider<OAuthPopup Function()>(
  (ref) => openOAuthPopup,
);

final oauthSessionsProvider =
    NotifierProvider<OAuthSessions, Map<String, OAuthSession>>(
      OAuthSessions.new,
    );

/// Per-server OAuth state (registered client, endpoints, tokens). Contains
/// credentials, so it is only ever read by [OAuthService].
class OAuthSessions extends Notifier<Map<String, OAuthSession>> {
  @override
  Map<String, OAuthSession> build() {
    final raw = readJson(ref.read(sharedPreferencesProvider), _storageKey);
    final sessions = <String, OAuthSession>{};
    if (raw is Map) {
      for (final e in raw.entries) {
        try {
          sessions['${e.key}'] = OAuthSession.fromJson(
            (e.value as Map).cast<String, dynamic>(),
          );
        } catch (_) {
          // Ignore entries written by an incompatible version.
        }
      }
    }
    return sessions;
  }

  void put(String serverId, OAuthSession session) {
    state = {...state, serverId: session};
    _persist();
  }

  void remove(String serverId) {
    if (!state.containsKey(serverId)) return;
    state = {...state}..remove(serverId);
    _persist();
  }

  void _persist() => writeJson(
    ref.read(sharedPreferencesProvider),
    _storageKey,
    {for (final e in state.entries) e.key: e.value.toJson()},
  );
}

final oauthServiceProvider = Provider<OAuthService>(OAuthService.new);

class OAuthService {
  OAuthService(this._ref);

  final Ref _ref;
  final _refreshing = <String, Future<String?>>{};

  OAuthSession? sessionFor(String serverId) =>
      _ref.read(oauthSessionsProvider)[serverId];

  bool isSignedIn(String serverId) => sessionFor(serverId)?.tokens != null;

  /// A usable access token for [serverId], refreshing it when it has expired
  /// (or when [forceRefresh] is set because the server rejected it). Null means
  /// the user has to sign in again.
  Future<String?> accessToken(String serverId, {bool forceRefresh = false}) {
    final session = sessionFor(serverId);
    final tokens = session?.tokens;
    if (session == null || tokens == null) return Future.value(null);
    if (!forceRefresh && !tokens.isExpired(DateTime.now())) {
      return Future.value(tokens.accessToken);
    }
    // Coalesce concurrent refreshes: refresh tokens are often single-use.
    return _refreshing[serverId] ??= _refresh(serverId, session, tokens)
        .whenComplete(() {
          // A block body on purpose: returning remove()'s result would hand
          // whenComplete its own future to wait on, and deadlock.
          _refreshing.remove(serverId);
        });
  }

  Future<String?> _refresh(
    String serverId,
    OAuthSession session,
    OAuthTokens tokens,
  ) async {
    final refreshToken = tokens.refreshToken;
    if (refreshToken == null) return null;
    final client = _httpClient();
    try {
      final fresh = await OAuthFlow(client).refresh(
        metadata: session.metadata,
        registration: session.registration,
        refreshToken: refreshToken,
        resource: session.resource,
      );
      if (_ref.mounted) {
        _ref
            .read(oauthSessionsProvider.notifier)
            .put(serverId, session.withTokens(fresh));
      }
      return fresh.accessToken;
    } on OAuthException {
      // Refresh token revoked or expired: require a new interactive sign-in.
      if (_ref.mounted) {
        _ref
            .read(oauthSessionsProvider.notifier)
            .put(serverId, session.withTokens(null));
      }
      return null;
    } finally {
      client.close();
    }
  }

  /// Runs the interactive authorization-code + PKCE flow in [popup].
  Future<void> authorize({
    required McpServerConfig config,
    required OAuthPopup popup,
    BearerChallenge challenge = const BearerChallenge(),
  }) async {
    final client = _httpClient();
    try {
      final flow = OAuthFlow(client);
      final redirectUri = _ref.read(oauthRedirectUriProvider).toString();
      final resource = Uri.parse(config.url).removeFragment().toString();

      final metadata = await flow.discover(
        Uri.parse(config.url),
        challenge: challenge,
      );
      final registration = await _registration(
        flow,
        config,
        metadata,
        redirectUri,
      );
      final request = flow.authorizationRequest(
        metadata: metadata,
        registration: registration,
        resource: resource,
        scope: (config.oauthScope ?? '').trim().isNotEmpty
            ? config.oauthScope
            : challenge.scope,
      );

      popup.navigate(request.url);
      final params = await popup.result.timeout(
        _authorizeTimeout,
        onTimeout: () => throw OAuthException('Sign-in timed out.'),
      );

      if (params['error'] != null) {
        throw OAuthException(
          'The server denied authorization: '
          '${params['error_description'] ?? params['error']}',
        );
      }
      if (params['state'] != request.state) {
        throw OAuthException(
          'Sign-in response did not match this request (state mismatch).',
        );
      }
      final code = params['code'];
      if (code == null || code.isEmpty) {
        throw OAuthException(
          'The server did not return an authorization code.',
        );
      }

      final tokens = await flow.exchangeCode(
        metadata: metadata,
        registration: registration,
        code: code,
        verifier: request.verifier,
        resource: resource,
      );
      _ref
          .read(oauthSessionsProvider.notifier)
          .put(
            config.id,
            OAuthSession(
              resource: resource,
              metadata: metadata,
              registration: registration,
              tokens: tokens,
            ),
          );
    } finally {
      popup.close();
      client.close();
    }
  }

  Future<OAuthClientRegistration> _registration(
    OAuthFlow flow,
    McpServerConfig config,
    OAuthServerMetadata metadata,
    String redirectUri,
  ) async {
    final preset = (config.oauthClientId ?? '').trim();
    if (preset.isNotEmpty) {
      return OAuthClientRegistration(
        clientId: preset,
        redirectUri: redirectUri,
      );
    }
    final existing = sessionFor(config.id)?.registration;
    final sameServer =
        sessionFor(config.id)?.metadata.issuer == metadata.issuer;
    if (existing != null && sameServer && existing.redirectUri == redirectUri) {
      return existing;
    }
    return flow.register(metadata, redirectUri: redirectUri);
  }

  void signOut(String serverId) {
    final session = sessionFor(serverId);
    if (session == null) return;
    // Keep the registered client so signing in again needs no new registration.
    _ref
        .read(oauthSessionsProvider.notifier)
        .put(serverId, session.withTokens(null));
  }

  void forget(String serverId) =>
      _ref.read(oauthSessionsProvider.notifier).remove(serverId);

  http.Client _httpClient() => _ref.read(mcpHttpClientFactoryProvider)();
}
