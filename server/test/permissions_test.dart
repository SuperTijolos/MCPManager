import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_google.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';
import 'support/pg.dart';
import 'support/sse.dart';

void main() {
  late FakeGitHub github;
  late FakeGoogle google;
  late FakeUpstream upstream;
  late Harness gw;
  late String portalOne;

  /// Everyone who comes in through GitHub's `acme` list starts as a viewer.
  setUp(() async {
    github = await FakeGitHub.start();
    google = await FakeGoogle.start();
    upstream = await FakeUpstream.start(
      tools: [tool('lookup')],
      handlers: {'lookup': (_) => textResult('found')},
    );
    gw = await Harness.start(
      github: github,
      google: google,
      githubOrgs: ['acme'],
      defaultRole: 'viewer',
    );
    await gw.addServer('Alpha', upstream.url, id: 'a');
    await gw.addServer('Beta', upstream.url, id: 'b');
    portalOne = await gw.addPortal('One', ['a'], slug: 'one');
  });

  tearDown(() async {
    await gw.close();
    await github.close();
    await google.close();
    await upstream.close();
  });

  var nextUser = 100;

  Future<http.Response> get(String path, {Map<String, String>? headers}) async {
    final request = http.Request('GET', Uri.parse('${gw.base}$path'))
      ..followRedirects = false
      ..headers.addAll(headers ?? {});
    return http.Response.fromStream(await gw.client.send(request));
  }

  String? cookieValue(http.Response r, String name) => RegExp(
    '$name=([^;,\\s]*)',
  ).firstMatch(r.headers['set-cookie'] ?? '')?.group(1);

  /// Signs in through [id] with [code] after following [startPath].
  Future<http.Response> browser(
    String startPath,
    String id,
    String code,
  ) async {
    final start = await get(startPath);
    expect(start.statusCode, 302, reason: start.body);
    final state = Uri.parse(
      start.headers['location']!,
    ).queryParameters['state']!;
    return get(
      '/auth/$id/callback?code=$code&state=$state',
      headers: {'cookie': 'mcp_login=${cookieValue(start, 'mcp_login')}'},
    );
  }

  /// A new GitHub member of `acme`; returns their id and session token.
  Future<({String id, String session})> member([String? login]) async {
    final n = nextUser++;
    final user = GhUser(n, login ?? 'user$n', orgs: ['acme']);
    final r = await browser('/auth/github', 'github', github.codeFor(user));
    expect(r.statusCode, 302, reason: r.body);
    return (id: 'github:$n', session: cookieValue(r, 'mcp_session')!);
  }

  Future<http.Response> as(
    String session,
    String method,
    String path, [
    Object? body,
  ]) => gw.admin(method, path, body, {
    'authorization': 'Bearer $session',
    'content-type': 'application/json',
  });

  Future<void> setRole(
    String id,
    String role, {
    Object? servers = 'keep',
    Object? portals = 'keep',
  }) async {
    final r = await gw.admin('PUT', '/api/members/$id', {
      'role': role,
      if (servers != 'keep') 'serverIds': servers,
      if (portals != 'keep') 'portalIds': portals,
    });
    expect(r.statusCode, 200, reason: r.body);
  }

  Future<void> addGoogleProvider({
    List<String> domains = const [],
    String defaultRole = 'viewer',
  }) async {
    final r = await gw.admin('POST', '/api/auth/providers', {
      'kind': 'google',
      'id': 'google',
      'name': 'Google',
      'clientId': 'g-client',
      'clientSecret': 'g-secret',
      'domains': domains,
      'defaultRole': defaultRole,
    });
    expect(r.statusCode, 201, reason: r.body);
  }

  dynamic json(http.Response r) => jsonDecode(r.body);

  group('roles', () {
    test(
      'the built-in roles and the permission catalogue are listed',
      () async {
        final roles = json(await gw.admin('GET', '/api/roles')) as List;
        expect(
          [for (final r in roles) r['id']],
          ['admin', 'operator', 'viewer'],
        );
        expect(roles.every((r) => r['builtin'] == true), isTrue);
        final admin = roles.first;
        final catalogue =
            json(await gw.admin('GET', '/api/permissions')) as List;
        expect(admin['permissions'], hasLength(catalogue.length));
      },
    );

    test('/api/me says what the caller may do', () async {
      final admin = json(await gw.admin('GET', '/api/me'));
      expect(admin['access']['permissions'], contains('members.manage'));
      expect(admin['access']['serverIds'], isNull);

      final m = await member();
      final me = json(await as(m.session, 'GET', '/api/me'));
      expect(me['member']['role'], 'viewer');
      expect(me['access']['permissions'], contains('servers.view'));
      expect(me['access']['permissions'], isNot(contains('servers.manage')));
    });

    test('a custom role can be made, changed and deleted', () async {
      final created = await gw.admin('POST', '/api/roles', {
        'name': 'Auditor',
        'description': 'Reads logs',
        'permissions': ['audit.view', 'servers.view'],
      });
      expect(created.statusCode, 201, reason: created.body);
      expect(json(created)['id'], 'auditor');

      final changed = await gw.admin('PUT', '/api/roles/auditor', {
        'permissions': ['audit.view'],
      });
      expect(json(changed)['permissions'], ['audit.view']);

      expect((await gw.admin('DELETE', '/api/roles/auditor')).statusCode, 204);
      expect((await gw.admin('GET', '/api/roles/auditor')).statusCode, 404);
    });

    test('built-in roles cannot be changed or deleted', () async {
      expect(
        (await gw.admin('PUT', '/api/roles/viewer', {
          'permissions': [],
        })).statusCode,
        409,
      );
      expect((await gw.admin('DELETE', '/api/roles/admin')).statusCode, 409);
      expect(
        (await gw.admin('POST', '/api/roles', {
          'name': 'Admin',
          'permissions': [],
        })).statusCode,
        409,
        reason: 'the id is taken',
      );
    });

    test('refuses unknown permissions', () async {
      final r = await gw.admin('POST', '/api/roles', {
        'name': 'Odd',
        'permissions': ['servers.view', 'servers.explode'],
      });
      expect(r.statusCode, 400);
      expect(r.body, contains('servers.explode'));
    });

    test('a role in use cannot be deleted', () async {
      await gw.admin('POST', '/api/roles', {
        'name': 'Auditor',
        'permissions': ['audit.view'],
      });
      final m = await member();
      await setRole(m.id, 'auditor');
      expect((await gw.admin('DELETE', '/api/roles/auditor')).statusCode, 409);
      await setRole(m.id, 'viewer');
      expect((await gw.admin('DELETE', '/api/roles/auditor')).statusCode, 204);
    });
  });

  group('permissions on the API', () {
    test('a viewer reads, but changes nothing', () async {
      final m = await member();
      expect((await as(m.session, 'GET', '/api/servers')).statusCode, 200);
      expect((await as(m.session, 'GET', '/api/portals')).statusCode, 200);
      expect((await as(m.session, 'GET', '/api/tools')).statusCode, 200);
      expect((await as(m.session, 'GET', '/api/audit')).statusCode, 200);
      expect((await as(m.session, 'GET', '/api/status')).statusCode, 200);

      for (final (method, path) in [
        ('POST', '/api/servers'),
        ('PUT', '/api/servers/a'),
        ('DELETE', '/api/servers/a'),
        ('POST', '/api/servers/a/call'),
        ('POST', '/api/portals'),
        ('DELETE', '/api/portals/x'),
        ('GET', '/api/tokens'),
        ('POST', '/api/tokens'),
        ('PUT', '/api/rules'),
        ('GET', '/api/chats'),
        ('GET', '/api/llm/providers'),
        ('POST', '/api/llm/providers'),
        ('GET', '/api/members'),
        ('GET', '/api/roles'),
        ('GET', '/api/invites'),
        ('POST', '/api/invites'),
        ('GET', '/api/auth/providers'),
        ('POST', '/api/audit/delete'),
      ]) {
        final r = await as(m.session, method, path, {});
        expect(r.statusCode, 403, reason: '$method $path → ${r.body}');
        expect(json(r)['error'], 'forbidden');
      }
      expect(await gw.admin('GET', '/api/servers').then(json), hasLength(2));
    });

    test('an operator runs the gateway but not access', () async {
      final m = await member();
      await setRole(m.id, 'operator');
      final made = await as(m.session, 'POST', '/api/servers', {
        'name': 'Gamma',
        'url': upstream.url,
        'transport': 'streamable-http',
      });
      expect(made.statusCode, 201, reason: made.body);
      expect(
        (await as(m.session, 'POST', '/api/servers/a/call', {
          'tool': 'lookup',
          'arguments': {},
        })).statusCode,
        200,
      );
      expect(
        (await as(m.session, 'POST', '/api/tokens', {
          'name': 't',
          'portalIds': [portalOne],
        })).statusCode,
        201,
      );
      for (final (method, path) in [
        ('GET', '/api/members'),
        ('POST', '/api/roles'),
        ('GET', '/api/auth/providers'),
        ('POST', '/api/llm/providers'),
        ('POST', '/api/audit/delete'),
      ]) {
        expect(
          (await as(m.session, method, path, {})).statusCode,
          403,
          reason: '$method $path',
        );
      }
    });

    test('changing a role applies at once', () async {
      final m = await member();
      expect((await as(m.session, 'POST', '/api/portals', {})).statusCode, 403);
      await gw.admin('POST', '/api/roles', {
        'name': 'Builder',
        'permissions': ['portals.view', 'portals.manage'],
      });
      await setRole(m.id, 'builder');
      final r = await as(m.session, 'POST', '/api/portals', {
        'name': 'Two',
        'servers': ['a'],
      });
      expect(r.statusCode, 201, reason: r.body);
      await gw.admin('PUT', '/api/roles/builder', {
        'permissions': ['portals.view'],
      });
      expect(
        (await as(m.session, 'POST', '/api/portals', {
          'name': 'Three',
        })).statusCode,
        403,
      );
    });

    test('a role that no longer exists grants nothing', () async {
      final m = await member();
      final r = await gw.admin('PUT', '/api/members/${m.id}', {'role': 'nope'});
      expect(r.statusCode, 400);
    });

    test('the admin token can do everything', () async {
      expect((await gw.admin('GET', '/api/members')).statusCode, 200);
      expect((await gw.admin('GET', '/api/auth/providers')).statusCode, 200);
    });
  });

  group('scope', () {
    test('limits the servers a member sees and uses', () async {
      final m = await member();
      await setRole(m.id, 'operator', servers: ['a']);

      final servers = json(await as(m.session, 'GET', '/api/servers')) as List;
      expect([for (final s in servers) s['id']], ['a']);
      final tools = json(await as(m.session, 'GET', '/api/tools'));
      expect(
        [for (final s in tools['servers']) s['serverId'] ?? s['id']],
        ['a'],
      );

      expect((await as(m.session, 'GET', '/api/servers/b')).statusCode, 404);
      expect(
        (await as(m.session, 'POST', '/api/servers/b/call', {
          'tool': 'lookup',
          'arguments': {},
        })).statusCode,
        404,
      );
      expect(
        (await as(m.session, 'POST', '/api/servers/a/call', {
          'tool': 'lookup',
          'arguments': {},
        })).statusCode,
        200,
      );
      expect((await as(m.session, 'DELETE', '/api/servers/b')).statusCode, 404);
    });

    test('health only shows the servers in scope', () async {
      final m = await member();
      await setRole(m.id, 'viewer', servers: ['b']);
      await gw.admin('POST', '/api/health/check');
      final health = json(await as(m.session, 'GET', '/api/health'));
      expect((health['servers'] as Map).keys, ['b']);
    });

    test(
      'a scoped member cannot create servers or see the audit log',
      () async {
        final m = await member();
        await setRole(m.id, 'operator', servers: ['a']);
        final made = await as(m.session, 'POST', '/api/servers', {
          'name': 'New',
          'url': upstream.url,
          'transport': 'streamable-http',
        });
        expect(made.statusCode, 403);
        expect((await as(m.session, 'GET', '/api/audit')).statusCode, 403);
        expect((await as(m.session, 'PUT', '/api/rules', {})).statusCode, 403);
      },
    );

    test('limits the portals a member sees', () async {
      await gw.addPortal('Two', ['b'], slug: 'two');
      final m = await member();
      await setRole(m.id, 'operator', portals: [portalOne]);
      final portals = json(await as(m.session, 'GET', '/api/portals')) as List;
      expect([for (final p in portals) p['slug']], ['one']);
      final two = json(await gw.admin('GET', '/api/portals')) as List;
      final twoId = two.firstWhere((p) => p['slug'] == 'two')['id'];
      expect(
        (await as(m.session, 'GET', '/api/portals/$twoId')).statusCode,
        404,
      );
    });

    test('only existing servers can be named', () async {
      final m = await member();
      final r = await gw.admin('PUT', '/api/members/${m.id}', {
        'serverIds': ['ghost'],
      });
      expect(r.statusCode, 400);
    });

    test('null means all again', () async {
      final m = await member();
      await setRole(m.id, 'viewer', servers: ['a']);
      await setRole(m.id, 'viewer', servers: null);
      expect(json(await as(m.session, 'GET', '/api/servers')), hasLength(2));
    });
  });

  group('managing members', () {
    late ({String id, String session}) manager;

    setUp(() async {
      await gw.admin('POST', '/api/roles', {
        'name': 'Manager',
        'permissions': [
          'members.view',
          'members.manage',
          'servers.view',
          'tools.view',
          'portals.view',
          'audit.view',
        ],
      });
      manager = await member('manager');
      await setRole(manager.id, 'manager');
    });

    test('lists members with their role and scope', () async {
      final list =
          json(await as(manager.session, 'GET', '/api/members')) as List;
      expect(list.single['role'], 'manager');
      expect(list.single['serverIds'], isNull);
    });

    test('cannot hand out more than they have', () async {
      final other = await member();
      final r = await as(manager.session, 'PUT', '/api/members/${other.id}', {
        'role': 'operator',
      });
      expect(r.statusCode, 403);
      expect(json(r)['error'], 'cannot_grant');
      final ok = await as(manager.session, 'PUT', '/api/members/${other.id}', {
        'role': 'viewer',
        'serverIds': ['a'],
      });
      expect(ok.statusCode, 200, reason: ok.body);
    });

    test('cannot touch themselves', () async {
      for (final method in ['PUT', 'DELETE']) {
        final r = await as(
          manager.session,
          method,
          '/api/members/${manager.id}',
          {'role': 'viewer'},
        );
        expect(r.statusCode, 409, reason: method);
        expect(json(r)['error'], 'cannot_edit_self');
      }
    });

    test('cannot touch someone who can do more', () async {
      final boss = await member('boss');
      await setRole(boss.id, 'admin');
      for (final method in ['PUT', 'DELETE']) {
        final r = await as(manager.session, method, '/api/members/${boss.id}', {
          'role': 'viewer',
        });
        expect(r.statusCode, 403, reason: method);
        expect(json(r)['error'], 'cannot_edit_higher');
      }
    });

    test('can remove someone beneath them, which signs them out', () async {
      final other = await member();
      final r = await as(manager.session, 'DELETE', '/api/members/${other.id}');
      expect(r.statusCode, 204);
      expect((await as(other.session, 'GET', '/api/me')).statusCode, 401);
    });

    test('cannot lift a limit they are under', () async {
      await gw.admin('PUT', '/api/members/${manager.id}', {
        'serverIds': ['a'],
      });
      final other = await member();
      final r = await as(manager.session, 'PUT', '/api/members/${other.id}', {
        'role': 'viewer',
        'serverIds': null,
      });
      expect(r.statusCode, 403);
      final ok = await as(manager.session, 'PUT', '/api/members/${other.id}', {
        'role': 'viewer',
        'serverIds': ['a'],
      });
      expect(ok.statusCode, 200, reason: ok.body);
    });

    test('cannot make a role that can do more than they can', () async {
      await gw.admin('PUT', '/api/roles/manager', {
        'permissions': ['members.view', 'members.manage', 'roles.manage'],
      });
      final r = await as(manager.session, 'POST', '/api/roles', {
        'name': 'Big',
        'permissions': ['roles.manage', 'audit.manage'],
      });
      expect(r.statusCode, 403);
      expect(json(r)['error'], 'cannot_grant');
      final ok = await as(manager.session, 'POST', '/api/roles', {
        'name': 'Small',
        'permissions': ['roles.manage'],
      });
      expect(ok.statusCode, 201, reason: ok.body);
    });
  });

  group('invitations', () {
    Future<Map<String, dynamic>> invite(Map<String, dynamic> body) async {
      final r = await gw.admin('POST', '/api/invites', body);
      expect(r.statusCode, 201, reason: r.body);
      return json(r) as Map<String, dynamic>;
    }

    test('a link shows who is invited and how to join', () async {
      await addGoogleProvider();
      final i = await invite({'role': 'operator', 'email': 'ann@example.com'});
      expect(i['url'], startsWith('${gw.base}/auth/invite/mcpi_'));
      expect(i['status'], 'pending');

      final page = await get(Uri.parse(i['url'] as String).path);
      expect(page.statusCode, 200);
      expect(page.body, contains('Operator'));
      expect(page.body, contains('ann@example.com'));
      expect(page.body, contains('Join with Google'));
      expect(page.body, contains('Join with GitHub'));
      expect(page.body, contains('href="/auth/google?invite=mcpi_'));
    });

    test('the token is shown once and only its hash is kept', () async {
      final i = await invite({'role': 'viewer'});
      final list = await gw.admin('GET', '/api/invites');
      expect(list.body, isNot(contains(i['token'] as String)));
      expect(json(list).single.containsKey('token'), isFalse);
    });

    test('someone not on any list gets in with the link', () async {
      await addGoogleProvider(domains: ['nowhere.org']);
      final i = await invite({
        'role': 'operator',
        'serverIds': ['a'],
        'portalIds': null,
      });
      final token = i['token'];
      final r = await browser(
        '/auth/google?invite=$token',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com', name: 'Ann')),
      );
      expect(r.statusCode, 302, reason: r.body);
      final session = cookieValue(r, 'mcp_session')!;

      final me = json(await as(session, 'GET', '/api/me'));
      expect(me['member']['role'], 'operator');
      expect(me['member']['serverIds'], ['a']);
      expect(me['member']['viaInvite'], isTrue);
      expect(json(await as(session, 'GET', '/api/servers')), hasLength(1));
    });

    test('an invitation works once', () async {
      await addGoogleProvider();
      final i = await invite({'role': 'viewer'});
      final first = await browser(
        '/auth/google?invite=${i['token']}',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      expect(first.statusCode, 302);
      final list = json(await gw.admin('GET', '/api/invites')) as List;
      expect(list.single['status'], 'used');
      expect(list.single['usedBy'], 'google:g1');

      final again = await get('/auth/google?invite=${i['token']}');
      expect(again.statusCode, 400);
      expect((await get(Uri.parse(i['url'] as String).path)).statusCode, 404);
    });

    test('an invitation for an email needs that verified email', () async {
      await addGoogleProvider();
      final i = await invite({'role': 'viewer', 'email': 'ann@example.com'});
      final wrong = await browser(
        '/auth/google?invite=${i['token']}',
        'google',
        google.codeFor(GoogleUser('g2', 'eve@example.com')),
      );
      expect(wrong.statusCode, 403);
      expect(wrong.body, contains('ann@example.com'));

      final unverified = await browser(
        '/auth/google?invite=${i['token']}',
        'google',
        google.codeFor(GoogleUser('g3', 'ann@example.com', verified: false)),
      );
      expect(unverified.statusCode, 403);

      final right = await browser(
        '/auth/google?invite=${i['token']}',
        'google',
        google.codeFor(GoogleUser('g4', 'Ann@Example.com')),
      );
      expect(right.statusCode, 302, reason: right.body);
    });

    test('an email invitation needs no link at all', () async {
      await addGoogleProvider();
      await invite({'role': 'operator', 'email': 'ann@example.com'});
      final r = await browser(
        '/auth/google',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      expect(r.statusCode, 302, reason: r.body);
      final me = json(
        await as(cookieValue(r, 'mcp_session')!, 'GET', '/api/me'),
      );
      expect(me['member']['role'], 'operator');
      // Someone else with another address is still turned away.
      final eve = await browser(
        '/auth/google',
        'google',
        google.codeFor(GoogleUser('g2', 'eve@example.com')),
      );
      expect(eve.statusCode, 403);
    });

    test('an invited member stays in until removed', () async {
      await addGoogleProvider(domains: ['nowhere.org']);
      final i = await invite({'role': 'viewer'});
      final r = await browser(
        '/auth/google?invite=${i['token']}',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      final session = cookieValue(r, 'mcp_session')!;
      expect((await as(session, 'GET', '/api/me')).statusCode, 200);

      // Signing in again later works without the link.
      final again = await browser(
        '/auth/google',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      expect(again.statusCode, 302);

      await gw.admin('DELETE', '/api/members/google:g1');
      expect((await as(session, 'GET', '/api/me')).statusCode, 401);
      final gone = await browser(
        '/auth/google',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      expect(gone.statusCode, 403, reason: 'no invitation, not on the list');
    });

    test(
      'turning the provider off still locks an invited member out',
      () async {
        await addGoogleProvider();
        final i = await invite({'role': 'viewer'});
        final r = await browser(
          '/auth/google?invite=${i['token']}',
          'google',
          google.codeFor(GoogleUser('g1', 'ann@example.com')),
        );
        final session = cookieValue(r, 'mcp_session')!;
        await gw.admin('PUT', '/api/auth/providers/google', {'enabled': false});
        expect((await as(session, 'GET', '/api/me')).statusCode, 401);
      },
    );

    test('an expired invitation is refused', () async {
      await addGoogleProvider();
      final i = await invite({'role': 'viewer', 'expiresInDays': 1});
      gw.clock.advance(const Duration(days: 2));
      expect((await get('/auth/google?invite=${i['token']}')).statusCode, 400);
      expect((await get(Uri.parse(i['url'] as String).path)).statusCode, 404);
      final list = json(await gw.admin('GET', '/api/invites')) as List;
      expect(list.single['status'], 'expired');
    });

    test('a revoked invitation is refused', () async {
      await addGoogleProvider();
      final i = await invite({'role': 'viewer'});
      expect(
        (await gw.admin('DELETE', '/api/invites/${i['id']}')).statusCode,
        204,
      );
      expect((await get('/auth/google?invite=${i['token']}')).statusCode, 400);
    });

    test('a made-up token is refused', () async {
      expect((await get('/auth/invite/mcpi_nothing')).statusCode, 404);
      expect((await get('/auth/github?invite=mcpi_nothing')).statusCode, 400);
    });

    test('an existing member invited again gets the new role', () async {
      final m = await member();
      final i = await invite({'role': 'operator'});
      final r = await browser(
        '/auth/github?invite=${i['token']}',
        'github',
        github.codeFor(
          GhUser(int.parse(m.id.split(':')[1]), 'user', orgs: ['acme']),
        ),
      );
      expect(r.statusCode, 302, reason: r.body);
      final me = json(
        await as(cookieValue(r, 'mcp_session')!, 'GET', '/api/me'),
      );
      expect(me['member']['role'], 'operator');
    });

    test('can only be made for a role the inviter may give', () async {
      await gw.admin('POST', '/api/roles', {
        'name': 'Inviter',
        'permissions': ['members.view', 'members.manage'],
      });
      final m = await member();
      await setRole(m.id, 'inviter');
      final r = await as(m.session, 'POST', '/api/invites', {'role': 'admin'});
      expect(r.statusCode, 403);
      final ok = await as(m.session, 'POST', '/api/invites', {
        'role': 'inviter',
      });
      expect(ok.statusCode, 201, reason: ok.body);
    });

    test('validates the role, email and scope', () async {
      for (final body in [
        {'role': 'nope'},
        {'role': 'viewer', 'email': 'not-an-email'},
        {
          'role': 'viewer',
          'serverIds': ['ghost'],
        },
        {'role': 'viewer', 'returnTo': 'https://evil.example/'},
      ]) {
        expect(
          (await gw.admin('POST', '/api/invites', body)).statusCode,
          400,
          reason: '$body',
        );
      }
    });

    test('a role with a pending invitation cannot be deleted', () async {
      await gw.admin('POST', '/api/roles', {
        'name': 'Temp',
        'permissions': ['audit.view'],
      });
      final i = await invite({'role': 'temp'});
      expect((await gw.admin('DELETE', '/api/roles/temp')).statusCode, 409);
      await gw.admin('DELETE', '/api/invites/${i['id']}');
      expect((await gw.admin('DELETE', '/api/roles/temp')).statusCode, 204);
    });
  });

  group('default roles', () {
    test('the list of a provider gives its default role', () async {
      await addGoogleProvider(
        domains: ['example.com'],
        defaultRole: 'operator',
      );
      final r = await browser(
        '/auth/google',
        'google',
        google.codeFor(GoogleUser('g1', 'ann@example.com')),
      );
      final me = json(
        await as(cookieValue(r, 'mcp_session')!, 'GET', '/api/me'),
      );
      expect(me['member']['role'], 'operator');
      expect(me['member']['viaInvite'], isFalse);
    });

    test('a role someone already has is kept at the next sign-in', () async {
      final m = await member();
      await setRole(m.id, 'operator', servers: ['a']);
      final again = await browser(
        '/auth/github',
        'github',
        github.codeFor(
          GhUser(int.parse(m.id.split(':')[1]), 'user', orgs: ['acme']),
        ),
      );
      final me = json(
        await as(cookieValue(again, 'mcp_session')!, 'GET', '/api/me'),
      );
      expect(me['member']['role'], 'operator');
      expect(me['member']['serverIds'], ['a']);
    });

    test('the environment keeps giving admin unless told otherwise', () async {
      final other = await Harness.start(github: github, githubOrgs: ['acme']);
      addTearDown(other.close);
      final providers =
          json(await other.admin('GET', '/api/auth/providers')) as List;
      expect(providers.single['defaultRole'], 'admin');
      expect(
        json(
          await gw.admin('GET', '/api/auth/providers'),
        ).single['defaultRole'],
        'viewer',
      );
    });

    test('a provider\'s default role must exist and be grantable', () async {
      final bad = await gw.admin('POST', '/api/auth/providers', {
        'kind': 'google',
        'id': 'google',
        'defaultRole': 'nope',
      });
      expect(bad.statusCode, 400);
      await gw.admin('POST', '/api/roles', {
        'name': 'Providers',
        'permissions': ['providers.manage'],
      });
      final m = await member();
      await setRole(m.id, 'providers');
      final r = await as(m.session, 'POST', '/api/auth/providers', {
        'kind': 'google',
        'id': 'google',
        'defaultRole': 'admin',
      });
      expect(r.statusCode, 403);
    });

    test('a role used as a default cannot be deleted', () async {
      await gw.admin('POST', '/api/roles', {
        'name': 'Newbie',
        'permissions': ['servers.view'],
      });
      await addGoogleProvider(defaultRole: 'newbie');
      expect((await gw.admin('DELETE', '/api/roles/newbie')).statusCode, 409);
    });
  });

  group('live events', () {
    test(
      'audit events only reach members who may read the audit log',
      () async {
        final viewer = await member('reader'); // viewer reads audit
        await gw.admin('POST', '/api/roles', {
          'name': 'Blind',
          'permissions': ['servers.view', 'tools.view'],
        });
        final blind = await member('blind');
        await setRole(blind.id, 'blind');

        Future<SseReader> open(String token) async {
          final r = await SseReader.open(
            '${gw.base}/api/events',
            headers: {'authorization': 'Bearer $token'},
          );
          addTearDown(r.close);
          await r.nextOf('ready');
          return r;
        }

        final seeing = await open(viewer.session);
        final blinded = await open(blind.session);
        final portalToken = await gw.addToken('c');
        await gw.callTool('one', portalToken, 'one__lookup');

        expect(
          (await seeing.nextOf('audit')).data['exposedName'],
          'one__lookup',
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(blinded.messages.where((m) => m.event == 'audit'), isEmpty);
      },
    );

    test('health only reaches members who may see that server', () async {
      final m = await member();
      await setRole(m.id, 'viewer', servers: ['b']);
      final r = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer ${m.session}'},
      );
      addTearDown(r.close);
      await r.nextOf('ready');
      await gw.admin('POST', '/api/health/check');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final ids = [
        for (final e in r.messages)
          if (e.event == 'health') e.data['serverId'],
      ];
      expect(ids.toSet(), {'b'});
    });
  });

  group('storage', () {
    late TestDatabase db;
    setUp(() async => db = await TestDatabase.create());
    tearDown(() async => db.drop());

    test('roles, invitations and scopes survive a restart', () async {
      var server = await Harness.start(
        databaseUrl: db.url,
        google: google,
        github: github,
        githubOrgs: ['acme'],
        defaultRole: 'viewer',
      );
      await server.addServer('Alpha', upstream.url, id: 'a');
      await server.adminJson('POST', '/api/roles', {
        'name': 'Auditor',
        'description': 'Reads',
        'permissions': ['audit.view', 'servers.view'],
      });
      final invite = await server.adminJson('POST', '/api/invites', {
        'role': 'auditor',
        'email': 'Ann@Example.com',
        'serverIds': ['a'],
      });
      final r = await server.rawGet('/auth/github');
      final state = Uri.parse(r.headers['location']!).queryParameters['state']!;
      final done = await server.rawGet(
        '/auth/github/callback?code=${github.codeFor(GhUser(7, 'ada', orgs: ['acme']))}&state=$state',
        {'cookie': 'mcp_login=$state'},
      );
      final session = cookieValue(done, 'mcp_session')!;
      await server.adminJson('PUT', '/api/members/github:7', {
        'role': 'auditor',
        'serverIds': ['a'],
      });
      await server.close();

      server = await Harness.start(
        databaseUrl: db.url,
        github: github,
        githubOrgs: ['acme'],
        defaultRole: 'viewer',
      );
      addTearDown(server.close);
      final roles = await server.admin('GET', '/api/roles');
      expect(json(roles).last['id'], 'auditor');
      expect(json(roles).last['permissions'], ['audit.view', 'servers.view']);
      final me = jsonDecode(
        (await server.admin('GET', '/api/me', null, {
          'authorization': 'Bearer $session',
        })).body,
      );
      expect(me['member']['role'], 'auditor');
      expect(me['member']['serverIds'], ['a']);
      final invites =
          jsonDecode((await server.admin('GET', '/api/invites')).body) as List;
      expect(invites.single['email'], 'ann@example.com');
      expect(invites.single['id'], invite['id']);
      expect(invites.single['status'], 'pending');
    });
  });
}
