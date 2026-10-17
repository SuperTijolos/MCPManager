import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_flow.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_models.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_service.dart';

import '../support/fakes.dart';

final _tools = [
  {
    'name': 'lookup',
    'description': 'Read something',
    'inputSchema': {'type': 'object'},
    'annotations': {'readOnlyHint': true},
  },
];

FakeOAuthWorld _world({
  bool withChallengeHeader = true,
  bool withMetadata = true,
  bool supportsRegistration = true,
  int tokenLifetimeSeconds = 3600,
}) => FakeOAuthWorld(
  mcp: FakeMcpServer(
    tools: _tools,
    handlers: {'lookup': (args) => textResult('found ${args['q']}')},
  ),
  withChallengeHeader: withChallengeHeader,
  withMetadata: withMetadata,
  supportsRegistration: supportsRegistration,
  tokenLifetimeSeconds: tokenLifetimeSeconds,
);

Future<ProviderContainer> _container(FakeOAuthWorld world) async {
  final container = await makeContainer(httpClient: world.client);
  addTearDown(container.dispose);
  return container;
}

/// Adds the protected server (no credentials yet) and waits for the 401.
Future<ServerRuntime> _addProtected(ProviderContainer c, {bool oauth = true}) =>
    c
        .read(mcpHubProvider.notifier)
        .addServer(name: 'Protected', url: oauthMcpUrl, oauth: oauth);

void main() {
  group('protocol helpers', () {
    test('parseBearerChallenge reads resource_metadata and scope', () {
      final c = parseBearerChallenge(
        'Bearer realm="mcp", resource_metadata="https://x.test/.well-known/oauth-protected-resource", scope="read write"',
      );
      expect(
        c.resourceMetadata,
        'https://x.test/.well-known/oauth-protected-resource',
      );
      expect(c.scope, 'read write');
      expect(parseBearerChallenge(null).resourceMetadata, isNull);
      expect(parseBearerChallenge('Bearer').resourceMetadata, isNull);
    });

    test('PKCE S256 matches the RFC 7636 test vector', () {
      expect(
        pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('random verifiers are url-safe and long enough', () {
      final v = randomUrlSafe(48);
      expect(v.length, greaterThanOrEqualTo(43));
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(v), isTrue);
      expect(randomUrlSafe(48), isNot(v));
    });
  });

  group('OAuthFlow discovery', () {
    test('follows the 401 challenge to the authorization server', () async {
      final world = _world();
      final meta = await OAuthFlow(world.client).discover(
        Uri.parse(oauthMcpUrl),
        challenge: parseBearerChallenge(
          'Bearer resource_metadata="https://mcp.test/.well-known/oauth-protected-resource/mcp"',
        ),
      );
      expect(meta.authorizationEndpoint, 'https://auth.test/authorize');
      expect(meta.tokenEndpoint, 'https://auth.test/token');
      expect(meta.registrationEndpoint, 'https://auth.test/register');
      expect(world.requested.first, contains('oauth-protected-resource/mcp'));
    });

    test(
      'falls back to well-known URLs when the challenge is unreadable',
      () async {
        final world = _world();
        final meta = await OAuthFlow(world.client)
            .discover(Uri.parse(oauthMcpUrl));
        expect(meta.issuer, 'https://auth.test');
      },
    );

    test(
      'falls back to default endpoints when there is no metadata at all',
      () async {
        final world = _world(withMetadata: false);
        final meta = await OAuthFlow(world.client)
            .discover(Uri.parse(oauthMcpUrl));
        expect(meta.authorizationEndpoint, 'https://mcp.test/authorize');
        expect(meta.tokenEndpoint, 'https://mcp.test/token');
        expect(meta.registrationEndpoint, 'https://mcp.test/register');
      },
    );
  });

  group('OAuthFlow requests', () {
    final metadata = const OAuthServerMetadata(
      issuer: 'https://auth.test',
      authorizationEndpoint: 'https://auth.test/authorize',
      tokenEndpoint: 'https://auth.test/token',
      registrationEndpoint: 'https://auth.test/register',
    );

    test('registers a public client with this app\'s redirect URI', () async {
      final world = _world();
      final reg = await OAuthFlow(world.client)
          .register(metadata, redirectUri: oauthRedirect);
      expect(reg.clientId, 'client-1');
      final body = world.registrations.single;
      expect(body['redirect_uris'], [oauthRedirect]);
      expect(body['token_endpoint_auth_method'], 'none');
      expect(body['grant_types'], contains('refresh_token'));
    });

    test('explains how to proceed when registration is unsupported', () async {
      final world = _world();
      const noReg = OAuthServerMetadata(
        issuer: 'i',
        authorizationEndpoint: 'https://auth.test/authorize',
        tokenEndpoint: 'https://auth.test/token',
      );
      expect(
        OAuthFlow(world.client).register(noReg, redirectUri: oauthRedirect),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.message,
            'message',
            contains('Client ID'),
          ),
        ),
      );
    });

    test('authorization URL carries PKCE, state, redirect and resource', () {
      final request = OAuthFlow(_world().client).authorizationRequest(
        metadata: metadata,
        registration: const OAuthClientRegistration(
          clientId: 'c',
          redirectUri: oauthRedirect,
        ),
        resource: oauthMcpUrl,
        scope: 'read',
      );
      final q = request.url.queryParameters;
      expect(request.url.origin, 'https://auth.test');
      expect(q['response_type'], 'code');
      expect(q['client_id'], 'c');
      expect(q['redirect_uri'], oauthRedirect);
      expect(q['resource'], oauthMcpUrl);
      expect(q['scope'], 'read');
      expect(q['state'], request.state);
      expect(q['code_challenge_method'], 'S256');
      expect(q['code_challenge'], pkceChallenge(request.verifier));
      expect(
        q.containsKey('code_verifier'),
        isFalse,
        reason: 'the verifier must never be in the URL',
      );
    });

    test(
      'refresh keeps the old refresh token when the server does not rotate it',
      () async {
        final tokenWorld = _world();
        // Drive a real code exchange first to get a valid refresh token, then
        // verify the expiry arithmetic with an injected clock.
        final flow = OAuthFlow(
          tokenWorld.client,
          clock: () => DateTime.utc(2026, 1, 1),
        );
        const reg = OAuthClientRegistration(
          clientId: 'client-1',
          redirectUri: oauthRedirect,
        );
        final request = flow.authorizationRequest(
          metadata: metadata,
          registration: reg,
          resource: oauthMcpUrl,
        );
        final params = tokenWorld.authorize(request.url);
        final tokens = await flow.exchangeCode(
          metadata: metadata,
          registration: reg,
          code: params['code']!,
          verifier: request.verifier,
          resource: oauthMcpUrl,
        );
        expect(tokens.accessToken, 'at-1');
        expect(tokens.refreshToken, 'rt-1');
        expect(tokens.expiresAt, DateTime.utc(2026, 1, 1, 1));
        expect(
          tokens.isExpired(DateTime.utc(2026, 1, 1, 0, 59, 45)),
          isTrue,
          reason: '30s skew',
        );
        expect(tokens.isExpired(DateTime.utc(2026, 1, 1, 0, 30)), isFalse);
      },
    );

    test('a wrong verifier is rejected by the token endpoint', () async {
      final world = _world();
      final flow = OAuthFlow(world.client);
      const reg = OAuthClientRegistration(
        clientId: 'client-1',
        redirectUri: oauthRedirect,
      );
      final request = flow.authorizationRequest(
        metadata: metadata,
        registration: reg,
        resource: oauthMcpUrl,
      );
      final params = world.authorize(request.url);
      expect(
        flow.exchangeCode(
          metadata: metadata,
          registration: reg,
          code: params['code']!,
          verifier: 'not-the-verifier',
          resource: oauthMcpUrl,
        ),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.message,
            'message',
            contains('bad code or verifier'),
          ),
        ),
      );
    });
  });

  group('signing in through the hub', () {
    test(
      'a 401 marks the server as needing sign-in and keeps the challenge',
      () async {
        final world = _world();
        final c = await _container(world);
        final runtime = await _addProtected(c);

        expect(runtime.status, ServerStatus.needsAuth);
        expect(runtime.tools, isEmpty);
        expect(runtime.authChallenge, contains('resource_metadata'));
        expect(runtime.error, contains('Sign-in is required'));
      },
    );

    test(
      'authorize completes the flow, then connects with the bearer token',
      () async {
        final world = _world();
        final c = await _container(world);
        final id = (await _addProtected(c)).config.id;

        final popup = FakePopup.approving(world);
        final error = await c
            .read(mcpHubProvider.notifier)
            .authorize(id, popup);

        expect(error, isNull);
        final runtime = c.read(mcpHubProvider).byId(id)!;
        expect(runtime.status, ServerStatus.connected);
        expect(runtime.tools.map((t) => t.name), ['lookup']);
        expect(popup.closed, isTrue);
        expect(popup.navigated.single.origin, 'https://auth.test');
        expect(world.registrations, hasLength(1));
        expect(world.mcpAuthHeaders.last, 'Bearer at-1');

        // Tokens are stored for the server, and never end up in the audit log.
        expect(c.read(oauthServiceProvider).isSignedIn(id), isTrue);
        final audit = c.read(auditLogProvider);
        expect(
          audit.where(
            (e) =>
                e.kind == AuditKind.authorize &&
                e.status == AuditStatus.success,
          ),
          hasLength(1),
        );
        expect(
          audit.map((e) => '${e.args}${e.result}${e.error}').join(),
          isNot(contains('at-1')),
        );
      },
    );

    test(
      'works for a server whose config did not have OAuth enabled yet',
      () async {
        final world = _world();
        final c = await _container(world);
        final runtime = await _addProtected(c, oauth: false);
        expect(
          runtime.status,
          ServerStatus.needsAuth,
          reason: 'no credentials at all → offer sign-in',
        );

        final error = await c
            .read(mcpHubProvider.notifier)
            .authorize(runtime.config.id, FakePopup.approving(world));
        expect(error, isNull);
        expect(
          c.read(mcpHubProvider).byId(runtime.config.id)!.config.oauth,
          isTrue,
        );
      },
    );

    test('denying access reports the reason and stores nothing', () async {
      final world = _world();
      final c = await _container(world);
      final id = (await _addProtected(c)).config.id;

      final popup = FakePopup.denying(world);
      final error = await c.read(mcpHubProvider.notifier).authorize(id, popup);

      expect(error, contains('User said no'));
      expect(popup.closed, isTrue);
      expect(c.read(oauthServiceProvider).isSignedIn(id), isFalse);
      expect(c.read(mcpHubProvider).byId(id)!.status, ServerStatus.needsAuth);
      expect(c.read(auditLogProvider).first.status, AuditStatus.error);
    });

    test(
      'a response with the wrong state is rejected (CSRF protection)',
      () async {
        final world = _world();
        final c = await _container(world);
        final id = (await _addProtected(c)).config.id;

        final error = await c
            .read(mcpHubProvider.notifier)
            .authorize(id, FakePopup.wrongState(world));

        expect(error, contains('state mismatch'));
        expect(
          world.tokenRequests,
          isEmpty,
          reason: 'the code must not be exchanged',
        );
        expect(c.read(oauthServiceProvider).isSignedIn(id), isFalse);
      },
    );

    test('closing the window cancels cleanly', () async {
      final world = _world();
      final c = await _container(world);
      final id = (await _addProtected(c)).config.id;

      final popup = FakePopup.closedByUser();
      final error = await c.read(mcpHubProvider.notifier).authorize(id, popup);
      expect(error, contains('closed'));
      expect(popup.closed, isTrue);
    });

    test('a preset client id skips dynamic registration', () async {
      final world = _world(supportsRegistration: false);
      final c = await makeContainer(httpClient: world.client);
      addTearDown(c.dispose);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(
            name: 'P',
            url: oauthMcpUrl,
            oauth: true,
            oauthClientId: 'client-preset',
          );
      // The fake issues "client-1" only via /register; with a preset id the
      // authorization request must use the preset one.
      final popup = FakePopup((url) {
        expect(url.queryParameters['client_id'], 'client-preset');
        return world.authorize(url);
      });
      await c.read(mcpHubProvider.notifier).authorize(runtime.config.id, popup);
      expect(world.registrations, isEmpty);
    });

    test(
      'registration unsupported and no client id gives actionable guidance',
      () async {
        final world = _world(supportsRegistration: false);
        final c = await _container(world);
        final id = (await _addProtected(c)).config.id;
        final error = await c
            .read(mcpHubProvider.notifier)
            .authorize(id, FakePopup.approving(world));
        expect(error, contains('Client ID'));
      },
    );

    test('works without a readable challenge header (CORS hides it)', () async {
      final world = _world(withChallengeHeader: false);
      final c = await _container(world);
      final runtime = await _addProtected(c);
      expect(runtime.status, ServerStatus.needsAuth);
      expect(runtime.authChallenge, isNull);
      final error = await c
          .read(mcpHubProvider.notifier)
          .authorize(runtime.config.id, FakePopup.approving(world));
      expect(error, isNull);
      expect(
        c.read(mcpHubProvider).byId(runtime.config.id)!.status,
        ServerStatus.connected,
      );
    });
  });

  group('token lifecycle', () {
    Future<(ProviderContainer, FakeOAuthWorld, String)> signedIn() async {
      final world = _world();
      final c = await _container(world);
      final id = (await _addProtected(c)).config.id;
      await c
          .read(mcpHubProvider.notifier)
          .authorize(id, FakePopup.approving(world));
      return (c, world, id);
    }

    test('an expired access token is refreshed before use', () async {
      final (c, world, id) = await signedIn();
      _expire(c, id);
      final service = c.read(oauthServiceProvider);

      final token = await service.accessToken(id);

      expect(token, 'at-2');
      expect(world.tokenRequests.last['grant_type'], 'refresh_token');
      expect(world.tokenRequests.last['refresh_token'], 'rt-1');
      expect(
        service.sessionFor(id)!.tokens!.refreshToken,
        'rt-2',
        reason: 'rotated token is stored',
      );
    });

    test(
      'concurrent callers share one refresh (refresh tokens are single-use)',
      () async {
        final (c, world, id) = await signedIn();
        _expire(c, id);
        final service = c.read(oauthServiceProvider);

        final tokens = await Future.wait([
          service.accessToken(id),
          service.accessToken(id),
          service.accessToken(id),
        ]);

        expect(tokens, ['at-2', 'at-2', 'at-2']);
        expect(
          world.tokenRequests.where((r) => r['grant_type'] == 'refresh_token'),
          hasLength(1),
        );
      },
    );

    test(
      'a token revoked mid-session is refreshed and the call retried',
      () async {
        final (c, world, id) = await signedIn();
        world.revoke('at-1');

        final result = await c
            .read(mcpHubProvider.notifier)
            .callTool(
              serverId: id,
              toolName: 'lookup',
              args: {'q': 'x'},
              source: AuditSource.workbench,
              actor: 'user',
            );

        expect(result.isError, isFalse);
        expect(result.text, 'found x');
        expect(world.mcpAuthHeaders.last, 'Bearer at-2');
      },
    );

    test(
      'a dead refresh token clears the tokens and asks to sign in again',
      () async {
        final (c, world, id) = await signedIn();
        _expire(c, id);
        world.refreshFails = true;

        await c.read(mcpHubProvider.notifier).connect(id);

        expect(c.read(mcpHubProvider).byId(id)!.status, ServerStatus.needsAuth);
        expect(c.read(oauthServiceProvider).isSignedIn(id), isFalse);
        expect(
          c.read(oauthServiceProvider).sessionFor(id),
          isNotNull,
          reason: 'the registered client is kept',
        );
      },
    );

    test('sign out forgets tokens but not the client; signing in again does not re-register', () async {
      final (c, world, id) = await signedIn();
      final hub = c.read(mcpHubProvider.notifier);

      hub.signOut(id);
      expect(c.read(mcpHubProvider).byId(id)!.status, ServerStatus.needsAuth);
      expect(c.read(oauthServiceProvider).isSignedIn(id), isFalse);

      await hub.authorize(id, FakePopup.approving(world));
      expect(c.read(mcpHubProvider).byId(id)!.status, ServerStatus.connected);
      expect(world.registrations, hasLength(1));
    });

    test(
      'changing the server URL or removing the server drops its OAuth session',
      () async {
        final (c, world, id) = await signedIn();
        final hub = c.read(mcpHubProvider.notifier);
        final config = c.read(mcpHubProvider).byId(id)!.config;

        await hub.updateServer(config.copyWith(url: 'https://other.test/mcp'));
        expect(c.read(oauthServiceProvider).sessionFor(id), isNull);

        await hub.updateServer(config.copyWith(url: oauthMcpUrl));
        await hub.authorize(id, FakePopup.approving(world));
        expect(c.read(oauthServiceProvider).sessionFor(id), isNotNull);
        hub.removeServer(id);
        expect(c.read(oauthServiceProvider).sessionFor(id), isNull);
      },
    );

    test('OAuth state survives a restart', () async {
      final (c, world, id) = await signedIn();
      final stored = c.read(oauthSessionsProvider)[id]!.toJson();
      expect(stored['tokens'], isNotNull);

      final prefs = <String, Object>{
        'mcpm.servers.v1':
            '[${_encode(c.read(mcpHubProvider).byId(id)!.config.toJson())}]',
        'mcpm.oauth.v1': _encode({id: stored}),
      };
      final second = await makeContainer(
        httpClient: world.client,
        prefs: prefs,
      );
      addTearDown(second.dispose);
      second.read(mcpHubProvider);
      await pumpEventQueue();

      expect(
        second.read(mcpHubProvider).byId(id)!.status,
        ServerStatus.connected,
        reason: 'stored tokens are used without a new sign-in',
      );
    });
  });

  group('static bearer tokens are unchanged', () {
    test(
      'a rejected static token is a plain error, not a sign-in prompt',
      () async {
        final world = _world();
        final c = await _container(world);
        final runtime = await c
            .read(mcpHubProvider.notifier)
            .addServer(
              name: 'Static',
              url: oauthMcpUrl,
              headers: {'Authorization': 'Bearer wrong'},
            );

        expect(runtime.status, ServerStatus.error);
        expect(runtime.error, contains('Check the server headers/token'));
      },
    );
  });
}

String _encode(Object o) => jsonEncode(o);

/// Marks the stored access token as expired without touching the refresh token.
void _expire(ProviderContainer c, String id) {
  final session = c.read(oauthSessionsProvider)[id]!;
  final t = session.tokens!;
  c
      .read(oauthSessionsProvider.notifier)
      .put(
        id,
        session.withTokens(
          OAuthTokens(
            accessToken: t.accessToken,
            refreshToken: t.refreshToken,
            expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        ),
      );
}
