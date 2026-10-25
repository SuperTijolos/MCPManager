import 'dart:convert';

import 'package:test/test.dart';

import 'support/fake_oauth_upstream.dart';
import 'support/fake_upstream.dart';
import 'support/harness.dart';
import 'support/pg.dart';

void main() {
  group('in memory', () => suite(memory: true));
  group('in Postgres', () => suite(memory: false));
}

void suite({required bool memory}) {
  late Harness gw;
  late FakeUpstream files;
  TestDatabase? db;

  setUp(() async {
    if (!memory) db = await TestDatabase.create();
    gw = await Harness.start(databaseUrl: db?.url);
    files = await FakeUpstream.start(
      tools: [
        tool(
          'read_file',
          properties: {
            'path': {'type': 'string'},
          },
          required: ['path'],
        ),
      ],
      handlers: {'read_file': (a) => textResult('contents of ${a['path']}')},
    );
    await gw.addServer('Files', files.url, id: 'srv');
  });

  tearDown(() async {
    await gw.close();
    await files.close();
    await db?.drop();
  });

  Future<List<Map<String, dynamic>>> audit([String q = '']) async {
    final r = await gw.adminJson('GET', '/api/audit$q');
    return [
      for (final e in r['events'] as List) (e as Map).cast<String, dynamic>(),
    ];
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body) =>
      gw.adminJson('POST', path, body);

  group('trying a server', () {
    test('connects without saving anything', () async {
      final r = await post('/api/servers/probe', {'url': files.url});
      expect(r['connected'], isTrue);
      expect(r['toolCount'], 1);
      expect(r['server']['name'], isNotNull);
      expect(r['transport'], isNotNull);
      expect(r['endpoint'], files.url);
      expect(r['latencyMs'], isA<int>());
      expect(r['trace'], isNotEmpty);
      final servers =
          jsonDecode((await gw.admin('GET', '/api/servers')).body) as List;
      expect(servers, hasLength(1), reason: 'only the one saved before');
    });

    test('says what went wrong', () async {
      final dead = await FakeUpstream.start();
      final url = dead.url;
      await dead.close();
      final r = await post('/api/servers/probe', {'url': url});
      expect(r['connected'], isFalse);
      expect(r['error'], isNotEmpty);
    });

    test('refuses an address that is not http(s)', () async {
      expect(
        (await gw.admin('POST', '/api/servers/probe', {
          'url': 'ftp://x',
        })).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/servers/probe', {})).statusCode,
        400,
      );
    });

    test('uses the headers of a saved server unless told otherwise', () async {
      final locked = await FakeUpstream.start(
        tools: [tool('x')],
        requireToken: 's3cret',
      );
      addTearDown(locked.close);
      await gw.adminJson('PUT', '/api/servers/locked', {
        'name': 'Locked',
        'url': locked.url,
        'transport': 'streamable-http',
        'headers': {'Authorization': 'Bearer s3cret'},
      });
      final saved = await post('/api/servers/probe', {'serverId': 'locked'});
      expect(saved['connected'], isTrue);
      final wrong = await post('/api/servers/probe', {
        'serverId': 'locked',
        'headers': {'Authorization': 'Bearer nope'},
      });
      expect(wrong['connected'], isFalse);
      expect(wrong['needsAuth'], isTrue);
      final kept = await post('/api/servers/probe', {
        'serverId': 'locked',
        'headers': {'Authorization': null},
      });
      expect(kept['connected'], isTrue, reason: 'null keeps the stored value');
    });

    test('does not touch the audit log', () async {
      await post('/api/servers/probe', {'url': files.url});
      expect(
        (await audit()).where(
          (e) => e['kind'] == null || e['kind'] == 'toolCall',
        ),
        isEmpty,
      );
    });

    test('tells a server that wants OAuth from one that is broken', () async {
      final oauth = await FakeOAuthUpstream.start();
      addTearDown(oauth.close);
      final r = await post('/api/servers/probe', {
        'url': oauth.url,
        'oauth': true,
      });
      expect(r['connected'], isFalse);
      expect(r['needsAuth'], isTrue);
    });

    test('needs a credential', () async {
      final r = await gw.client.post(Uri.parse('${gw.base}/api/servers/probe'));
      expect(r.statusCode, 401);
    });
  });

  group('editing headers', () {
    Future<Map<String, dynamic>> put(Map<String, dynamic> headers) =>
        gw.adminJson('PUT', '/api/servers/srv', {
          'name': 'Files',
          'url': files.url,
          'transport': 'streamable-http',
          'headers': headers,
        });

    test('a null value keeps what is stored under that name', () async {
      await put({'A': '1', 'B': '2'});
      final r = await put({'A': null, 'B': 'changed', 'C': '3'});
      expect(r['headerNames'], ['A', 'B', 'C']);
      final locked = await FakeUpstream.start(requireToken: 'tok');
      addTearDown(locked.close);
      // Values never come back, so prove them through behaviour: A is still 1.
      await put({'A': null});
      expect(gw.gateway.store.state.server('srv')!.headers, {'A': '1'});
      await put({'A': null, 'B': 'changed'});
      expect(gw.gateway.store.state.server('srv')!.headers, {
        'A': '1',
        'B': 'changed',
      });
    });

    test('a null for a name that is not stored adds nothing', () async {
      await put({'A': '1'});
      await put({'A': null, 'Z': null});
      expect(gw.gateway.store.state.server('srv')!.headers, {'A': '1'});
    });

    test('an empty list removes every header', () async {
      await put({'A': '1'});
      await put({});
      expect(gw.gateway.store.state.server('srv')!.headers, isEmpty);
    });
  });

  group('events the dashboard reports', () {
    test('a management action is recorded with who did it', () async {
      final r = await post('/api/audit/events', {
        'kind': 'manage',
        'status': 'success',
        'source': 'chat',
        'tool': 'add_server',
        'serverName': 'Docs',
        'result': 'added',
        'actor': 'operator:gemma4',
        'approval': 'user',
        'conversationId': 'chat_1',
      });
      expect(r['kind'], 'manage');
      final e = (await audit()).single;
      expect(e['kind'], 'manage');
      expect(e['source'], 'chat');
      expect(e['tool'], 'add_server');
      expect(e['actor'], 'operator:gemma4');
      expect(e['approval'], 'user');
      expect(e['conversationId'], 'chat_1');
      expect(e['principal'], {
        'kind': 'admin',
        'id': 'admin',
        'name': 'Admin token',
      });
    });

    test('a refused call is recorded as denied', () async {
      await post('/api/audit/events', {
        'kind': 'toolCall',
        'status': 'denied',
        'source': 'chat',
        'serverId': 'srv',
        'serverName': 'Files',
        'tool': 'read_file',
        'args': '{"path":"/a"}',
        'approval': 'denied',
      });
      final e = (await audit()).single;
      expect(e['status'], 'denied');
      expect(e['approval'], 'denied');
    });

    test('secrets are masked', () async {
      await post('/api/audit/events', {
        'status': 'error',
        'args': 'token sk-supersecretvalue1234567890 here',
        'error': 'Bearer abcdefghijklmnopqrstuvwxyz0123456789 rejected',
      });
      final e = (await audit()).single;
      expect(e['args'], isNot(contains('supersecretvalue')));
      expect(e['error'], isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    });

    test('long text is shortened', () async {
      await post('/api/audit/events', {
        'status': 'success',
        'result': 'x' * 50000,
      });
      expect(
        ((await audit()).single['result'] as String).length,
        lessThanOrEqualTo(4000),
      );
    });

    test('bad input is refused and stores nothing', () async {
      Future<int> code(Map<String, dynamic> b) async =>
          (await gw.admin('POST', '/api/audit/events', b)).statusCode;
      expect(await code({'status': 'weird'}), 400);
      expect(await code({}), 400);
      expect(await code({'status': 'success', 'kind': 'serverConnect'}), 400);
      expect(await code({'status': 'success', 'source': 'portal'}), 400);
      expect(await code({'status': 'success', 'source': 'system'}), 400);
      expect(await code({'status': 'success', 'durationMs': -1}), 400);
      expect(await code({'status': 'success', 'args': 5}), 400);
      expect(await audit(), isEmpty);
    });
  });

  group('removing events', () {
    Future<List<String>> seed() async {
      final ids = <String>[];
      for (var i = 0; i < 4; i++) {
        final r = await post('/api/audit/events', {
          'status': 'success',
          'tool': 't$i',
        });
        ids.add(r['id'] as String);
        gw.clock.advance(const Duration(hours: 1));
      }
      return ids;
    }

    test('by id', () async {
      final ids = await seed();
      final r = await post('/api/audit/delete', {
        'ids': [ids[0], ids[2], 'nope'],
      });
      expect(r['removed'], 2);
      expect([for (final e in await audit()) e['tool']], ['t3', 't1']);
    });

    test('older than a time', () async {
      await seed();
      final cutoff = gw.clock().subtract(const Duration(hours: 2, minutes: 30));
      final r = await post('/api/audit/delete', {
        'before': cutoff.toUtc().toIso8601String(),
      });
      expect(r['removed'], 2);
      expect([for (final e in await audit()) e['tool']], ['t3', 't2']);
    });

    test('everything', () async {
      await seed();
      final r = await post('/api/audit/delete', {'all': true});
      expect(r['removed'], 4);
      expect(await audit(), isEmpty);
    });

    test('nothing without being told what', () async {
      await seed();
      expect((await gw.admin('POST', '/api/audit/delete', {})).statusCode, 400);
      expect(
        (await gw.admin('POST', '/api/audit/delete', {'ids': 'x'})).statusCode,
        400,
      );
      expect(
        (await gw.admin('POST', '/api/audit/delete', {
          'before': 'yesterday',
        })).statusCode,
        400,
      );
      expect(await audit(), hasLength(4));
    });

    test('an empty list of ids removes nothing', () async {
      await seed();
      final r = await post('/api/audit/delete', {'ids': <String>[]});
      expect(r['removed'], 0);
      expect(await audit(), hasLength(4));
    });
  });

  group('calling from the dashboard', () {
    test('records the actor and how it was approved', () async {
      await post('/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
        'source': 'chat',
        'actor': 'operator:gemma4',
        'approval': 'auto',
      });
      final e = (await audit()).single;
      expect(e['actor'], 'operator:gemma4');
      expect(e['approval'], 'auto');
      expect(e['kind'], isNull, reason: 'a plain tool call carries no kind');
    });

    test('can skip the rules for a test run', () async {
      await gw.adminJson('PUT', '/api/rules', {
        'rules': [
          {
            'id': 'why',
            'name': 'Why',
            'scope': 'all',
            'args': [
              {
                'name': 'reason',
                'type': 'string',
                'required': true,
                'description': 'x',
              },
            ],
          },
        ],
        'overrides': {},
      });
      final withRules = await post('/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
      });
      expect(withRules['rejected'], isNotNull);
      final without = await post('/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
        'applyRules': false,
      });
      expect(without['status'], 'success');
      expect(without['text'], 'contents of /a');
    });

    test('only the dashboard may skip the rules', () async {
      final r = await gw.admin('POST', '/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
        'source': 'chat',
        'applyRules': false,
      });
      expect(r.statusCode, 400);
      expect(files.requests.where((q) => q['method'] == 'tools/call'), isEmpty);
    });
  });

  group('what a call answers', () {
    test(
      'carries the audit event it wrote, so the dashboard need not wait',
      () async {
        final r = await post('/api/servers/srv/call', {
          'tool': 'read_file',
          'arguments': {'path': '/a'},
          'actor': 'user',
        });
        final event = (r['event'] as Map).cast<String, dynamic>();
        final stored = (await audit()).single;
        expect(event['id'], stored['id']);
        expect(event['tool'], 'read_file');
        expect(event['source'], 'dashboard');
      },
    );

    test('also when the rules refused the call', () async {
      await gw.adminJson('PUT', '/api/rules', {
        'rules': [
          {
            'id': 'why',
            'name': 'Why',
            'scope': 'all',
            'args': [
              {
                'name': 'reason',
                'type': 'string',
                'required': true,
                'description': 'x',
              },
            ],
          },
        ],
        'overrides': {},
      });
      final r = await post('/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
      });
      expect(r['rejected'], isNotNull);
      expect(
        (r['event'] as Map)['error'],
        contains('Rejected before forwarding'),
      );
    });
  });

  group('finding a server', () {
    test(
      'what answered is reported, and the transport that worked is remembered',
      () async {
        final bare = 'http://127.0.0.1:${files.port}';
        await gw.adminJson('PUT', '/api/servers/bare', {
          'name': 'Bare',
          'url': bare,
        });
        final r = await gw.adminJson(
          'GET',
          '/api/servers/bare/tools?refresh=1',
        );
        expect(r['endpoint'], bare);
        expect(r['transport'], 'streamable-http');
        expect(r['trace'], isNotEmpty);
        final saved = gw.gateway.store.state.server('bare')!;
        expect(saved.url, bare);
        expect(
          saved.transport.wire,
          'streamable-http',
          reason: 'the next connect is direct',
        );
      },
    );

    test('a server that cannot be reached says what was tried', () async {
      final dead = await FakeUpstream.start();
      final url = dead.url;
      await dead.close();
      await gw.adminJson('PUT', '/api/servers/dead', {
        'name': 'Dead',
        'url': url,
      });
      final r = await gw.adminJson('GET', '/api/servers/dead/tools?refresh=1');
      expect(r['error'], isNotNull);
      expect(r['trace'], isNotEmpty);
      expect(
        gw.gateway.store.state.server('dead')!.url,
        url,
        reason: 'nothing found, nothing changed',
      );
    });
  });

  group('a server that fails once', () {
    int lists() =>
        files.requests.where((q) => q['method'] == 'tools/list').length;

    test(
      'keeps its last tools for that failure, and is looked at again next time',
      () async {
        await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
        final port = files.port;
        await files.close();

        final failed = await gw.adminJson(
          'GET',
          '/api/servers/srv/tools?refresh=1',
        );
        expect(failed['error'], isNotNull);
        expect(
          failed['tools'],
          hasLength(1),
          reason: 'a blip must not empty a portal',
        );

        // Back up: the next plain look does not trust the cache of a failure.
        files = await FakeUpstream.start(
          tools: [tool('read_file'), tool('extra')],
          port: port,
        );
        final again = await gw.adminJson('GET', '/api/servers/srv/tools');
        expect(again['error'], isNull);
        expect(again['tools'], hasLength(2));
        expect(lists(), greaterThan(0));
      },
    );

    test('a second failure in a row drops the tools', () async {
      await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      await files.close();
      await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      final second = await gw.adminJson('GET', '/api/servers/srv/tools');
      expect(second['error'], isNotNull);
      expect(second['tools'], isEmpty);
    });
  });

  group('re-checking a server', () {
    test('listing its tools afresh is recorded as a connection', () async {
      await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      final e = (await audit('?source=system')).single;
      expect(e['kind'], 'serverConnect');
      expect(e['status'], 'success');
      await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      expect(
        await audit('?source=system'),
        hasLength(1),
        reason: 'only changes are recorded',
      );
    });

    test('a plain listing is not', () async {
      await gw.adminJson('GET', '/api/servers/srv/tools');
      expect(await audit('?source=system'), isEmpty);
    });
  });

  group('what the gateway records by itself', () {
    test('a server coming up and going down', () async {
      await gw.adminJson('POST', '/api/health/check');
      var events = await audit('?source=system');
      expect(events.single['kind'], 'serverConnect');
      expect(events.single['status'], 'success');
      expect(events.single['serverName'], 'Files');
      expect(events.single['result'], contains('1 tools'));
      expect(events.single['actor'], 'system');

      await gw.adminJson('POST', '/api/health/check');
      expect(
        await audit('?source=system'),
        hasLength(1),
        reason: 'no change, no event',
      );

      await files.close();
      await gw.adminJson('POST', '/api/health/check');
      events = await audit('?source=system');
      expect(events.first['status'], 'error');
      expect(events.first['error'], isNotEmpty);
      expect(events, hasLength(2));
    });

    test('an upstream sign-in and sign-out', () async {
      final oauth = await FakeOAuthUpstream.start();
      addTearDown(oauth.close);
      await gw.adminJson('PUT', '/api/servers/o', {
        'name': 'OAuth',
        'url': oauth.url,
        'transport': 'streamable-http',
        'oauth': true,
      });
      final start = await post('/api/servers/o/oauth/start', {});
      final back = oauth.approve(Uri.parse(start['authorizeUrl'] as String));
      await gw.rawGet('${back.path}?${back.query}');
      var events = (await audit(
        '?source=system',
      )).where((e) => e['kind'] == 'authorize').toList();
      expect(events.single['status'], 'success');
      expect(events.single['result'], 'OAuth sign-in completed');

      await gw.adminJson('DELETE', '/api/servers/o/oauth');
      events = (await audit(
        '?source=system',
      )).where((e) => e['kind'] == 'authorize').toList();
      expect(events, hasLength(2));
      expect(events.first['result'], 'Signed out');
    });

    test('a refused sign-in', () async {
      final oauth = await FakeOAuthUpstream.start();
      addTearDown(oauth.close);
      await gw.adminJson('PUT', '/api/servers/o', {
        'name': 'OAuth',
        'url': oauth.url,
        'transport': 'streamable-http',
        'oauth': true,
      });
      final start = await post('/api/servers/o/oauth/start', {});
      final back = oauth.approve(
        Uri.parse(start['authorizeUrl'] as String),
        error: 'access_denied',
      );
      await gw.rawGet('${back.path}?${back.query}');
      final e = (await audit(
        '?source=system',
      )).singleWhere((e) => e['kind'] == 'authorize');
      expect(e['status'], 'error');
      expect(e['error'], contains('access_denied'));
    });
  });
}
