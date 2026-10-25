import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_google.dart';
import 'support/harness.dart';
import 'support/pg.dart';

void main() {
  late FakeGitHub github;
  late FakeGoogle google;
  late Harness gw;

  setUp(() async {
    github = await FakeGitHub.start();
    google = await FakeGoogle.start();
    gw = await Harness.start(
      github: github,
      google: google,
      githubFromEnvironment: false,
    );
  });

  tearDown(() async {
    await gw.close();
    await github.close();
    await google.close();
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

  Future<Map<String, dynamic>> addProvider(Map<String, dynamic> body) =>
      gw.adminJson('POST', '/api/auth/providers', body);

  Future<Map<String, dynamic>> addGoogle({
    List<String> domains = const [],
    List<String> emails = const [],
    String id = 'google',
  }) => addProvider({
    'kind': 'google',
    'id': id,
    'name': 'Google',
    'clientId': 'g-client',
    'clientSecret': 'g-secret',
    'domains': domains,
    'emails': emails,
  });

  Future<Map<String, dynamic>> addGitHub({
    List<String> orgs = const [],
    List<String> users = const [],
    List<String> emails = const [],
  }) => addProvider({
    'kind': 'github',
    'name': 'GitHub',
    'clientId': 'gh-client',
    'clientSecret': 'gh-secret',
    'orgs': orgs,
    'users': users,
    'emails': emails,
  });

  /// A full browser round trip through [id]; returns the callback response.
  Future<http.Response> signIn(String id, String code) async {
    final start = await get('/auth/$id');
    expect(start.statusCode, 302, reason: start.body);
    final state = Uri.parse(
      start.headers['location']!,
    ).queryParameters['state']!;
    return get(
      '/auth/$id/callback?code=$code&state=$state',
      headers: {'cookie': 'mcp_login=${cookieValue(start, 'mcp_login')}'},
    );
  }

  Future<http.Response> asMember(String session, String path) =>
      gw.admin('GET', path, null, {'authorization': 'Bearer $session'});

  group('setting up a provider', () {
    test('keeps the secret write-only', () async {
      final created = await addGoogle(domains: ['example.com']);
      expect(created['hasSecret'], isTrue);
      expect(created.containsKey('clientSecret'), isFalse);
      expect(created['source'], 'database');
      expect(created['callbackUrl'], '${gw.base}/auth/google/callback');

      final list = await gw.admin('GET', '/api/auth/providers');
      expect(list.body, isNot(contains('g-secret')));
      expect(jsonDecode(list.body), hasLength(1));
    });

    test('an update without a secret keeps the stored one', () async {
      await addGoogle(domains: ['example.com']);
      final updated = await gw.adminJson('PUT', '/api/auth/providers/google', {
        'domains': ['other.org'],
      });
      expect(updated['hasSecret'], isTrue);
      expect(updated['domains'], ['other.org']);

      final code = google.codeFor(GoogleUser('s1', 'a@other.org'));
      final r = await signIn('google', code);
      expect(r.statusCode, 302, reason: r.body);
      expect(google.secretsSeen, ['g-secret']);
    });

    test(
      'an empty secret clears it, and that turns the provider off',
      () async {
        await addGoogle(domains: ['example.com']);
        final cleared = await gw.adminJson(
          'PUT',
          '/api/auth/providers/google',
          {'clientSecret': ''},
        );
        expect(cleared['hasSecret'], isFalse);
        expect(cleared['enabled'], isFalse);
        expect((await get('/auth/google')).statusCode, 404);
      },
    );

    test(
      'cleans up the allow-list and refuses what is not an address',
      () async {
        final saved = await addGoogle(
          domains: ['@Example.com', 'example.com', ' '],
          emails: ['Ann@Example.com'],
        );
        expect(saved['domains'], ['example.com']);
        expect(saved['emails'], ['ann@example.com']);

        final bad = await gw.admin('PUT', '/api/auth/providers/google', {
          'emails': ['not-an-address'],
        });
        expect(bad.statusCode, 400);
        final badDomain = await gw.admin('PUT', '/api/auth/providers/google', {
          'domains': ['ann@example.com'],
        });
        expect(badDomain.statusCode, 400);
      },
    );

    test('refuses a bad kind, a taken id and a reserved id', () async {
      expect(
        (await gw.admin('POST', '/api/auth/providers', {
          'kind': 'x',
        })).statusCode,
        400,
      );
      await addGoogle();
      expect(
        (await gw.admin('POST', '/api/auth/providers', {
          'kind': 'google',
          'id': 'google',
        })).statusCode,
        409,
      );
      expect(
        (await gw.admin('POST', '/api/auth/providers', {
          'kind': 'google',
          'id': 'config',
        })).statusCode,
        400,
      );
    });

    test('needs a signed-in member or the admin token', () async {
      final r = await gw.admin('GET', '/api/auth/providers', null, {});
      expect(r.statusCode, 401);
    });

    test('lists what the server environment provides, read-only', () async {
      final env = await Harness.start(github: github, githubOrgs: ['acme']);
      addTearDown(env.close);
      final list = jsonDecode(
        (await env.admin('GET', '/api/auth/providers')).body,
      );
      expect(list, hasLength(1));
      expect(list.single['source'], 'environment');
      expect(list.single['orgs'], ['acme']);
      expect(list.single['hasSecret'], isTrue);
      expect(list.single.containsKey('clientSecret'), isFalse);

      expect(
        (await env.admin('DELETE', '/api/auth/providers/github')).statusCode,
        409,
      );
      expect(
        (await env.admin('PUT', '/api/auth/providers/github', {
          'name': 'x',
        })).statusCode,
        409,
      );
      expect(
        (await env.admin('POST', '/api/auth/providers', {
          'kind': 'github',
          'id': 'github',
        })).statusCode,
        409,
      );
    });
  });

  group('signing in with Google', () {
    test('lets in an address at an allowed domain', () async {
      await addGoogle(domains: ['example.com']);
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s1', 'Ann@Example.com', name: 'Ann')),
      );
      expect(r.statusCode, 302, reason: r.body);
      final session = cookieValue(r, 'mcp_session')!;
      final me = jsonDecode((await asMember(session, '/api/me')).body);
      expect(me['member']['id'], 'google:s1');
      expect(me['member']['name'], 'Ann');
      expect(google.redirectsSeen, ['${gw.base}/auth/google/callback']);
    });

    test('lets in a listed address from any domain', () async {
      await addGoogle(emails: ['bob@gmail.com']);
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s2', 'bob@gmail.com')),
      );
      expect(r.statusCode, 302, reason: r.body);
    });

    test('turns away an address that is not listed', () async {
      await addGoogle(domains: ['example.com'], emails: ['bob@gmail.com']);
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s3', 'eve@evil.com')),
      );
      expect(r.statusCode, 403);
      expect(cookieValue(r, 'mcp_session'), isNull);
    });

    test('does not trust an address Google has not verified', () async {
      await addGoogle(domains: ['example.com']);
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s4', 'ann@example.com', verified: false)),
      );
      expect(r.statusCode, 403);
    });

    test('with an empty allow-list lets nobody in', () async {
      await addGoogle();
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s5', 'ann@example.com')),
      );
      expect(r.statusCode, 403);
    });

    test('a wrong code is refused', () async {
      await addGoogle(domains: ['example.com']);
      final r = await signIn('google', 'nope');
      expect(r.statusCode, 502);
    });

    test('the start sends the browser to Google with the right asks', () async {
      await addGoogle(domains: ['example.com']);
      final start = await get('/auth/google');
      final to = Uri.parse(start.headers['location']!);
      expect(to.path, '/auth');
      expect(to.queryParameters['client_id'], 'g-client');
      expect(to.queryParameters['scope'], 'openid email profile');
      expect(to.queryParameters['response_type'], 'code');
      expect(
        to.queryParameters['redirect_uri'],
        '${gw.base}/auth/google/callback',
      );
    });

    test(
      'a sign-in begun with one provider cannot finish with another',
      () async {
        await addGoogle(domains: ['example.com']);
        await addGitHub(users: ['ada']);
        final start = await get('/auth/google');
        final state = Uri.parse(
          start.headers['location']!,
        ).queryParameters['state']!;
        final code = github.codeFor(GhUser(1, 'ada'));
        final r = await get(
          '/auth/github/callback?code=$code&state=$state',
          headers: {'cookie': 'mcp_login=${cookieValue(start, 'mcp_login')}'},
        );
        expect(r.statusCode, 400);
        expect(cookieValue(r, 'mcp_session'), isNull);
      },
    );
  });

  group('signing in with a GitHub app set up in the dashboard', () {
    test(
      'lets in a listed login, an organisation or a verified email',
      () async {
        await addGitHub(
          orgs: ['acme'],
          users: ['ada'],
          emails: ['grace@navy.mil'],
        );
        Future<int> status(GhUser u) async =>
            (await signIn('github', github.codeFor(u))).statusCode;

        expect(await status(GhUser(1, 'Ada')), 302);
        expect(await status(GhUser(2, 'bob', orgs: ['ACME'])), 302);
        expect(
          await status(GhUser(3, 'grace', emails: [('Grace@Navy.mil', true)])),
          302,
        );
        expect(await status(GhUser(4, 'eve', orgs: ['elsewhere'])), 403);
      },
    );

    test('an unverified email does not count', () async {
      await addGitHub(emails: ['grace@navy.mil']);
      final r = await signIn(
        'github',
        github.codeFor(GhUser(3, 'grace', emails: [('grace@navy.mil', false)])),
      );
      expect(r.statusCode, 403);
    });

    test('a domain on the list lets in anyone verified at it', () async {
      await addProvider({
        'kind': 'github',
        'name': 'GitHub',
        'clientId': 'gh-client',
        'clientSecret': 'gh-secret',
        'domains': ['navy.mil'],
      });
      final r = await signIn(
        'github',
        github.codeFor(GhUser(3, 'grace', emails: [('g@navy.mil', true)])),
      );
      expect(r.statusCode, 302, reason: r.body);
    });
  });

  group('several providers at once', () {
    test('/auth/config lists the ones that are on', () async {
      await addGoogle(domains: ['example.com']);
      await addGitHub(users: ['ada']);
      await addProvider({'kind': 'google', 'id': 'unfinished', 'name': 'Half'});

      final config = jsonDecode((await get('/auth/config')).body);
      expect(config['providers'], [
        {'id': 'google', 'kind': 'google', 'name': 'Google'},
        {'id': 'github', 'kind': 'github', 'name': 'GitHub'},
      ]);
      expect(config['github'], isTrue);
    });

    test('a disabled provider cannot be started', () async {
      await addGoogle(domains: ['example.com']);
      await gw.adminJson('PUT', '/api/auth/providers/google', {
        'enabled': false,
      });
      expect((await get('/auth/google')).statusCode, 404);
      final config = jsonDecode((await get('/auth/config')).body);
      expect(config['providers'], isEmpty);
    });

    test('turning a provider off signs its members out at once', () async {
      await addGoogle(domains: ['example.com']);
      final r = await signIn(
        'google',
        google.codeFor(GoogleUser('s1', 'ann@example.com')),
      );
      final session = cookieValue(r, 'mcp_session')!;
      expect((await asMember(session, '/api/me')).statusCode, 200);

      await gw.adminJson('PUT', '/api/auth/providers/google', {
        'enabled': false,
      });
      expect((await asMember(session, '/api/me')).statusCode, 401);

      await gw.adminJson('PUT', '/api/auth/providers/google', {
        'enabled': true,
      });
      expect((await asMember(session, '/api/me')).statusCode, 200);
    });

    test('taking an address off the list signs that person out', () async {
      await addGoogle(emails: ['ann@example.com', 'bob@example.com']);
      final ann = cookieValue(
        await signIn(
          'google',
          google.codeFor(GoogleUser('a', 'ann@example.com')),
        ),
        'mcp_session',
      )!;
      final bob = cookieValue(
        await signIn(
          'google',
          google.codeFor(GoogleUser('b', 'bob@example.com')),
        ),
        'mcp_session',
      )!;
      await gw.adminJson('PUT', '/api/auth/providers/google', {
        'emails': ['bob@example.com'],
      });
      expect((await asMember(ann, '/api/me')).statusCode, 401);
      expect((await asMember(bob, '/api/me')).statusCode, 200);
    });

    test('deleting a provider removes its members\' sessions', () async {
      await addGoogle(domains: ['example.com']);
      final session = cookieValue(
        await signIn(
          'google',
          google.codeFor(GoogleUser('a', 'ann@example.com')),
        ),
        'mcp_session',
      )!;
      final gone = await gw.admin('DELETE', '/api/auth/providers/google');
      expect(gone.statusCode, 204);
      expect((await asMember(session, '/api/me')).statusCode, 401);
      expect(
        jsonDecode((await gw.admin('GET', '/api/auth/providers')).body),
        isEmpty,
      );
      expect(
        (await gw.admin('DELETE', '/api/auth/providers/google')).statusCode,
        404,
      );
    });

    test(
      'the consent page offers each provider next to the admin token',
      () async {
        await addGoogle(domains: ['example.com']);
        await addGitHub(users: ['ada']);
        final reg = await gw.client.post(
          Uri.parse('${gw.base}/oauth/register'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'client_name': 'Claude',
            'redirect_uris': ['https://claude.example/cb'],
            'token_endpoint_auth_method': 'none',
          }),
        );
        final clientId = jsonDecode(reg.body)['client_id'];
        final page = await get(
          '/oauth/authorize?client_id=$clientId&response_type=code'
          '&redirect_uri=${Uri.encodeQueryComponent('https://claude.example/cb')}'
          '&code_challenge=${'a' * 43}&code_challenge_method=S256&state=x',
        );
        expect(page.statusCode, 200, reason: page.body);
        expect(page.body, contains('Sign in with Google'));
        expect(page.body, contains('Sign in with GitHub'));
        expect(page.body, contains('href="/auth/google?return_to='));
        expect(page.body, contains('href="/auth/github?return_to='));
        expect(page.body, contains('name="password"'));
      },
    );
  });

  group('storage', () {
    late TestDatabase db;
    setUp(() async => db = await TestDatabase.create());
    tearDown(() async => db.drop());

    test(
      'providers and members survive a restart; the secret has its own table',
      () async {
        var server = await Harness.start(databaseUrl: db.url, google: google);
        await server.adminJson('POST', '/api/auth/providers', {
          'kind': 'google',
          'id': 'google',
          'name': 'Google',
          'clientId': 'g-client',
          'clientSecret': 'g-secret',
          'domains': ['example.com'],
        });
        final start = await server.rawGet('/auth/google');
        final state = Uri.parse(
          start.headers['location']!,
        ).queryParameters['state']!;
        final done = await server.rawGet(
          '/auth/google/callback?code=${google.codeFor(GoogleUser('s1', 'ann@example.com'))}&state=$state',
          {'cookie': 'mcp_login=$state'},
        );
        expect(done.statusCode, 302, reason: done.body);
        final session = cookieValue(done, 'mcp_session')!;
        await server.close();

        final c = await db.connect();
        try {
          final provider = (await c.execute(
            'select * from auth_providers',
          )).single.toColumnMap();
          expect(provider['kind'], 'google');
          expect(provider['client_id'], 'g-client');
          expect(provider.values.map((v) => '$v'), isNot(contains('g-secret')));
          final secret = await c.execute('select * from auth_provider_secrets');
          expect(secret.single.toColumnMap().values, contains('g-secret'));
          final member = (await c.execute(
            'select provider, emails from members',
          )).single;
          expect(member[0], 'google');
          expect(member[1], ['ann@example.com']);
        } finally {
          await c.close();
        }

        server = await Harness.start(databaseUrl: db.url, google: google);
        addTearDown(server.close);
        final me = await server.admin('GET', '/api/me', null, {
          'authorization': 'Bearer $session',
        });
        expect(me.statusCode, 200, reason: me.body);
        final again = jsonDecode(
          (await server.admin('GET', '/api/auth/providers')).body,
        );
        expect(again.single['hasSecret'], isTrue);
        expect(again.single['domains'], ['example.com']);
      },
    );
  });
}
