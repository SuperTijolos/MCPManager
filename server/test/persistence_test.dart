import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mcp_portal_server/mcp_portal_server.dart';
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_oauth_upstream.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';
import 'support/pg.dart';

void main() {
  late TestDatabase db;
  late FakeUpstream upstream;

  setUp(() async {
    db = await TestDatabase.create();
    upstream = await FakeUpstream.start(
      tools: [tool('lookup')],
      handlers: {'lookup': (_) => textResult('found')},
    );
  });

  tearDown(() async {
    await upstream.close();
    await db.drop();
  });

  Future<List<Map<String, Object?>>> rows(String sql) async {
    final c = await db.connect();
    try {
      return [for (final r in await c.execute(sql)) r.toColumnMap()];
    } finally {
      await c.close();
    }
  }

  test('servers, portals, tokens and rules survive a restart', () async {
    var gw = await Harness.start(databaseUrl: db.url);
    await gw.addServer(
      'Docs',
      upstream.url,
      id: 'srv',
      headers: {'X-Key': 'secret'},
    );
    await gw.addPortal('Docs', ['srv'], slug: 'docs');
    final token = await gw.addToken('c');
    await gw.adminJson('PUT', '/api/rules', {
      'rules': [],
      'overrides': {
        'srv/other': {'hidden': true},
      },
    });
    await gw.toolNames('docs', token);
    await gw.close();

    gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    expect(await gw.toolNames('docs', token), ['docs__lookup']);
    final server = await gw.adminJson('GET', '/api/servers/srv');
    expect(server['headerNames'], ['X-Key']);
    expect((await gw.adminJson('GET', '/api/rules'))['overrides'], isNotEmpty);
  });

  test('the order of servers and portals is kept', () async {
    var gw = await Harness.start(databaseUrl: db.url);
    for (final n in ['Zulu', 'Alpha', 'Mike']) {
      await gw.addServer(n, upstream.url, id: n.toLowerCase());
    }
    await gw.close();

    gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    final list =
        jsonDecode((await gw.admin('GET', '/api/servers')).body) as List;
    expect(
      [for (final s in list) (s as Map)['name']],
      ['Zulu', 'Alpha', 'Mike'],
    );
  });

  test(
    'upstream credentials live in their own table, not in servers',
    () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await gw.addServer(
        'Docs',
        upstream.url,
        id: 'srv',
        headers: {'Authorization': 'Bearer very-secret'},
      );

      final servers = await rows('select * from servers');
      expect(servers.single['header_names'], ['Authorization']);
      expect('${servers.single}', isNot(contains('very-secret')));
      final creds = await rows('select * from server_credentials');
      expect('${creds.single['headers']}', contains('very-secret'));
    },
  );

  test('deleting a server and a portal removes their rows', () async {
    final gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    await gw.addServer('Docs', upstream.url, id: 'srv');
    final portal = await gw.addPortal('Docs', ['srv'], slug: 'docs');
    expect(await rows('select 1 from portals'), hasLength(1));

    await gw.adminJson('DELETE', '/api/portals/$portal');
    await gw.adminJson('DELETE', '/api/servers/srv');
    expect(await rows('select 1 from portals'), isEmpty);
    expect(await rows('select 1 from servers'), isEmpty);
    expect(await rows('select 1 from server_credentials'), isEmpty);
  });

  test('a slug freed by one server can be taken by another at once', () async {
    final gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    await gw.addServer('Shared', upstream.url, id: 'a');
    await gw.adminJson('DELETE', '/api/servers/a');
    await gw.addServer('Shared', upstream.url, id: 'b');
    final left = await rows('select id, slug from servers');
    expect(left.single, {'id': 'b', 'slug': 'shared'});
  });

  test('changes from many requests at once all land', () async {
    final gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    await Future.wait([
      for (var i = 0; i < 12; i++) gw.addServer('S$i', upstream.url, id: 's$i'),
    ]);
    expect(await rows('select 1 from servers'), hasLength(12));
  });

  test('access tokens keep only a hash, and revoking is stored', () async {
    final gw = await Harness.start(databaseUrl: db.url);
    addTearDown(gw.close);
    final secret = await gw.addToken('client');
    final stored = await rows('select * from access_tokens');
    expect('${stored.single}', isNot(contains(secret)));
    expect(stored.single['hash'], hashOf(secret));
    expect(stored.single['revoked_at'], isNull);

    final id = stored.single['id'];
    await gw.adminJson('DELETE', '/api/tokens/$id');
    expect(
      (await rows('select revoked_at from access_tokens')).single['revoked_at'],
      isNotNull,
    );
  });

  group('the audit log', () {
    test('is stored in a table and read back, newest first', () async {
      var gw = await Harness.start(databaseUrl: db.url);
      await gw.addServer('Docs', upstream.url, id: 'srv');
      await gw.addPortal('Docs', ['srv'], slug: 'docs');
      final token = await gw.addToken('c');
      await gw.callTool('docs', token, 'docs__lookup');
      await gw.callTool('docs', token, 'docs__missing');
      await gw.gateway.audit.flush();
      await gw.close();

      expect(await rows('select 1 from audit_events'), hasLength(2));

      gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      final events =
          (await gw.adminJson('GET', '/api/audit'))['events'] as List;
      expect(events, hasLength(2));
      expect((events.first as Map)['exposedName'], 'docs__missing');
      expect((events.last as Map)['exposedName'], 'docs__lookup');
      expect((events.last as Map)['status'], 'success');
    });

    test('can be filtered by status, portal and text', () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await gw.addServer('Docs', upstream.url, id: 'srv');
      final portal = await gw.addPortal('Docs', ['srv'], slug: 'docs');
      final token = await gw.addToken('c');
      await gw.callTool('docs', token, 'docs__lookup');
      await gw.callTool('docs', token, 'docs__missing');
      await gw.gateway.audit.flush();

      Future<List> ask(String query) async =>
          (await gw.adminJson('GET', '/api/audit?$query'))['events'] as List;
      expect(await ask('status=success'), hasLength(1));
      expect(await ask('status=denied'), hasLength(1));
      expect(await ask('status=error'), isEmpty);
      expect(await ask('portal=$portal'), hasLength(2));
      expect(await ask('portal=nope'), isEmpty);
      expect(await ask('q=LOOKUP'), hasLength(1));
      expect(await ask('limit=1'), hasLength(1));
    });

    test('searching for % or _ matches them literally', () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await gw.addServer('Docs', upstream.url, id: 'srv');
      await gw.addPortal('Docs', ['srv'], slug: 'docs');
      final token = await gw.addToken('c');
      await gw.callTool('docs', token, 'docs__lookup');
      await gw.gateway.audit.flush();

      final all =
          (await gw.adminJson('GET', '/api/audit?q=%25'))['events'] as List;
      expect(all, isEmpty, reason: '% must not act as a wildcard');
      final one =
          (await gw.adminJson('GET', '/api/audit?q=d_cs'))['events'] as List;
      expect(one, isEmpty, reason: '_ must not act as a wildcard');
    });
  });

  group('the admin token', () {
    test('is generated once, shown once, and kept as a hash', () async {
      var gw = await Harness.start(databaseUrl: db.url, token: null);
      final secret = gw.gateway.generatedAdminToken!;
      expect(secret, startsWith('mcpadmin_'));
      expect(
        (await gw.admin(
          'GET',
          '/api/status',
          null,
          gw.adminHeaders(secret),
        )).statusCode,
        200,
      );
      final stored = await rows('select * from settings');
      expect('$stored', isNot(contains(secret)));
      expect(stored.single['key'], 'admin_token_hash');
      await gw.close();

      gw = await Harness.start(databaseUrl: db.url, token: null);
      addTearDown(gw.close);
      expect(gw.gateway.generatedAdminToken, isNull);
      expect(
        (await gw.admin(
          'GET',
          '/api/status',
          null,
          gw.adminHeaders(secret),
        )).statusCode,
        200,
      );
      expect(
        (await gw.admin(
          'GET',
          '/api/status',
          null,
          gw.adminHeaders('wrong-wrong-wrong-wrong'),
        )).statusCode,
        401,
      );
    });

    test('a configured token wins and must be long enough', () async {
      expect(
        () => GatewayServer.create(
          GatewayConfig(port: 0, databaseUrl: db.url, adminToken: 'short'),
        ),
        throwsA(isA<ArgumentError>()),
      );
      final gw = await Harness.start(
        databaseUrl: db.url,
        token: 'a-configured-admin-token-1234',
      );
      addTearDown(gw.close);
      expect(gw.gateway.generatedAdminToken, isNull);
      expect(
        (await gw.admin(
          'GET',
          '/api/status',
          null,
          gw.adminHeaders('a-configured-admin-token-1234'),
        )).statusCode,
        200,
      );
    });
  });

  group('the database', () {
    test('is migrated once, however often the server starts', () async {
      for (var i = 0; i < 3; i++) {
        final gw = await Harness.start(databaseUrl: db.url);
        await gw.close();
      }
      final done = await rows('select version from schema_migrations');
      expect(
        [for (final d in done) d['version']],
        [
          '20261023000000_init',
          '20261024000000_sessions',
          '20261025000000_audit_conversation',
          '20261026000000_upstream_oauth',
          '20261027000000_chats',
          '20261028000000_llm_providers',
          '20261029000000_audit_kinds',
          '20261030000000_auth_providers',
          '20261031000000_roles_invites',
        ],
      );
    });

    test('two servers starting together do not collide', () async {
      final starts = await Future.wait([
        for (var i = 0; i < 3; i++) Harness.start(databaseUrl: db.url),
      ]);
      for (final gw in starts) {
        await gw.close();
      }
      expect(await rows('select 1 from schema_migrations'), hasLength(9));
    });

    test('creates every table the server needs', () async {
      await (await Harness.start(databaseUrl: db.url)).close();
      final tables = {
        for (final r in await rows(
          "select tablename from pg_tables where schemaname = 'public'",
        ))
          r['tablename'],
      };
      expect(
        tables,
        containsAll([
          'servers',
          'server_credentials',
          'portals',
          'access_tokens',
          'oauth_clients',
          'oauth_grants',
          'tool_rules',
          'tool_overrides',
          'audit_events',
          'members',
          'sessions',
          'chats',
          'chat_content',
          'llm_providers',
          'llm_provider_secrets',
          'auth_providers',
          'auth_provider_secrets',
          'roles',
          'invites',
          'settings',
        ]),
      );
    });

    test('is required to run', () async {
      expect(
        () => GatewayServer.create(GatewayConfig(port: 0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an unreachable database fails to start instead of hanging', () async {
      await expectLater(
        GatewayServer.create(
          GatewayConfig(
            port: 0,
            databaseUrl:
                'postgresql://postgres:x@127.0.0.1:1/none?sslmode=disable',
          ),
        ).timeout(const Duration(seconds: 20)),
        throwsA(isA<Object>()),
      );
    });
  });

  group('sign-in', () {
    late FakeGitHub github;

    setUp(() async => github = await FakeGitHub.start());
    tearDown(() => github.close());

    Future<String> signIn(Harness gw) async {
      Future<http.Response> get(String path, [Map<String, String>? h]) async {
        final r = http.Request('GET', Uri.parse('${gw.base}$path'))
          ..followRedirects = false
          ..headers.addAll(h ?? {});
        return http.Response.fromStream(await gw.client.send(r));
      }

      final code = github.codeFor(GhUser(7, 'ada', orgs: ['acme']));
      final start = await get('/auth/github');
      final state = Uri.parse(
        start.headers['location']!,
      ).queryParameters['state']!;
      final done = await get('/auth/github/callback?code=$code&state=$state', {
        'cookie': 'mcp_login=$state',
      });
      return RegExp(
        'mcp_session=([^;,]+)',
      ).firstMatch(done.headers['set-cookie']!)!.group(1)!;
    }

    test(
      'members and sessions survive a restart, and only a hash is kept',
      () async {
        var gw = await Harness.start(
          databaseUrl: db.url,
          github: github,
          githubOrgs: ['acme'],
        );
        final session = await signIn(gw);
        await gw.close();

        final members = await rows('select * from members');
        expect(members.single['login'], 'ada');
        expect(members.single['orgs'], ['acme']);
        final sessions = await rows('select * from sessions');
        expect(sessions.single['member_id'], 'github:7');
        expect('$sessions', isNot(contains(session)));
        expect(sessions.single['hash'], hashOf(session));

        gw = await Harness.start(
          databaseUrl: db.url,
          github: github,
          githubOrgs: ['acme'],
        );
        addTearDown(gw.close);
        final me = await gw.admin('GET', '/api/me', null, {
          'authorization': 'Bearer $session',
        });
        expect(me.statusCode, 200, reason: 'still signed in after a restart');
      },
    );

    test('removing a member removes their sessions', () async {
      final gw = await Harness.start(
        databaseUrl: db.url,
        github: github,
        githubOrgs: ['acme'],
      );
      addTearDown(gw.close);
      await signIn(gw);
      await gw.admin('DELETE', '/api/members/github:7');
      expect(await rows('select 1 from members'), isEmpty);
      expect(await rows('select 1 from sessions'), isEmpty);
    });
  });

  group('upstream sign-in', () {
    late FakeOAuthUpstream oauth;

    setUp(() async => oauth = await FakeOAuthUpstream.start());
    tearDown(() => oauth.close());

    Future<void> signIn(Harness gw) async {
      await gw.adminJson('PUT', '/api/servers/srv', {
        'name': 'OAuth',
        'url': oauth.url,
        'transport': 'streamable-http',
        'oauth': true,
        'oauthScope': 'read',
      });
      final start = await gw.adminJson(
        'POST',
        '/api/servers/srv/oauth/start',
        {},
      );
      final back = oauth.approve(Uri.parse(start['authorizeUrl'] as String));
      final r = await gw.rawGet('${back.path}?${back.query}');
      expect(r.statusCode, 200, reason: r.body);
    }

    test('tokens survive a restart and keep working', () async {
      var gw = await Harness.start(databaseUrl: db.url);
      await signIn(gw);
      await gw.close();

      final stored = await rows('select * from server_oauth');
      expect(stored.single['server_id'], 'srv');
      expect('${stored.single['session']}', contains('at-'));
      final server = await rows('select oauth, oauth_scope from servers');
      expect(server.single, {'oauth': true, 'oauth_scope': 'read'});

      gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      final status = await gw.adminJson('GET', '/api/servers/srv/oauth');
      expect(status['signedIn'], isTrue);
      final call = await gw.adminJson('POST', '/api/servers/srv/call', {
        'tool': 'whoami',
      });
      expect(call['text'], startsWith('token:at-'));
    });

    test('a refreshed token is stored', () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await signIn(gw);
      final before =
          '${(await rows('select session from server_oauth')).single['session']}';
      gw.clock.advance(const Duration(hours: 2));
      await gw.adminJson('POST', '/api/servers/srv/call', {'tool': 'whoami'});
      final after =
          '${(await rows('select session from server_oauth')).single['session']}';
      expect(after, isNot(before));
      expect(oauth.refreshCount, 1);
    });

    test('deleting the server removes the tokens', () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await signIn(gw);
      await gw.adminJson('DELETE', '/api/servers/srv');
      expect(await rows('select 1 from server_oauth'), isEmpty);
    });
  });

  group('language-model providers', () {
    test(
      'are stored with the key in its own table, and survive a restart',
      () async {
        var gw = await Harness.start(databaseUrl: db.url);
        await gw.adminJson('PUT', '/api/llm/providers/p1', {
          'name': 'Cloud',
          'kind': 'openaiCompatible',
          'baseUrl': 'https://api.example.com/v1',
          'apiKey': 'sk-test-key-0123456789',
          'models': ['m1', 'm2'],
          'contextLength': 32000,
        });
        await gw.adminJson('PUT', '/api/llm/providers/p2', {
          'name': 'Local',
          'kind': 'ollama',
          'baseUrl': 'http://localhost:11434',
        });
        await gw.close();

        final providers = await rows(
          'select * from llm_providers order by position',
        );
        expect([for (final p in providers) p['id']], ['p1', 'p2']);
        expect(providers.first['models'], ['m1', 'm2']);
        expect(providers.first['context_length'], 32000);
        expect('$providers', isNot(contains('sk-test-key')));
        final secrets = await rows('select * from llm_provider_secrets');
        expect(secrets.single, {
          'provider_id': 'p1',
          'api_key': 'sk-test-key-0123456789',
        });

        gw = await Harness.start(databaseUrl: db.url);
        addTearDown(gw.close);
        final list =
            jsonDecode((await gw.admin('GET', '/api/llm/providers')).body)
                as List;
        expect([for (final p in list) p['name']], ['Cloud', 'Local']);
        expect(list.first['hasKey'], isTrue);
        expect(list.last['hasKey'], isFalse);
      },
    );

    test('removing the key or the provider removes the secret', () async {
      final gw = await Harness.start(databaseUrl: db.url);
      addTearDown(gw.close);
      await gw.adminJson('PUT', '/api/llm/providers/p1', {
        'name': 'Cloud',
        'kind': 'openaiCompatible',
        'baseUrl': 'https://api.example.com/v1',
        'apiKey': 'sk-test-key-0123456789',
      });
      await gw.adminJson('PUT', '/api/llm/providers/p1', {'clearApiKey': true});
      expect(await rows('select 1 from llm_provider_secrets'), isEmpty);
      await gw.adminJson('PUT', '/api/llm/providers/p1', {
        'apiKey': 'sk-test-key-0123456789',
      });
      await gw.admin('DELETE', '/api/llm/providers/p1');
      expect(await rows('select 1 from llm_provider_secrets'), isEmpty);
      expect(await rows('select 1 from llm_providers'), isEmpty);
    });
  });
}
