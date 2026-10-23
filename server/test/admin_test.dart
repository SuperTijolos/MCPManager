import 'dart:convert';

import 'package:test/test.dart';

import 'support/fake_upstream.dart';
import 'support/harness.dart';

void main() {
  late Harness gw;
  late FakeUpstream upstream;

  setUp(() async {
    gw = await Harness.start();
    upstream = await FakeUpstream.start(
      tools: [tool('read_file'), tool('write_file')],
      handlers: {'read_file': (_) => textResult('contents')},
    );
  });

  tearDown(() async {
    await gw.close();
    await upstream.close();
  });

  group('the admin API', () {
    test('needs the admin token', () async {
      for (final headers in [
        <String, String>{},
        {'authorization': 'Bearer wrong-token-wrong-token'},
        {'authorization': 'Basic abc'},
      ]) {
        final r = await gw.admin('GET', '/api/status', null, headers);
        expect(r.statusCode, 401, reason: '$headers');
      }
      final ok = await gw.admin('GET', '/api/status');
      expect(ok.statusCode, 200);
      expect(jsonDecode(ok.body)['servers'], 0);
    });

    test('an access token is not an admin token', () async {
      final id = await gw.addServer('Files', upstream.url);
      await gw.addPortal('P', [id]);
      final secret = await gw.addToken('client');
      final r = await gw.admin(
        'GET',
        '/api/servers',
        null,
        gw.adminHeaders(secret),
      );
      expect(r.statusCode, 401);
    });

    test('unknown routes are 404 and wrong methods 405', () async {
      expect((await gw.admin('GET', '/api/nothing')).statusCode, 404);
      expect((await gw.admin('PATCH', '/api/servers')).statusCode, 405);
    });

    test('malformed JSON is a 400, not a crash', () async {
      final r = await gw.client.post(
        Uri.parse('${gw.base}/api/servers'),
        headers: gw.adminHeaders(),
        body: '{oops',
      );
      expect(r.statusCode, 400);
      expect(jsonDecode(r.body)['error'], 'invalid_json');
    });
  });

  group('servers', () {
    test('are created, listed and never reveal their header values', () async {
      final id = await gw.addServer(
        'Files',
        upstream.url,
        headers: {'Authorization': 'Bearer super-secret', 'X-Api-Key': 'k'},
      );

      final list = await gw.admin('GET', '/api/servers');
      expect(list.body, isNot(contains('super-secret')));
      final server = (jsonDecode(list.body) as List).single as Map;
      expect(server['id'], id);
      expect(server['slug'], 'files');
      expect(server['headerNames'], ['Authorization', 'X-Api-Key']);
      expect(server.containsKey('headers'), isFalse);

      final one = await gw.admin('GET', '/api/servers/$id');
      expect(one.body, isNot(contains('super-secret')));
    });

    test('keep their headers when an update does not send any', () async {
      final id = await gw.addServer(
        'Files',
        upstream.url,
        headers: {'Authorization': 'Bearer kept'},
      );
      await gw.adminJson('PUT', '/api/servers/$id', {'name': 'Renamed'});

      await gw.addPortal('P', [id], slug: 'p');
      final token = await gw.addToken('t');
      upstream.requireToken = 'kept';
      expect(await gw.toolNames('p', token), isNotEmpty);
    });

    test('PUT creates a server under the id the caller chose', () async {
      final id = await gw.addServer('Files', upstream.url, id: 'srv_from_app');
      expect(id, 'srv_from_app');
      expect(
        (await gw.admin('GET', '/api/servers/srv_from_app')).statusCode,
        200,
      );
    });

    test('validate their URL, name and slug', () async {
      expect(
        (await gw.admin('POST', '/api/servers', {
          'name': 'x',
          'url': 'not a url',
        })).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/servers', {
          'url': upstream.url,
        })).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/servers', {
          'name': 'x',
          'url': upstream.url,
          'slug': 'Bad Slug',
        })).statusCode,
        400,
      );
    });

    test(
      'get a free slug when names collide, and reject a taken explicit one',
      () async {
        await gw.addServer('Files', upstream.url);
        await gw.addServer('Files', upstream.url);
        final slugs = [
          for (final s
              in jsonDecode((await gw.admin('GET', '/api/servers')).body)
                  as List)
            (s as Map)['slug'],
        ];
        expect(slugs, ['files', 'files-2']);

        final clash = await gw.admin('POST', '/api/servers', {
          'name': 'Other',
          'url': upstream.url,
          'slug': 'files',
        });
        expect(clash.statusCode, 409);
      },
    );

    test('can be tested before they go into a portal', () async {
      final id = await gw.addServer('Files', upstream.url);
      final result = await gw.adminJson('POST', '/api/servers/$id/test');
      expect(result['ok'], isTrue);
      expect(result['toolCount'], 2);
      expect(result['tools'], ['read_file', 'write_file']);
      expect(result['server'], {'name': 'fake-upstream', 'version': '9.9.9'});
      expect(result['transport'], 'streamable-http');
    });

    test('report why a test failed', () async {
      final dead = await FakeUpstream.start();
      final url = dead.url;
      await dead.close();
      final id = await gw.addServer('Dead', url);
      final result = await gw.adminJson('POST', '/api/servers/$id/test');
      expect(result['ok'], isFalse);
      expect(result['error'], isA<String>());
      expect(result['toolCount'], 0);
    });

    test('list the upstream tools', () async {
      final id = await gw.addServer('Files', upstream.url);
      final r = await gw.adminJson('GET', '/api/servers/$id/tools');
      expect((r['tools'] as List).map((t) => (t as Map)['name']), [
        'read_file',
        'write_file',
      ]);
    });

    test('are removed from every portal when deleted', () async {
      final a = await gw.addServer('A', upstream.url);
      final b = await gw.addServer('B', upstream.url);
      final portal = await gw.addPortal('P', [a, b]);

      expect((await gw.admin('DELETE', '/api/servers/$a')).statusCode, 200);

      final p = await gw.adminJson('GET', '/api/portals/$portal');
      expect((p['servers'] as List).map((s) => (s as Map)['serverId']), [b]);
      expect((await gw.admin('DELETE', '/api/servers/$a')).statusCode, 404);
    });
  });

  group('portals', () {
    test('get an endpoint from their slug', () async {
      final id = await gw.addServer('Files', upstream.url);
      final portal = await gw.adminJson('POST', '/api/portals', {
        'name': 'Dev Tools',
        'servers': [id],
      });
      expect(portal['slug'], 'dev-tools');
      expect(portal['endpoint'], '${gw.base}/mcp/dev-tools');
      expect(portal['enabled'], isTrue);
    });

    test('use the public URL for endpoints when one is configured', () async {
      final custom = await Harness.start(publicUrl: 'https://mcp.example.com');
      addTearDown(custom.close);
      final portal = await custom.adminJson('POST', '/api/portals', {
        'name': 'P',
      });
      expect(portal['endpoint'], 'https://mcp.example.com/mcp/p');
    });

    test('reject a bad or taken slug and unknown servers', () async {
      await gw.addPortal('P', [], slug: 'main');
      expect(
        (await gw.admin('POST', '/api/portals', {
          'name': 'x',
          'slug': 'main',
        })).statusCode,
        409,
      );
      expect(
        (await gw.admin('POST', '/api/portals', {
          'name': 'x',
          'slug': 'Has Space',
        })).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/portals', {
          'name': 'x',
          'servers': ['nope'],
        })).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/portals', {'servers': []})).statusCode,
        400,
      );
    });

    test('are updated in place', () async {
      final a = await gw.addServer('A', upstream.url);
      final b = await gw.addServer('B', upstream.url);
      final id = await gw.addPortal('P', [a]);

      await gw.adminJson('PUT', '/api/portals/$id', {
        'name': 'Renamed',
        'description': 'All the things',
        'servers': [
          a,
          {'serverId': b, 'enabled': false},
        ],
        'excludedTools': ['$a/write_file'],
      });

      final p = await gw.adminJson('GET', '/api/portals/$id');
      expect(p['name'], 'Renamed');
      expect(p['slug'], 'p', reason: 'the slug stays unless it is changed');
      expect(p['description'], 'All the things');
      expect(p['excludedTools'], ['$a/write_file']);
      expect((p['servers'] as List).map((s) => (s as Map)['enabled']), [
        true,
        false,
      ]);
    });

    test('show the tools they leave out, marked, when asked', () async {
      final id = await gw.addServer('Files', upstream.url, id: 'srv1');
      final portal = await gw.addPortal(
        'P',
        [id],
        extra: {
          'excludedTools': ['srv1/write_file'],
        },
      );

      final shown = await gw.adminJson('GET', '/api/portals/$portal/tools');
      expect((shown['tools'] as List).map((t) => (t as Map)['name']), [
        'files__read_file',
      ]);

      final all = await gw.adminJson(
        'GET',
        '/api/portals/$portal/tools?includeHidden=1',
      );
      final byName = {
        for (final t in all['tools'] as List) (t as Map)['name'] as String: t,
      };
      expect(byName['files__write_file']!['excluded'], isTrue);
      expect(byName['files__read_file']!['excluded'], isFalse);
    });

    test('are deleted', () async {
      final id = await gw.addPortal('P', []);
      expect((await gw.admin('DELETE', '/api/portals/$id')).statusCode, 200);
      expect((await gw.admin('GET', '/api/portals/$id')).statusCode, 404);
    });

    test(
      'preview their effective tools, with the hidden ones on request',
      () async {
        final id = await gw.addServer('Files', upstream.url, id: 'srv1');
        final portal = await gw.addPortal('P', [id]);
        await gw.adminJson('PUT', '/api/rules', {
          'rules': [],
          'overrides': {
            'srv1/write_file': {'hidden': true, 'instructions': ''},
          },
        });

        final shown = await gw.adminJson('GET', '/api/portals/$portal/tools');
        expect((shown['tools'] as List).map((t) => (t as Map)['name']), [
          'files__read_file',
        ]);

        final all = await gw.adminJson(
          'GET',
          '/api/portals/$portal/tools?includeHidden=1',
        );
        final byName = {
          for (final t in all['tools'] as List) (t as Map)['name'] as String: t,
        };
        expect(byName['files__write_file']!['visible'], isFalse);
        expect(byName['files__read_file']!['visible'], isTrue);
      },
    );
  });

  group('access tokens', () {
    test('are shown once and stored only as a hash', () async {
      final created = await gw.adminJson('POST', '/api/tokens', {
        'name': 'Claude',
      });
      final secret = created['secret'] as String;
      expect(secret, startsWith('mcp_'));
      expect(secret.length, greaterThan(30));
      expect((created['token'] as Map)['prefix'], secret.substring(0, 8));

      final list = await gw.admin('GET', '/api/tokens');
      expect(list.body, isNot(contains(secret)));
      expect(list.body, isNot(contains('"hash"')));
      expect(gw.gateway.store.state.tokens.single.hash, hashOf(secret));
    });

    test('carry their times in UTC so any clock reads them right', () async {
      final created = await gw.adminJson('POST', '/api/tokens', {
        'name': 'n',
        'expiresInDays': 5,
      });
      final token = created['token'] as Map;
      expect(token['createdAt'], endsWith('Z'));
      expect(token['expiresAt'], endsWith('Z'));
    });

    test('must have a name and only name real portals', () async {
      expect(
        (await gw.admin('POST', '/api/tokens', {'name': ' '})).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/tokens', {
          'name': 'x',
          'portalIds': ['ghost'],
        })).statusCode,
        400,
      );
    });

    test('can be revoked', () async {
      final id = await gw.addServer('Files', upstream.url);
      await gw.addPortal('P', [id], slug: 'p');
      final created = await gw.adminJson('POST', '/api/tokens', {'name': 'x'});
      final secret = created['secret'] as String;
      expect(await gw.toolNames('p', secret), isNotEmpty);

      await gw.adminJson(
        'DELETE',
        '/api/tokens/${(created['token'] as Map)['id']}',
      );

      final reply = await gw.post('p', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: secret);
      expect(reply.statusCode, 401);
      final list = await gw.admin('GET', '/api/tokens');
      expect(
        ((jsonDecode(list.body) as List).single as Map)['revokedAt'],
        isNotNull,
      );
    });
  });

  group('rules', () {
    test('are stored in the format the app uses and read back', () async {
      final body = {
        'rules': [
          {
            'id': 'r1',
            'name': 'Why',
            'scope': 'all',
            'args': [
              {'name': 'reason', 'type': 'string', 'required': true},
            ],
          },
        ],
        'overrides': {
          's/t': {'hidden': true},
        },
      };
      expect((await gw.adminJson('PUT', '/api/rules', body))['rules'], 1);
      final back = await gw.adminJson('GET', '/api/rules');
      expect((back['rules'] as List).single['name'], 'Why');
      expect((back['overrides'] as Map)['s/t']['hidden'], isTrue);
    });

    test('reject a document that cannot be read', () async {
      final r = await gw.admin('PUT', '/api/rules', {
        'rules': ['nonsense'],
      });
      expect(r.statusCode, 400);
    });
  });
}
