import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_portal_server/mcp_portal_server.dart';
import 'package:test/test.dart';

import 'support/fake_upstream.dart';
import 'support/harness.dart';

const verifier = 'a-long-random-code-verifier-0123456789-abcdefghijklmnop';
const redirect = 'https://client.example.com/callback';

void main() {
  late Harness gw;
  late FakeUpstream upstream;

  setUp(() async {
    gw = await Harness.start();
    upstream = await FakeUpstream.start(
      tools: [tool('lookup')],
      handlers: {'lookup': (_) => textResult('found')},
    );
    await gw.addServer('Docs', upstream.url, id: 'srv');
    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    await gw.addPortal('Other', ['srv'], slug: 'other');
  });

  tearDown(() async {
    await gw.close();
    await upstream.close();
  });

  Future<String> register({
    String name = 'Test client',
    List<String> redirects = const [redirect],
  }) async {
    final r = await gw.client.post(
      Uri.parse('${gw.base}/oauth/register'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'client_name': name,
        'redirect_uris': redirects,
        'token_endpoint_auth_method': 'none',
      }),
    );
    expect(r.statusCode, 201, reason: r.body);
    return jsonDecode(r.body)['client_id'] as String;
  }

  Map<String, String> authParams(
    String clientId, {
    String? resource,
    String state = 'st4te',
    String? challenge,
    String redirectUri = redirect,
  }) => {
    'client_id': clientId,
    'redirect_uri': redirectUri,
    'response_type': 'code',
    'code_challenge': challenge ?? pkceS256(verifier),
    'code_challenge_method': 'S256',
    'state': state,
    'scope': 'mcp:tools',
    'resource': ?resource,
  };

  /// Posts the consent form; returns the response without following redirects.
  Future<http.Response> consent(
    Map<String, String> params, {
    String password = adminToken,
    String decision = 'allow',
  }) async {
    final request =
        http.Request('POST', Uri.parse('${gw.base}/oauth/authorize'))
          ..followRedirects = false
          ..headers['content-type'] = 'application/x-www-form-urlencoded'
          ..bodyFields = {
            ...params,
            'password': password,
            'decision': decision,
          };
    return http.Response.fromStream(await gw.client.send(request));
  }

  Future<String> authorize(String clientId, {String? resource}) async {
    final r = await consent(authParams(clientId, resource: resource));
    expect(r.statusCode, 302, reason: r.body);
    return Uri.parse(r.headers['location']!).queryParameters['code']!;
  }

  Future<http.Response> exchange(Map<String, String> body) => gw.client.post(
    Uri.parse('${gw.base}/oauth/token'),
    headers: {'content-type': 'application/x-www-form-urlencoded'},
    body: body,
  );

  Future<Map<String, dynamic>> tokens(
    String clientId, {
    String? resource,
  }) async {
    final code = await authorize(clientId, resource: resource);
    final r = await exchange({
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': clientId,
      'redirect_uri': redirect,
      'code_verifier': verifier,
    });
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map).cast<String, dynamic>();
  }

  group('discovery', () {
    test('the authorization server describes its endpoints', () async {
      final r = await gw.client.get(
        Uri.parse('${gw.base}/.well-known/oauth-authorization-server'),
      );
      final meta = jsonDecode(r.body) as Map;
      expect(meta['issuer'], gw.base);
      expect(meta['authorization_endpoint'], '${gw.base}/oauth/authorize');
      expect(meta['token_endpoint'], '${gw.base}/oauth/token');
      expect(meta['registration_endpoint'], '${gw.base}/oauth/register');
      expect(meta['code_challenge_methods_supported'], ['S256']);
      expect(meta['token_endpoint_auth_methods_supported'], ['none']);
      expect(r.headers['access-control-allow-origin'], '*');
    });

    test('each portal is a protected resource of its own', () async {
      final r = await gw.client.get(
        Uri.parse('${gw.base}/.well-known/oauth-protected-resource/mcp/docs'),
      );
      final meta = jsonDecode(r.body) as Map;
      expect(meta['resource'], '${gw.base}/mcp/docs');
      expect(meta['authorization_servers'], [gw.base]);

      final root = await gw.client.get(
        Uri.parse('${gw.base}/.well-known/oauth-protected-resource'),
      );
      expect(jsonDecode(root.body)['resource'], gw.base);
      final none = await gw.client.get(
        Uri.parse('${gw.base}/.well-known/oauth-protected-resource/mcp/ghost'),
      );
      expect(none.statusCode, 404);
    });
  });

  group('registration', () {
    test('gives a public client an id', () async {
      expect(await register(), startsWith('mcpc_'));
    });

    test('rejects bad redirect addresses and confidential clients', () async {
      Future<int> status(Map<String, dynamic> body) async =>
          (await gw.client.post(
            Uri.parse('${gw.base}/oauth/register'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(body),
          )).statusCode;

      expect(await status({}), 400);
      expect(await status({'redirect_uris': []}), 400);
      expect(
        await status({
          'redirect_uris': ['javascript:alert(1)'],
        }),
        400,
      );
      expect(
        await status({
          'redirect_uris': ['http://evil.example.com/cb'],
        }),
        400,
      );
      expect(
        await status({
          'redirect_uris': ['https://x.example.com/cb#frag'],
        }),
        400,
      );
      expect(
        await status({
          'redirect_uris': ['https://x.example.com/cb'],
          'token_endpoint_auth_method': 'client_secret_basic',
        }),
        400,
      );
      expect(
        await status({
          'redirect_uris': ['http://localhost:8123/cb'],
        }),
        201,
      );
      expect(
        await status({
          'redirect_uris': ['claude://oauth/callback'],
        }),
        201,
      );
    });

    test('the number of registered clients is bounded', () async {
      for (var i = 0; i < 205; i++) {
        await register(name: 'client $i');
      }
      expect(
        gw.gateway.store.state.oauthClients.length,
        lessThanOrEqualTo(200),
      );
    });
  });

  group('the consent page', () {
    test('names the client and the portal, and cannot be framed', () async {
      final id = await register(name: 'My Assistant');
      final r = await gw.client.get(
        Uri.parse('${gw.base}/oauth/authorize').replace(
          queryParameters: authParams(id, resource: '${gw.base}/mcp/docs'),
        ),
      );
      expect(r.statusCode, 200);
      expect(r.body, contains('My Assistant'));
      expect(r.body, contains('client.example.com'));
      expect(r.body, contains('<strong>Docs</strong>'));
      expect(r.headers['x-frame-options'], 'DENY');
      expect(
        r.headers['content-security-policy'],
        contains("frame-ancestors 'none'"),
      );
      expect(
        r.headers['content-security-policy'],
        contains("form-action 'self' https://client.example.com"),
      );
      expect(r.headers['cache-control'], 'no-store');
    });

    test('escapes anything a client can put in it', () async {
      final id = await register(name: '<script>alert(1)</script>');
      final r = await gw.client.get(
        Uri.parse('${gw.base}/oauth/authorize').replace(
          queryParameters: authParams(
            id,
            state: '"><img src=x onerror=alert(1)>',
          ),
        ),
      );
      expect(r.body, isNot(contains('<script>alert')));
      expect(r.body, isNot(contains('<img src=x')));
      expect(r.body, contains('&lt;script&gt;'));
    });

    test('refuses a request it cannot trust', () async {
      final id = await register();
      Future<int> get(Map<String, String> p) async => (await gw.client.get(
        Uri.parse('${gw.base}/oauth/authorize').replace(queryParameters: p),
      )).statusCode;

      expect(await get(authParams('mcpc_unknown')), 400);
      expect(
        await get(authParams(id, redirectUri: 'https://evil.example.com/cb')),
        400,
      );
      expect(await get({...authParams(id), 'response_type': 'token'}), 400);
      expect(
        await get({...authParams(id), 'code_challenge_method': 'plain'}),
        400,
      );
      expect(await get(authParams(id, resource: '${gw.base}/mcp/ghost')), 400);
      expect(await get(authParams(id)), 200);
    });

    test(
      'a custom redirect scheme is allowed through the page policy',
      () async {
        final id = await register(redirects: ['claude://oauth/callback']);
        final r = await gw.client.get(
          Uri.parse('${gw.base}/oauth/authorize').replace(
            queryParameters: authParams(
              id,
              redirectUri: 'claude://oauth/callback',
            ),
          ),
        );
        expect(
          r.headers['content-security-policy'],
          contains('form-action \'self\' claude:'),
        );
      },
    );
  });

  group('signing in', () {
    test('a wrong password shows the page again, with no code', () async {
      final id = await register();
      final r = await consent(authParams(id), password: 'nope-nope-nope-nope');
      expect(r.statusCode, 401);
      expect(r.body, contains('That is not the admin token.'));
      expect(r.headers['location'], isNull);
    });

    test(
      'the right password redirects with a code and the client\'s state',
      () async {
        final id = await register();
        final r = await consent(authParams(id, state: 'abc'));
        expect(r.statusCode, 302);
        final location = Uri.parse(r.headers['location']!);
        expect(location.origin, 'https://client.example.com');
        expect(location.path, '/callback');
        expect(location.queryParameters['state'], 'abc');
        expect(location.queryParameters['code'], isNotEmpty);
      },
    );

    test('denying redirects with access_denied', () async {
      final id = await register();
      final r = await consent(authParams(id), decision: 'deny', password: '');
      expect(r.statusCode, 302);
      final q = Uri.parse(r.headers['location']!).queryParameters;
      expect(q['error'], 'access_denied');
      expect(q.containsKey('code'), isFalse);
    });

    test('many wrong attempts lock the page for a while', () async {
      final id = await register();
      for (var i = 0; i < 10; i++) {
        expect(
          (await consent(
            authParams(id),
            password: 'wrong-wrong-wrong-wrong',
          )).statusCode,
          401,
        );
      }
      expect(
        (await consent(
          authParams(id),
          password: 'wrong-wrong-wrong-wrong',
        )).statusCode,
        429,
      );
      // Even the right password waits.
      expect((await consent(authParams(id))).statusCode, 429);

      gw.clock.advance(const Duration(minutes: 16));
      expect((await consent(authParams(id))).statusCode, 302);
    });
  });

  group('tokens', () {
    test(
      'an access token opens the portal like any other credential',
      () async {
        final id = await register(name: 'Claude');
        final t = await tokens(id);
        expect(t['token_type'], 'Bearer');
        expect(t['expires_in'], 3600);
        expect(t['access_token'], startsWith('mcpa_'));
        expect(t['refresh_token'], startsWith('mcpr_'));

        expect(await gw.toolNames('docs', t['access_token'] as String), [
          'docs__lookup',
        ]);
        expect(
          gw.textOf(
            await gw.callTool(
              'docs',
              t['access_token'] as String,
              'docs__lookup',
            ),
          ),
          'found',
        );
        final event = (await gw.gateway.audit.recent()).first;
        expect(event.principal, {'kind': 'oauth', 'id': id, 'name': 'Claude'});
      },
    );

    test('the secrets are stored only as hashes', () async {
      final id = await register();
      final t = await tokens(id);
      final stored = jsonEncode(gw.gateway.store.state.toJson());
      expect(stored, isNot(contains(t['access_token'] as String)));
      expect(stored, isNot(contains(t['refresh_token'] as String)));
    });

    test('a code works once', () async {
      final id = await register();
      final code = await authorize(id);
      final body = {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': id,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      };
      expect((await exchange(body)).statusCode, 200);
      final again = await exchange(body);
      expect(again.statusCode, 400);
      expect(jsonDecode(again.body)['error'], 'invalid_grant');
    });

    test(
      'a wrong verifier, client or redirect is refused, and burns the code',
      () async {
        final id = await register();
        final other = await register(name: 'other');
        for (final change in <Map<String, String>>[
          {
            'code_verifier':
                'not-the-verifier-not-the-verifier-not-the-verifier',
          },
          {'client_id': other},
          {'redirect_uri': 'https://client.example.com/other'},
        ]) {
          final code = await authorize(id);
          final r = await exchange({
            'grant_type': 'authorization_code',
            'code': code,
            'client_id': id,
            'redirect_uri': redirect,
            'code_verifier': verifier,
            ...change,
          });
          expect(r.statusCode, 400, reason: '$change');
          expect(jsonDecode(r.body)['error'], 'invalid_grant');
        }
      },
    );

    test('a code expires after five minutes', () async {
      final id = await register();
      final code = await authorize(id);
      gw.clock.advance(const Duration(minutes: 6));
      final r = await exchange({
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': id,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      expect(r.statusCode, 400);
    });

    test('an access token expires after an hour', () async {
      final t = await tokens(await register());
      final access = t['access_token'] as String;
      expect(await gw.toolNames('docs', access), isNotEmpty);
      gw.clock.advance(const Duration(minutes: 61));
      final r = await gw.post('docs', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: access);
      expect(r.statusCode, 401);
    });

    test('a refresh token gives new tokens and works only once', () async {
      final id = await register();
      final first = await tokens(id);
      gw.clock.advance(const Duration(minutes: 90));

      final r = await exchange({
        'grant_type': 'refresh_token',
        'refresh_token': first['refresh_token'] as String,
        'client_id': id,
      });
      expect(r.statusCode, 200, reason: r.body);
      final second = (jsonDecode(r.body) as Map).cast<String, dynamic>();
      expect(second['access_token'], isNot(first['access_token']));
      expect(
        await gw.toolNames('docs', second['access_token'] as String),
        isNotEmpty,
      );

      final reuse = await exchange({
        'grant_type': 'refresh_token',
        'refresh_token': first['refresh_token'] as String,
        'client_id': id,
      });
      expect(reuse.statusCode, 400);
    });

    test('a refresh token belongs to its client', () async {
      final id = await register();
      final other = await register(name: 'other');
      final t = await tokens(id);
      final r = await exchange({
        'grant_type': 'refresh_token',
        'refresh_token': t['refresh_token'] as String,
        'client_id': other,
      });
      expect(r.statusCode, 400);
    });

    test('a token asked for one portal opens only that portal', () async {
      final id = await register();
      final t = await tokens(id, resource: '${gw.base}/mcp/docs');
      final access = t['access_token'] as String;
      expect(await gw.toolNames('docs', access), isNotEmpty);
      final r = await gw.post('other', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: access);
      expect(r.statusCode, 403);

      // ...and so does its refresh token, when it is exchanged.
      final refreshed = await exchange({
        'grant_type': 'refresh_token',
        'refresh_token': t['refresh_token'] as String,
        'client_id': id,
      });
      final again =
          (jsonDecode(refreshed.body) as Map)['access_token'] as String;
      expect(
        (await gw.post('other', {
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
        }, token: again)).statusCode,
        403,
      );
    });

    test('unsupported grants and missing fields are errors', () async {
      expect(
        jsonDecode((await exchange({'grant_type': 'password'})).body)['error'],
        'unsupported_grant_type',
      );
      expect(
        jsonDecode(
          (await exchange({'grant_type': 'authorization_code'})).body,
        )['error'],
        'invalid_request',
      );
      expect(
        jsonDecode(
          (await exchange({'grant_type': 'refresh_token'})).body,
        )['error'],
        'invalid_request',
      );
    });

    test('a token response is never cached', () async {
      final id = await register();
      final code = await authorize(id);
      final r = await exchange({
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': id,
        'redirect_uri': redirect,
        'code_verifier': verifier,
      });
      expect(r.headers['cache-control'], 'no-store');
    });
  });
}
