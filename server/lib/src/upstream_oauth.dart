import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:mcp_core/mcp_core.dart';
import 'package:shelf/shelf.dart';

import 'audit.dart';
import 'events.dart';
import 'models.dart';
import 'pages.dart';
import 'state.dart';

const _pendingTtl = Duration(minutes: 10);
const _maxPending = 100;

class _Pending {
  _Pending({
    required this.serverId,
    required this.verifier,
    required this.metadata,
    required this.registration,
    required this.resource,
    required this.expiresAt,
    this.returnTo,
  });
  final String serverId;
  final String verifier;
  final OAuthServerMetadata metadata;
  final OAuthClientRegistration registration;
  final String resource;
  final DateTime expiresAt;
  final String? returnTo;
}

/// The gateway signs in to upstream servers that use OAuth, so the dashboard
/// and every portal client use them without ever seeing a token.
///
/// A member starts the sign-in from the dashboard ([begin]); the upstream's
/// sign-in page sends the browser back to `/oauth/upstream/callback`, where
/// the code is exchanged. Tokens live in the database and are refreshed when
/// a call needs them.
class UpstreamOAuth {
  UpstreamOAuth({
    required this.store,
    required this.bus,
    required this.audit,
    required this.onSessionChanged,
    http.Client Function()? httpClient,
    DateTime Function()? clock,
  }) : _http = httpClient ?? http.Client.new,
       _now = clock ?? DateTime.now;

  final StateStore store;
  final EventBus bus;
  final GatewayAuditLog audit;

  /// Called when tokens appear or disappear, so a held connection is replaced.
  final Future<void> Function(String serverId) onSessionChanged;
  final http.Client Function() _http;
  final DateTime Function() _now;

  final _pending = <String, _Pending>{};
  final _refreshing = <String, Future<String?>>{};

  OAuthSession? session(String serverId) => store.state.upstreamOAuth[serverId];

  /// What the dashboard may know: never a token.
  Json status(String serverId) {
    final s = session(serverId);
    final t = s?.tokens;
    return {
      'signedIn': t != null,
      if (t?.expiresAt != null)
        'expiresAt': t!.expiresAt!.toUtc().toIso8601String(),
      if (t?.scope != null) 'scope': t!.scope,
      'canRefresh': t?.refreshToken != null,
      if (s != null) 'issuer': s.metadata.issuer,
    };
  }

  /// A usable access token for [serverId], refreshed when it has expired (or
  /// when [forceRefresh] is set because the server refused it). Null means
  /// someone has to sign in again.
  Future<String?> accessToken(String serverId, {bool forceRefresh = false}) {
    final s = session(serverId);
    final tokens = s?.tokens;
    if (s == null || tokens == null) return Future.value(null);
    if (!forceRefresh && !tokens.isExpired(_now())) {
      return Future.value(tokens.accessToken);
    }
    // Refresh tokens are often single-use: one refresh at a time.
    return _refreshing[serverId] ??= _refresh(serverId, s, tokens).whenComplete(
      () {
        // A block body on purpose: returning remove()'s result would make
        // whenComplete wait on its own future.
        _refreshing.remove(serverId);
      },
    );
  }

  Future<String?> _refresh(
    String serverId,
    OAuthSession s,
    OAuthTokens tokens,
  ) async {
    final refreshToken = tokens.refreshToken;
    if (refreshToken == null) return null;
    final client = _http();
    try {
      final fresh = await OAuthFlow(client, clock: _now).refresh(
        metadata: s.metadata,
        registration: s.registration,
        refreshToken: refreshToken,
        resource: s.resource,
      );
      await _put(serverId, s.withTokens(fresh));
      return fresh.accessToken;
    } on OAuthException {
      // Revoked or expired for good: a new sign-in is needed.
      await _put(serverId, s.withTokens(null));
      bus.emit('oauth', {'serverId': serverId, 'signedIn': false});
      return null;
    } finally {
      client.close();
    }
  }

  /// Prepares a sign-in to [server] and returns the address to open in a
  /// browser. [redirectUri] is this gateway's callback address.
  Future<Uri> begin(
    UpstreamServer server, {
    required String redirectUri,
    String? returnTo,
  }) async {
    if (!server.oauth) {
      throw OAuthException('This server is not set to sign in with OAuth.');
    }
    final client = _http();
    try {
      final challenge = await _probe(server, client);
      final flow = OAuthFlow(client, clock: _now);
      final resource = Uri.parse(server.url).removeFragment().toString();
      final metadata = await flow.discover(
        Uri.parse(server.url),
        challenge: challenge,
      );

      final preset = (server.oauthClientId ?? '').trim();
      final existing = session(server.id);
      final OAuthClientRegistration registration;
      if (preset.isNotEmpty) {
        registration = OAuthClientRegistration(
          clientId: preset,
          redirectUri: redirectUri,
        );
      } else if (existing != null &&
          existing.metadata.issuer == metadata.issuer &&
          existing.registration.redirectUri == redirectUri) {
        registration = existing.registration;
      } else {
        registration = await flow.register(
          metadata,
          redirectUri: redirectUri,
          clientName: 'MCP Manager',
        );
        // Kept right away, so a sign-in that is abandoned and started again
        // does not register another client at the server.
        await _put(
          server.id,
          OAuthSession(
            resource: resource,
            metadata: metadata,
            registration: registration,
          ),
        );
      }

      final scope = (server.oauthScope ?? '').trim().isNotEmpty
          ? server.oauthScope
          : challenge.scope;
      final request = flow.authorizationRequest(
        metadata: metadata,
        registration: registration,
        resource: resource,
        scope: scope,
      );

      final now = _now();
      _pending.removeWhere((_, p) => !p.expiresAt.isAfter(now));
      if (_pending.length >= _maxPending) {
        throw OAuthException('Too many sign-ins at once. Try again shortly.');
      }
      _pending[request.state] = _Pending(
        serverId: server.id,
        verifier: request.verifier,
        metadata: metadata,
        registration: registration,
        resource: resource,
        returnTo: returnTo,
        expiresAt: now.add(_pendingTtl),
      );
      return request.url;
    } finally {
      client.close();
    }
  }

  /// Connects without credentials to read the server's `WWW-Authenticate`.
  Future<BearerChallenge> _probe(
    UpstreamServer server,
    http.Client client,
  ) async {
    final connection = createMcpConnection(
      server.toConfig().copyWith(oauth: false),
      httpClient: client,
    );
    try {
      await connection.connect();
    } on McpAuthRequired catch (e) {
      return parseBearerChallenge(e.wwwAuthenticate);
    } on McpException catch (e) {
      throw OAuthException('Could not reach the server: ${e.message}');
    } finally {
      connection.close();
    }
    throw OAuthException(
      'This server did not ask for a sign-in. Turn OAuth off for it.',
    );
  }

  Future<void> signOut(String serverId, {bool forget = false}) async {
    final s = session(serverId);
    if (s == null) return;
    await store.update((st) {
      if (forget) {
        st.upstreamOAuth.remove(serverId);
      } else {
        // Keep the registered client so the next sign-in needs no registration.
        st.upstreamOAuth[serverId] = s.withTokens(null);
      }
    });
    await onSessionChanged(serverId);
    bus.emit('oauth', {'serverId': serverId, 'signedIn': false});
    final server = store.state.server(serverId);
    if (server != null) await _record(server, 'success', result: 'Signed out');
  }

  Future<void> _put(String serverId, OAuthSession s) => store.update((st) {
    // A server deleted meanwhile must not get its row back.
    if (st.server(serverId) != null) st.upstreamOAuth[serverId] = s;
  });

  // ------------------------------------------------------------- callback

  /// Null when [request] is not the callback.
  Future<Response?> handle(Request request) async {
    if (request.url.path != 'oauth/upstream/callback' ||
        request.method != 'GET') {
      return null;
    }
    final q = request.url.queryParameters;
    final pending = q['state'] == null ? null : _pending.remove(q['state']);
    if (pending == null || !pending.expiresAt.isAfter(_now())) {
      return _page(
        400,
        'Cannot sign in',
        'This sign-in did not start here, or it took too long. Start again '
            'from the dashboard.',
      );
    }
    final server = store.state.server(pending.serverId);
    if (server == null) {
      return _page(404, 'Cannot sign in', 'That server no longer exists.');
    }
    if (q['error'] != null) {
      await _record(
        server,
        'error',
        error: '${q['error_description'] ?? q['error']}',
      );
      return _page(
        403,
        'Sign-in refused',
        'The server did not allow it: ${q['error_description'] ?? q['error']}',
      );
    }
    final code = q['code'];
    if (code == null || code.isEmpty) {
      return _page(400, 'Cannot sign in', 'The server sent no code.');
    }

    final client = _http();
    try {
      final tokens = await OAuthFlow(client, clock: _now).exchangeCode(
        metadata: pending.metadata,
        registration: pending.registration,
        code: code,
        verifier: pending.verifier,
        resource: pending.resource,
      );
      await _put(
        pending.serverId,
        OAuthSession(
          resource: pending.resource,
          metadata: pending.metadata,
          registration: pending.registration,
          tokens: tokens,
        ),
      );
    } on OAuthException catch (e) {
      await _record(server, 'error', error: e.message);
      return _page(502, 'Cannot sign in', e.message);
    } finally {
      client.close();
    }
    await _record(server, 'success', result: 'OAuth sign-in completed');
    await onSessionChanged(pending.serverId);
    bus.emit('oauth', {'serverId': pending.serverId, 'signedIn': true});

    final back = pending.returnTo;
    if (back != null) return Response.found(back);
    return _page(
      200,
      'Connected',
      '${server.name} is connected. You can close this window.',
    );
  }

  Future<void> _record(
    UpstreamServer server,
    String status, {
    String? result,
    String? error,
  }) => audit.record(
    GatewayAuditEvent.system(
      id: newId('evt'),
      timestamp: _now(),
      kind: 'authorize',
      status: status,
      serverId: server.id,
      serverName: server.name,
      result: result,
      error: error == null ? null : redactText(error),
    ),
  );

  Response _page(int status, String title, String message) =>
      htmlResponse(status, htmlPage(title, '<p>${escapeHtml(message)}</p>'));
}
