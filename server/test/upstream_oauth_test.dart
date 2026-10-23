import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_oauth_upstream.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';
import 'support/sse.dart';

void main() {
  late Harness gw;
  late FakeOAuthUpstream up;

  setUp(() async {
    gw = await Harness.start();
    up = await FakeOAuthUpstream.start();
    await gw.adminJson('PUT', '/api/servers/srv', {
      'name': 'OAuth',
      'url': up.url,
      'transport': 'streamable-http',
      'oauth': true,
    });
  });

  tearDown(() async {
    await gw.close();
    await up.close();
  });

  Future<Map<String, dynamic>> saveServer({
    String? url,
    bool oauth = true,
    Map<String, dynamic> extra = const {},
  }) => gw.adminJson('PUT', '/api/servers/srv', {
    'name': 'OAuth',
    'url': url ?? up.url,
    'transport': 'streamable-http',
    'oauth': oauth,
    ...extra,
  });

  Future<Uri> start({String? returnTo}) async {
    final r = await gw.admin('POST', '/api/servers/srv/oauth/start', {
      'returnTo': ?returnTo,
    });
    expect(r.statusCode, 200, reason: r.body);
    return Uri.parse(jsonDecode(r.body)['authorizeUrl'] as String);
  }

  /// A full sign-in: start, approve at the upstream, come back.
  Future<http.Response> signIn({String? returnTo}) async {
    final back = up.approve(await start(returnTo: returnTo));
    return gw.rawGet('${back.path}?${back.query}');
  }

  Future<Map<String, dynamic>> status() =>
      gw.adminJson('GET', '/api/servers/srv/oauth');

  Future<Map<String, dynamic>> call([String tool = 'whoami']) =>
      gw.adminJson('POST', '/api/servers/srv/call', {'tool': tool});

  group('starting a sign-in', () {
    test(
      'builds the upstream\'s sign-in address with PKCE and the resource',
      () async {
        final url = await start();
        expect(url.origin, up.origin);
        expect(url.path, '/authorize');
        final q = url.queryParameters;
        expect(q['response_type'], 'code');
        expect(q['client_id'], 'client-1');
        expect(q['redirect_uri'], '${gw.base}/oauth/upstream/callback');
        expect(q['code_challenge_method'], 'S256');
        expect(q['code_challenge'], hasLength(greaterThan(30)));
        expect(q['state'], hasLength(greaterThan(20)));
        expect(q['resource'], up.url);
        expect(
          q['scope'],
          'read',
          reason: 'taken from the server\'s challenge',
        );
      },
    );

    test('registers the gateway as a client, once', () async {
      await start();
      await start();
      expect(up.registrations, hasLength(1));
      expect(up.registrations.single['redirect_uris'], [
        '${gw.base}/oauth/upstream/callback',
      ]);
      expect(up.registrations.single['token_endpoint_auth_method'], 'none');
    });

    test('a scope set on the server wins over the challenge', () async {
      await saveServer(extra: {'oauthScope': 'mine'});
      expect((await start()).queryParameters['scope'], 'mine');
    });

    test('a client id set by hand is used without registering', () async {
      await saveServer(extra: {'oauthClientId': 'preset-1'});
      final url = await start();
      expect(url.queryParameters['client_id'], 'preset-1');
      expect(up.registrations, isEmpty);
    });

    test('is refused for a server that does not use OAuth', () async {
      await saveServer(oauth: false);
      final r = await gw.admin('POST', '/api/servers/srv/oauth/start', {});
      expect(r.statusCode, 502);
      expect(jsonDecode(r.body)['error'], 'oauth_failed');
    });

    test('is refused for a server that asks for nothing', () async {
      final open = await FakeUpstream.start(tools: [tool('x')]);
      addTearDown(open.close);
      await saveServer(url: open.url);
      final r = await gw.admin('POST', '/api/servers/srv/oauth/start', {});
      expect(r.statusCode, 502);
      expect(jsonDecode(r.body)['message'], contains('did not ask'));
    });

    test('is refused for an unknown server', () async {
      final r = await gw.admin('POST', '/api/servers/nope/oauth/start', {});
      expect(r.statusCode, 404);
    });

    test('needs a credential', () async {
      final r = await gw.client.post(
        Uri.parse('${gw.base}/api/servers/srv/oauth/start'),
      );
      expect(r.statusCode, 401);
    });

    test('says so when the upstream cannot be reached', () async {
      await up.close();
      final r = await gw.admin('POST', '/api/servers/srv/oauth/start', {});
      expect(r.statusCode, 502);
      expect(jsonDecode(r.body)['message'], isNotEmpty);
    });
  });

  group('coming back from the upstream', () {
    test('stores the tokens and says the server is connected', () async {
      expect((await status())['signedIn'], isFalse);
      final r = await signIn();
      expect(r.statusCode, 200);
      expect(r.body, contains('OAuth is connected'));
      final s = await status();
      expect(s['signedIn'], isTrue);
      expect(s['canRefresh'], isTrue);
      expect(s['scope'], 'read');
      expect(s['issuer'], up.origin);
    });

    test(
      'exchanges the code with the right verifier, client and redirect',
      () async {
        await signIn();
        final t = up.tokenRequests.single;
        expect(t['grant_type'], 'authorization_code');
        expect(t['client_id'], 'client-1');
        expect(t['redirect_uri'], '${gw.base}/oauth/upstream/callback');
        expect(t['resource'], up.url);
        expect(t['code_verifier'], hasLength(greaterThan(40)));
      },
    );

    test('never shows a token to the dashboard', () async {
      await signIn();
      final all = [
        (await gw.admin('GET', '/api/servers/srv/oauth')).body,
        (await gw.admin('GET', '/api/servers')).body,
        (await gw.admin('GET', '/api/servers/srv')).body,
        (await gw.admin('GET', '/api/status')).body,
      ].join();
      expect(all, isNot(contains('at-')));
      expect(all, isNot(contains('rt-')));
    });

    test('can send the browser back to the dashboard', () async {
      await gw.close();
      gw = await Harness.start(allowedOrigins: ['https://dash.example.com']);
      await saveServer();
      final r = await signIn(returnTo: 'https://dash.example.com/servers');
      expect(r.statusCode, 302);
      expect(r.headers['location'], 'https://dash.example.com/servers');
    });

    test('refuses to send the browser anywhere else', () async {
      final r = await gw.admin('POST', '/api/servers/srv/oauth/start', {
        'returnTo': 'https://evil.example.com/',
      });
      expect(r.statusCode, 400);
    });

    test('announces it on the event stream', () async {
      final events = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer $adminToken'},
      );
      addTearDown(events.close);
      await events.nextOf('ready');
      await signIn();
      final e = await events.nextOf('oauth');
      expect(e.data, {'serverId': 'srv', 'signedIn': true});
    });

    test('refuses a response it did not ask for', () async {
      final r = await gw.rawGet(
        '/oauth/upstream/callback?code=x&state=made-up',
      );
      expect(r.statusCode, 400);
      expect((await status())['signedIn'], isFalse);
    });

    test('cannot be completed twice', () async {
      final back = up.approve(await start());
      final path = '${back.path}?${back.query}';
      expect((await gw.rawGet(path)).statusCode, 200);
      expect((await gw.rawGet(path)).statusCode, 400);
    });

    test('expires after ten minutes', () async {
      final back = up.approve(await start());
      gw.clock.advance(const Duration(minutes: 11));
      expect((await gw.rawGet('${back.path}?${back.query}')).statusCode, 400);
      expect((await status())['signedIn'], isFalse);
    });

    test('reports a refusal at the upstream', () async {
      final back = up.approve(await start(), error: 'access_denied');
      final r = await gw.rawGet('${back.path}?${back.query}');
      expect(r.statusCode, 403);
      expect((await status())['signedIn'], isFalse);
    });

    test('reports a code the upstream will not accept', () async {
      final back = await start();
      final r = await gw.rawGet(
        '/oauth/upstream/callback?code=forged&state=${back.queryParameters['state']}',
      );
      expect(r.statusCode, 502);
      expect((await status())['signedIn'], isFalse);
    });

    test('is refused if the server was deleted meanwhile', () async {
      final back = up.approve(await start());
      await gw.adminJson('DELETE', '/api/servers/srv');
      expect((await gw.rawGet('${back.path}?${back.query}')).statusCode, 404);
      expect(gw.gateway.store.state.upstreamOAuth, isEmpty);
    });
  });

  group('once signed in', () {
    setUp(() => signIn());

    test('the server\'s tools can be listed', () async {
      final r = await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      expect(r['error'], isNull);
      expect(
        [for (final t in r['tools'] as List) (t as Map)['name']],
        ['whoami'],
      );
    });

    test('calls carry the access token', () async {
      final r = await call();
      expect(r['status'], 'success');
      expect(r['text'], startsWith('token:at-'));
      expect(up.mcpRequests.last, startsWith('at-'));
    });

    test('portal clients use the server too', () async {
      await gw.addPortal('Portal', ['srv'], slug: 'p');
      final token = await gw.addToken('c');
      expect(await gw.toolNames('p', token), ['oauth__whoami']);
      final r = await gw.callTool('p', token, 'oauth__whoami');
      expect(gw.textOf(r), startsWith('token:at-'));
    });

    test('the health check sees it as up', () async {
      final h = (await gw.adminJson('POST', '/api/health/check'))['servers'];
      expect(h['srv']['ok'], isTrue);
    });

    test('an expired token is refreshed, and the new one is used', () async {
      final first = (await call())['text'] as String;
      gw.clock.advance(const Duration(hours: 2));
      final second = (await call())['text'] as String;
      expect(up.refreshCount, 1);
      expect(second, isNot(first));
      expect(up.tokenRequests.last['resource'], up.url);
      expect((await status())['signedIn'], isTrue);
    });

    test('many calls at once cause one refresh', () async {
      await call();
      gw.clock.advance(const Duration(hours: 2));
      final results = await Future.wait([for (var i = 0; i < 6; i++) call()]);
      expect(results.every((r) => r['status'] == 'success'), isTrue);
      expect(up.refreshCount, 1, reason: 'refresh tokens are single-use');
    });

    test('asking for a token many times at once refreshes once', () async {
      gw.clock.advance(const Duration(hours: 2));
      final tokens = await Future.wait([
        for (var i = 0; i < 8; i++) gw.gateway.upstreamOAuth.accessToken('srv'),
      ]);
      expect(up.refreshCount, 1, reason: 'refresh tokens are single-use');
      expect(tokens.toSet(), hasLength(1));
      expect(tokens.first, startsWith('at-'));
      expect((await status())['signedIn'], isTrue);
    });

    test(
      'a token the server revoked early is replaced and the call retried',
      () async {
        await call();
        up.revokeAccessTokens();
        final r = await call();
        expect(r['status'], 'success');
        expect(up.refreshCount, 1);
      },
    );

    test('a refresh the server refuses signs the server out', () async {
      final events = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer $adminToken'},
      );
      addTearDown(events.close);
      await events.nextOf('ready');
      await call();
      up.rejectRefresh = true;
      gw.clock.advance(const Duration(hours: 2));
      final r = await call();
      expect(r['status'], 'error');
      expect(r['isError'], isTrue);
      expect((await status())['signedIn'], isFalse);
      expect((await events.nextOf('oauth')).data['signedIn'], isFalse);
    });

    test('signing out forgets the tokens but keeps the registration', () async {
      await gw.adminJson('DELETE', '/api/servers/srv/oauth');
      expect((await status())['signedIn'], isFalse);
      final r = await gw.admin('POST', '/api/servers/srv/call', {
        'tool': 'whoami',
      });
      expect(r.statusCode, 502);
      await start();
      expect(up.registrations, hasLength(1), reason: 'no second registration');
    });

    test('forgetting also drops the registration', () async {
      await gw.adminJson('DELETE', '/api/servers/srv/oauth?forget=1');
      await start();
      expect(up.registrations, hasLength(2));
    });

    test('a different address starts over', () async {
      final other = await FakeOAuthUpstream.start();
      addTearDown(other.close);
      await saveServer(url: other.url);
      expect((await status())['signedIn'], isFalse);
    });

    test('turning OAuth off drops the tokens', () async {
      await saveServer(oauth: false);
      expect((await status())['signedIn'], isFalse);
      expect(gw.gateway.store.state.upstreamOAuth, isEmpty);
    });

    test('deleting the server deletes them', () async {
      await gw.adminJson('DELETE', '/api/servers/srv');
      expect(gw.gateway.store.state.upstreamOAuth, isEmpty);
    });

    test('renaming the server keeps them', () async {
      await saveServer(extra: {'name': 'Renamed'});
      expect((await status())['signedIn'], isTrue);
    });
  });

  group('before signing in', () {
    test('the server\'s tools say a sign-in is needed', () async {
      final r = await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      expect(r['error'], isNotNull);
      expect(r['tools'], isEmpty);
    });

    test('a call is a clear 502', () async {
      final r = await gw.admin('POST', '/api/servers/srv/call', {
        'tool': 'whoami',
      });
      expect(r.statusCode, 502);
      expect(jsonDecode(r.body)['error'], 'server_unreachable');
    });
  });
}
