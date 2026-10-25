import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_portal_server/mcp_portal_server.dart';
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';

final ada = GhUser(1, 'Ada', name: 'Ada Lovelace', orgs: ['acme', 'other']);
final eve = GhUser(2, 'eve', orgs: ['elsewhere']);

void main() {
  late FakeGitHub github;
  late Harness gw;

  setUp(() async {
    github = await FakeGitHub.start();
    gw = await Harness.start(github: github, githubOrgs: ['Acme']);
  });

  tearDown(() async {
    await gw.close();
    await github.close();
  });

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    final request = http.Request('GET', Uri.parse('${gw.base}$path'))
      ..followRedirects = false
      ..headers.addAll(headers ?? {});
    return http.Response.fromStream(await gw.client.send(request));
  }

  String? cookieValue(http.Response r, String name) => RegExp(
    '$name=([^;,\\s]*)',
  ).firstMatch(r.headers['set-cookie'] ?? '')?.group(1);

  Future<({String state, String cookie, Uri github})> begin([
    String? returnTo,
  ]) async {
    final query = returnTo == null
        ? ''
        : '?return_to=${Uri.encodeQueryComponent(returnTo)}';
    final r = await get('/auth/github$query');
    expect(r.statusCode, 302, reason: r.body);
    final location = Uri.parse(r.headers['location']!);
    return (
      state: location.queryParameters['state']!,
      cookie: cookieValue(r, 'mcp_login')!,
      github: location,
    );
  }

  Future<http.Response> callback(String code, String state, {String? cookie}) =>
      get(
        '/auth/github/callback?code=$code&state=$state',
        headers: {'cookie': 'mcp_login=${cookie ?? ''}'},
      );

  /// Signs [user] in the way a browser would; returns the callback response.
  Future<http.Response> signIn(GhUser user, {String? returnTo}) async {
    final code = github.codeFor(user);
    final b = await begin(returnTo);
    return callback(code, b.state, cookie: b.cookie);
  }

  Future<String> sessionFor(GhUser user) async {
    final r = await signIn(user);
    expect(r.statusCode, 302, reason: r.body);
    return cookieValue(r, 'mcp_session')!;
  }

  Future<http.Response> asMember(String session, String method, String path) =>
      gw.admin(method, path, null, {'authorization': 'Bearer $session'});

  group('starting a sign-in', () {
    test('sends the browser to GitHub with a state it can check', () async {
      final b = await begin();
      expect(b.github.toString(), startsWith(github.url));
      expect(b.github.path, '/login/oauth/authorize');
      expect(b.github.queryParameters['client_id'], 'gh-client');
      expect(
        b.github.queryParameters['redirect_uri'],
        '${gw.base}/auth/github/callback',
      );
      expect(b.github.queryParameters['scope'], contains('read:org'));
      expect(b.github.queryParameters['scope'], isNot(contains('repo')));
      expect(b.github.queryParameters['state'], hasLength(greaterThan(20)));
      expect(
        b.cookie,
        b.state,
        reason: 'the cookie ties the state to a browser',
      );
    });

    test('keeps the state cookie away from scripts', () async {
      final r = await get('/auth/github');
      final header = r.headers['set-cookie']!;
      expect(header, contains('HttpOnly'));
      expect(header, contains('SameSite=Lax'));
      expect(header, isNot(contains('Secure')), reason: 'plain http here');
    });

    test('is Secure behind https', () async {
      await gw.close();
      gw = await Harness.start(
        github: github,
        githubOrgs: ['acme'],
        publicUrl: 'https://mcp.example.com',
      );
      final r = await get('/auth/github');
      expect(r.headers['set-cookie'], contains('Secure'));
      expect(
        Uri.parse(r.headers['location']!).queryParameters['redirect_uri'],
        'https://mcp.example.com/auth/github/callback',
      );
    });

    test('reports whether sign-in is set up', () async {
      final r = await get('/auth/config');
      expect(jsonDecode(r.body), {
        'providers': [
          {'id': 'github', 'kind': 'github', 'name': 'GitHub'},
        ],
        'github': true,
        'orgs': ['Acme'],
      });
      expect(r.headers['access-control-allow-origin'], '*');
    });

    test('says so when GitHub login is not configured', () async {
      final plain = await Harness.start();
      addTearDown(plain.close);
      final config = await plain.client.get(
        Uri.parse('${plain.base}/auth/config'),
      );
      expect(jsonDecode(config.body)['github'], isFalse);
      final start = await plain.client.get(
        Uri.parse('${plain.base}/auth/github'),
      );
      expect(start.statusCode, 404);
    });
  });

  group('where it returns to', () {
    test('a path on this server is fine', () async {
      final r = await signIn(ada, returnTo: '/auth/done');
      expect(r.statusCode, 302);
      expect(r.headers['location'], '/auth/done');
    });

    test(
      'a dashboard on an allowed origin gets the session in the fragment',
      () async {
        await gw.close();
        gw = await Harness.start(
          github: github,
          githubOrgs: ['acme'],
          allowedOrigins: ['https://dash.example.com'],
        );
        final r = await signIn(ada, returnTo: 'https://dash.example.com/app');
        expect(r.statusCode, 302);
        final location = Uri.parse(r.headers['location']!);
        expect(location.origin, 'https://dash.example.com');
        final token = Uri.splitQueryString(location.fragment)['session']!;
        expect(token, startsWith('mcps_'));
        expect(location.query, isEmpty, reason: 'never in the query string');
        expect((await asMember(token, 'GET', '/api/me')).statusCode, 200);
      },
    );

    test('localhost dashboards are allowed', () async {
      final r = await signIn(ada, returnTo: 'http://localhost:9555/');
      expect(r.statusCode, 302);
      expect(
        r.headers['location'],
        startsWith('http://localhost:9555/#session='),
      );
      // The dashboard is also told which server this was.
      final params = Uri.splitQueryString(
        Uri.parse(r.headers['location']!).fragment,
      );
      expect(params['server'], gw.base);
    });

    for (final bad in [
      'https://evil.example.com/',
      '//evil.example.com/x',
      r'/\evil.example.com',
      'javascript:alert(1)',
      'ftp://dash.example.com/',
    ]) {
      test('refuses $bad', () async {
        final r = await get(
          '/auth/github?return_to=${Uri.encodeQueryComponent(bad)}',
        );
        expect(r.statusCode, 400);
        expect(r.headers['set-cookie'], isNull);
      });
    }
  });

  group('finishing a sign-in', () {
    test('lets in a member of an allowed organisation', () async {
      final r = await signIn(ada);
      expect(r.statusCode, 302);
      final session = cookieValue(r, 'mcp_session')!;
      expect(session, startsWith('mcps_'));
      expect(r.headers['set-cookie'], contains('HttpOnly'));

      final me = jsonDecode((await asMember(session, 'GET', '/api/me')).body);
      expect(me['kind'], 'member');
      expect(me['member']['login'], 'Ada');
      expect(me['member']['id'], 'github:1');
      expect(me['member']['orgs'], ['acme', 'other']);
      expect(me['member']['name'], 'Ada Lovelace');
    });

    test('asks GitHub for the profile and organisations, once each', () async {
      await signIn(ada);
      expect(github.requests, [
        'POST /login/oauth/access_token',
        'GET /user',
        'GET /user/orgs',
        'GET /user/emails',
      ]);
    });

    test('turns away someone outside the organisation', () async {
      final r = await signIn(eve);
      expect(r.statusCode, 403);
      expect(r.body, contains('eve'));
      expect(
        r.headers['set-cookie'] ?? '',
        isNot(contains('mcp_session=mcps_')),
      );
      final members = jsonDecode((await gw.admin('GET', '/api/members')).body);
      expect(members, isEmpty);
      expect(gw.gateway.store.state.sessions, isEmpty);
    });

    test('a user on the list gets in without the organisation', () async {
      await gw.close();
      gw = await Harness.start(github: github, githubUsers: ['EVE']);
      final r = await signIn(eve);
      expect(r.statusCode, 302);
      expect(cookieValue(r, 'mcp_session'), isNotNull);
    });

    test('with no organisation or user listed, nobody gets in', () async {
      await gw.close();
      gw = await Harness.start(github: github);
      expect((await signIn(ada)).statusCode, 403);
    });

    test('the same person signing in again is one member', () async {
      await signIn(ada);
      await signIn(ada);
      final members =
          jsonDecode((await gw.admin('GET', '/api/members')).body) as List;
      expect(members, hasLength(1));
      expect(gw.gateway.store.state.sessions, hasLength(2));
    });

    test('a changed GitHub profile is picked up', () async {
      await signIn(ada);
      await signIn(GhUser(1, 'ada-renamed', orgs: ['acme']));
      final members =
          jsonDecode((await gw.admin('GET', '/api/members')).body) as List;
      expect(members.single['login'], 'ada-renamed');
      expect(members.single['orgs'], ['acme']);
    });

    test(
      'an organisation list GitHub will not give means no organisation',
      () async {
        github.orgsStatus = 403;
        expect((await signIn(ada)).statusCode, 403);
      },
    );

    test('the GitHub token is not kept', () async {
      await signIn(ada);
      final stored = jsonEncode(gw.gateway.store.state.toJson());
      expect(stored, isNot(contains('gho_')));
    });

    test('the client secret goes to GitHub only', () async {
      final r = await signIn(ada);
      expect(r.body + r.headers.toString(), isNot(contains('gh-secret')));
      expect(github.secretsSeen, ['gh-secret']);
    });
  });

  group('a sign-in that was not started here', () {
    test('without the cookie is refused', () async {
      final code = github.codeFor(ada);
      final b = await begin();
      final r = await callback(code, b.state);
      expect(r.statusCode, 400);
      expect(gw.gateway.store.state.members, isEmpty);
    });

    test('with someone else\'s cookie is refused', () async {
      final code = github.codeFor(ada);
      final mine = await begin();
      final theirs = await begin();
      final r = await callback(code, mine.state, cookie: theirs.cookie);
      expect(r.statusCode, 400);
    });

    test('with an invented state is refused', () async {
      final code = github.codeFor(ada);
      final r = await callback(code, 'made-up', cookie: 'made-up');
      expect(r.statusCode, 400);
    });

    test('cannot be completed twice', () async {
      final code = github.codeFor(ada);
      final b = await begin();
      expect((await callback(code, b.state, cookie: b.cookie)).statusCode, 302);
      expect((await callback(code, b.state, cookie: b.cookie)).statusCode, 400);
    });

    test('expires after ten minutes', () async {
      final code = github.codeFor(ada);
      final b = await begin();
      gw.clock.advance(const Duration(minutes: 11));
      expect((await callback(code, b.state, cookie: b.cookie)).statusCode, 400);
    });

    test('refuses when the person cancelled at GitHub', () async {
      final b = await begin();
      final r = await get(
        '/auth/github/callback?error=access_denied&state=${b.state}',
        headers: {'cookie': 'mcp_login=${b.cookie}'},
      );
      expect(r.statusCode, 403);
    });

    test('says so when GitHub rejects the code', () async {
      github.rejectCodes = true;
      final r = await signIn(ada);
      expect(r.statusCode, 502);
      expect(gw.gateway.store.state.sessions, isEmpty);
    });

    test('says so when GitHub cannot be reached', () async {
      final code = github.codeFor(ada);
      final b = await begin();
      await github.close();
      final r = await callback(code, b.state, cookie: b.cookie);
      expect(r.statusCode, 502);
    });
  });

  group('a signed-in member', () {
    test('can use the admin API', () async {
      final session = await sessionFor(ada);
      expect((await asMember(session, 'GET', '/api/status')).statusCode, 200);
    });

    test('is not the admin: the admin token still works, separately', () async {
      final me = jsonDecode((await gw.admin('GET', '/api/me')).body);
      expect(me['kind'], 'admin');
    });

    test('is refused with a made-up session', () async {
      expect(
        (await asMember('mcps_nothing-real', 'GET', '/api/status')).statusCode,
        401,
      );
    });

    test('cannot use the session as a portal token', () async {
      final upstream = await FakeUpstream.start(tools: [tool('lookup')]);
      addTearDown(upstream.close);
      await gw.addServer('Docs', upstream.url, id: 'srv');
      await gw.addPortal('Docs', ['srv'], slug: 'docs');
      final session = await sessionFor(ada);
      final r = await gw.post('docs', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: session);
      expect(r.statusCode, 401);
    });

    test('is signed out for good by logging out', () async {
      final session = await sessionFor(ada);
      expect((await asMember(session, 'POST', '/api/logout')).statusCode, 204);
      expect((await asMember(session, 'GET', '/api/me')).statusCode, 401);
      expect(gw.gateway.store.state.sessions, isEmpty);
    });

    test('is signed out after the session runs out', () async {
      final session = await sessionFor(ada);
      gw.clock.advance(const Duration(days: 6));
      expect((await asMember(session, 'GET', '/api/me')).statusCode, 200);
      gw.clock.advance(const Duration(days: 2));
      expect((await asMember(session, 'GET', '/api/me')).statusCode, 401);
    });

    test('loses access the moment they are removed', () async {
      final session = await sessionFor(ada);
      final r = await gw.admin('DELETE', '/api/members/github:1');
      expect(r.statusCode, 204);
      expect((await asMember(session, 'GET', '/api/me')).statusCode, 401);
      expect(gw.gateway.store.state.members, isEmpty);
      expect(gw.gateway.store.state.sessions, isEmpty);
    });

    test('removing someone who is not a member is a 404', () async {
      expect(
        (await gw.admin('DELETE', '/api/members/github:99')).statusCode,
        404,
      );
    });

    test(
      'is turned away if the server stops allowing their organisation',
      () async {
        final session = await sessionFor(ada);
        // Same state, new allow-list: restart the login rules only.
        final state = gw.gateway.store.state;
        state.members[0] = state.members[0].copyWith(orgs: ['someone-else']);
        expect((await asMember(session, 'GET', '/api/me')).statusCode, 401);
      },
    );

    test('old sessions are cleared when someone signs in', () async {
      await sessionFor(ada);
      gw.clock.advance(const Duration(days: 10));
      await sessionFor(ada);
      expect(gw.gateway.store.state.sessions, hasLength(1));
    });
  });

  group('connecting an MCP client', () {
    const verifier = 'a-long-random-code-verifier-0123456789-abcdefghijklmnop';
    const redirect = 'https://client.example.com/callback';

    Future<String> register() async {
      final r = await gw.client.post(
        Uri.parse('${gw.base}/oauth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Claude',
          'redirect_uris': [redirect],
          'token_endpoint_auth_method': 'none',
        }),
      );
      return jsonDecode(r.body)['client_id'] as String;
    }

    Map<String, String> params(String clientId) => {
      'client_id': clientId,
      'redirect_uri': redirect,
      'response_type': 'code',
      'code_challenge': pkceS256(verifier),
      'code_challenge_method': 'S256',
      'state': 's',
    };

    String query(Map<String, String> p) => p.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    Future<http.Response> post(
      Map<String, String> fields, {
      String? session,
    }) async {
      final request =
          http.Request('POST', Uri.parse('${gw.base}/oauth/authorize'))
            ..followRedirects = false
            ..headers['content-type'] = 'application/x-www-form-urlencoded'
            ..headers['cookie'] = session == null ? '' : 'mcp_session=$session'
            ..bodyFields = fields;
      return http.Response.fromStream(await gw.client.send(request));
    }

    String csrfIn(String html) =>
        RegExp('name="csrf" value="([^"]+)"').firstMatch(html)!.group(1)!;

    test(
      'shows a GitHub button next to the admin token when signed out',
      () async {
        final id = await register();
        final r = await get('/oauth/authorize?${query(params(id))}');
        expect(r.statusCode, 200);
        expect(r.body, contains('Sign in with GitHub'));
        expect(r.body, contains('/auth/github?return_to='));
        expect(r.body, contains('name="password"'));
      },
    );

    test('the button comes back to the same request', () async {
      final id = await register();
      final r = await get('/oauth/authorize?${query(params(id))}');
      final href = RegExp('href="([^"]+)"').firstMatch(r.body)!.group(1)!;
      final link = Uri.parse(href.replaceAll('&amp;', '&'));
      final back = link.queryParameters['return_to']!;
      expect(back, startsWith('/oauth/authorize?'));
      expect(Uri.parse(back).queryParameters['client_id'], id);
    });

    test('when signed in, asks only to allow or deny', () async {
      final id = await register();
      final session = await sessionFor(ada);
      final r = await get(
        '/oauth/authorize?${query(params(id))}',
        headers: {'cookie': 'mcp_session=$session'},
      );
      expect(r.body, contains('Ada'));
      expect(r.body, isNot(contains('name="password"')));
      expect(r.body, contains('name="csrf"'));
    });

    test('allowing as a member hands the client a code', () async {
      final id = await register();
      final session = await sessionFor(ada);
      final page = await get(
        '/oauth/authorize?${query(params(id))}',
        headers: {'cookie': 'mcp_session=$session'},
      );
      final r = await post({
        ...params(id),
        'decision': 'allow',
        'csrf': csrfIn(page.body),
      }, session: session);
      expect(r.statusCode, 302, reason: r.body);
      final location = Uri.parse(r.headers['location']!);
      expect(location.origin, 'https://client.example.com');
      expect(location.queryParameters['code'], isNotEmpty);
      expect(location.queryParameters['state'], 's');

      final token = await gw.client.post(
        Uri.parse('${gw.base}/oauth/token'),
        body: {
          'grant_type': 'authorization_code',
          'code': location.queryParameters['code']!,
          'client_id': id,
          'redirect_uri': redirect,
          'code_verifier': verifier,
        },
      );
      expect(token.statusCode, 200, reason: token.body);
    });

    test(
      'a cookie alone is not enough: the form must carry the csrf value',
      () async {
        final id = await register();
        final session = await sessionFor(ada);
        final none = await post({
          ...params(id),
          'decision': 'allow',
        }, session: session);
        expect(none.statusCode, 401);
        final wrong = await post({
          ...params(id),
          'decision': 'allow',
          'csrf': 'forged',
        }, session: session);
        expect(wrong.statusCode, 401);
      },
    );

    test(
      'one member\'s csrf value does not work for another session',
      () async {
        final id = await register();
        final adaSession = await sessionFor(ada);
        final page = await get(
          '/oauth/authorize?${query(params(id))}',
          headers: {'cookie': 'mcp_session=$adaSession'},
        );
        await gw.close();
        // Another session of the same server cannot reuse that value.
        gw = await Harness.start(github: github, githubOrgs: ['acme']);
        final id2 = await register();
        final other = await sessionFor(ada);
        final r = await post({
          ...params(id2),
          'decision': 'allow',
          'csrf': csrfIn(page.body),
        }, session: other);
        expect(r.statusCode, 401);
      },
    );

    test('a signed-out browser still needs the admin token', () async {
      final id = await register();
      final r = await post({...params(id), 'decision': 'allow'});
      expect(r.statusCode, 401);
      final ok = await post({
        ...params(id),
        'decision': 'allow',
        'password': adminToken,
      });
      expect(ok.statusCode, 302);
    });

    test('denying needs no sign-in and tells the client', () async {
      final id = await register();
      final r = await post({...params(id), 'decision': 'deny'});
      expect(r.statusCode, 302);
      expect(
        Uri.parse(r.headers['location']!).queryParameters['error'],
        'access_denied',
      );
    });

    test('a removed member can no longer allow clients', () async {
      final id = await register();
      final session = await sessionFor(ada);
      final page = await get(
        '/oauth/authorize?${query(params(id))}',
        headers: {'cookie': 'mcp_session=$session'},
      );
      await gw.admin('DELETE', '/api/members/github:1');
      final r = await post({
        ...params(id),
        'decision': 'allow',
        'csrf': csrfIn(page.body),
      }, session: session);
      expect(r.statusCode, 401);
    });

    test('without GitHub configured the page is as before', () async {
      final plain = await Harness.start();
      addTearDown(plain.close);
      final reg = await plain.client.post(
        Uri.parse('${plain.base}/oauth/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'x',
          'redirect_uris': [redirect],
        }),
      );
      final id = jsonDecode(reg.body)['client_id'] as String;
      final r = await plain.client.get(
        Uri.parse('${plain.base}/oauth/authorize?${query(params(id))}'),
      );
      expect(r.body, isNot(contains('Sign in with GitHub')));
      expect(r.body, contains('name="password"'));
    });
  });
}
