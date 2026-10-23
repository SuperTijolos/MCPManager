import 'dart:convert';

import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_upstream.dart';
import 'support/github_login.dart';
import 'support/harness.dart';
import 'support/sse.dart';

void main() {
  late Harness gw;
  late FakeUpstream files;

  setUp(() async {
    gw = await Harness.start();
    files = await FakeUpstream.start(
      tools: [
        tool(
          'read_file',
          properties: {
            'path': {'type': 'string'},
          },
          required: ['path'],
        ),
        tool('broken'),
      ],
      handlers: {
        'read_file': (a) => textResult('contents of ${a['path']}'),
        'broken': (_) => textResult('it failed', isError: true),
      },
    );
    await gw.addServer('Files', files.url, id: 'srv');
  });

  tearDown(() async {
    await gw.close();
    await files.close();
  });

  Future<Map<String, dynamic>> call(
    String tool, [
    Map<String, dynamic> args = const {},
    Map<String, dynamic> extra = const {},
    String server = 'srv',
  ]) => gw.adminJson('POST', '/api/servers/$server/call', {
    'tool': tool,
    'arguments': args,
    ...extra,
  });

  Future<List<Map<String, dynamic>>> audit([String query = '']) async {
    final r = await gw.adminJson('GET', '/api/audit$query');
    return [
      for (final e in r['events'] as List) (e as Map).cast<String, dynamic>(),
    ];
  }

  Future<void> setRules(Map<String, dynamic> body) =>
      gw.adminJson('PUT', '/api/rules', body);

  group('calling a tool', () {
    test('forwards the call and returns what the server said', () async {
      final r = await call('read_file', {'path': '/a'});
      expect(r['status'], 'success');
      expect(r['isError'], isFalse);
      expect(r['text'], 'contents of /a');
      expect(r['durationMs'], isA<int>());
      final sent = files.requests.lastWhere((q) => q['method'] == 'tools/call');
      expect(sent['params'], {
        'name': 'read_file',
        'arguments': {'path': '/a'},
      });
    });

    test('is recorded as the dashboard\'s, with no portal', () async {
      await call('read_file', {'path': '/a'});
      final e = (await audit()).single;
      expect(e['source'], 'dashboard');
      expect(e['tool'], 'read_file');
      expect(e['serverName'], 'Files');
      expect(e['principal'], {
        'kind': 'admin',
        'id': 'admin',
        'name': 'Admin token',
      });
      expect(e.containsKey('portalId'), isFalse);
      expect(e['status'], 'success');
      expect(e['result'], 'contents of /a');
    });

    test('a chat call carries its conversation', () async {
      await call(
        'read_file',
        {'path': '/a'},
        {'source': 'chat', 'conversationId': 'chat_1'},
      );
      await call('read_file', {'path': '/b'});
      final chat = await audit('?conversation=chat_1');
      expect(chat, hasLength(1));
      expect(chat.single['source'], 'chat');
      expect(chat.single['conversationId'], 'chat_1');
      expect(await audit('?source=dashboard'), hasLength(1));
      expect(await audit('?source=chat'), hasLength(1));
      expect(await audit('?source=portal'), isEmpty);
    });

    test('a server that answers with an error is an error', () async {
      final r = await call('broken');
      expect(r['status'], 'error');
      expect(r['isError'], isTrue);
      expect(r['text'], 'it failed');
      expect((await audit()).single['status'], 'error');
    });

    test(
      'a server that is down is a 502 that says why, and it is recorded',
      () async {
        await files.close();
        final r = await gw.admin('POST', '/api/servers/srv/call', {
          'tool': 'read_file',
          'arguments': {'path': '/a'},
        });
        expect(r.statusCode, 502);
        expect(jsonDecode(r.body)['error'], 'server_unreachable');
        final e = (await audit()).single;
        expect(e['status'], 'error');
        expect(e['error'], isNotEmpty);
      },
    );

    test(
      'a server that drops after being listed gives an error outcome',
      () async {
        await call('read_file', {'path': '/a'});
        await files.close();
        final r = await call('read_file', {'path': '/b'});
        expect(r['status'], 'error');
        expect(r['isError'], isTrue);
        expect(r['error'], isNotEmpty);
        expect((await audit()).first['status'], 'error');
      },
    );

    test(
      'secrets in the arguments are masked in the log, not on the wire',
      () async {
        await call('read_file', {
          'path': '/a',
          'api_key': 'sk-supersecretvalue1234567890',
        });
        final sent = files.requests.lastWhere(
          (q) => q['method'] == 'tools/call',
        );
        expect(
          sent['params']['arguments']['api_key'],
          'sk-supersecretvalue1234567890',
        );
        expect(
          (await audit()).single['args'],
          isNot(contains('supersecretvalue')),
        );
      },
    );

    test('is refused without a credential', () async {
      final r = await gw.admin(
        'POST',
        '/api/servers/srv/call',
        {'tool': 'read_file'},
        {'content-type': 'application/json'},
      );
      expect(r.statusCode, 401);
      expect(files.requests.where((q) => q['method'] == 'tools/call'), isEmpty);
    });

    group('with bad input', () {
      Future<int> status(
        Map<String, dynamic> body, {
        String server = 'srv',
      }) async => (await gw.admin(
        'POST',
        '/api/servers/$server/call',
        body,
      )).statusCode;

      test('an unknown server is 404', () async {
        expect(await status({'tool': 'read_file'}, server: 'nope'), 404);
      });
      test('a missing tool name is 400', () async {
        expect(await status({}), 400);
        expect(await status({'tool': 7}), 400);
      });
      test('arguments must be an object', () async {
        expect(await status({'tool': 'read_file', 'arguments': 'x'}), 400);
        expect(
          await status({
            'tool': 'read_file',
            'arguments': [1],
          }),
          400,
        );
      });
      test('the source must be dashboard or chat', () async {
        expect(await status({'tool': 'read_file', 'source': 'portal'}), 400);
      });
      test(
        'a tool the server does not have is 404 and is recorded as denied',
        () async {
          expect(await status({'tool': 'delete_everything'}), 404);
          final e = (await audit()).single;
          expect(e['status'], 'denied');
          expect(e['tool'], 'delete_everything');
        },
      );
      test('a disabled server is 409', () async {
        await gw.adminJson('PUT', '/api/servers/srv', {
          'name': 'Files',
          'url': files.url,
          'transport': 'streamable-http',
          'enabled': false,
        });
        expect(await status({'tool': 'read_file'}), 409);
        expect(
          files.requests.where((q) => q['method'] == 'tools/call'),
          isEmpty,
        );
      });
    });
  });

  group('rules on dashboard calls', () {
    const whyRule = {
      'id': 'why',
      'name': 'Why',
      'scope': 'all',
      'args': [
        {
          'name': 'reason',
          'type': 'string',
          'required': true,
          'description': 'Why',
        },
      ],
    };

    test(
      'refuse a call missing a required argument, before it leaves',
      () async {
        await setRules({
          'rules': [whyRule],
          'overrides': {},
        });
        final r = await call('read_file', {'path': '/a'});
        expect(r['isError'], isTrue);
        expect(r['rejected'], contains('Missing required argument: reason'));
        expect(r['status'], 'error');
        expect(
          files.requests.where((q) => q['method'] == 'tools/call'),
          isEmpty,
        );
        expect(
          (await audit()).single['error'],
          contains('Rejected before forwarding'),
        );
      },
    );

    test(
      'keep the rule\'s argument out of the upstream call and in the log',
      () async {
        await setRules({
          'rules': [whyRule],
          'overrides': {},
        });
        final r = await call('read_file', {'path': '/a', 'reason': 'checking'});
        expect(r['status'], 'success');
        final sent = files.requests.lastWhere(
          (q) => q['method'] == 'tools/call',
        );
        expect(sent['params']['arguments'], {'path': '/a'});
        final e = (await audit()).single;
        expect(e['rules'], ['Why']);
        expect(e['context'], contains('checking'));
      },
    );
  });

  group('hidden tools', () {
    setUp(() async {
      await setRules({
        'rules': [],
        'overrides': {
          'srv/read_file': {'hidden': true},
        },
      });
    });

    test('the test bench can still call them', () async {
      expect((await call('read_file', {'path': '/a'}))['status'], 'success');
    });

    test('the chat cannot', () async {
      final r = await gw.admin('POST', '/api/servers/srv/call', {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
        'source': 'chat',
      });
      expect(r.statusCode, 403);
      expect(files.requests.where((q) => q['method'] == 'tools/call'), isEmpty);
      final e = (await audit()).single;
      expect(e['status'], 'denied');
      expect(e['source'], 'chat');
    });
  });

  test('a signed-in member is named in the log', () async {
    final github = await FakeGitHub.start();
    addTearDown(github.close);
    await gw.close();
    gw = await Harness.start(github: github, githubOrgs: ['acme']);
    await gw.addServer('Files', files.url, id: 'srv');
    final session = await gw.signInAs(github, GhUser(1, 'ada', orgs: ['acme']));

    final r = await gw.admin(
      'POST',
      '/api/servers/srv/call',
      {
        'tool': 'read_file',
        'arguments': {'path': '/a'},
      },
      {'authorization': 'Bearer $session', 'content-type': 'application/json'},
    );
    expect(r.statusCode, 200, reason: r.body);
    final e = (await audit()).single;
    expect(e['principal'], {'kind': 'member', 'id': 'github:1', 'name': 'ada'});
  });

  group('the tool catalogue', () {
    test('one server: name, version, transport and every tool', () async {
      final r = await gw.adminJson('GET', '/api/servers/srv/tools');
      expect(r['error'], isNull);
      expect(r['server'], isNotNull);
      expect(r['transport'], isNotNull);
      expect(r['fetchedAt'], isNotNull);
      expect(
        [for (final t in r['tools'] as List) (t as Map)['name']],
        ['read_file', 'broken'],
      );
      expect((r['tools'] as List).first['inputSchema']['required'], ['path']);
    });

    int lists() =>
        files.requests.where((q) => q['method'] == 'tools/list').length;

    test('is cached, and refresh=1 asks again', () async {
      await gw.adminJson('GET', '/api/servers/srv/tools');
      final once = lists();
      await gw.adminJson('GET', '/api/servers/srv/tools');
      expect(lists(), once);
      await gw.adminJson('GET', '/api/servers/srv/tools?refresh=1');
      expect(lists(), once + 1);
    });

    test('all servers at once, skipping disabled ones', () async {
      final other = await FakeUpstream.start(tools: [tool('ping')]);
      addTearDown(other.close);
      await gw.addServer('Other', other.url, id: 'other');
      await gw.adminJson('PUT', '/api/servers/other', {
        'name': 'Other',
        'url': other.url,
        'transport': 'streamable-http',
        'enabled': false,
      });
      var r = await gw.adminJson('GET', '/api/tools');
      expect([for (final s in r['servers'] as List) (s as Map)['id']], ['srv']);

      await gw.adminJson('PUT', '/api/servers/other', {
        'name': 'Other',
        'url': other.url,
        'transport': 'streamable-http',
        'enabled': true,
      });
      r = await gw.adminJson('GET', '/api/tools');
      expect(
        [for (final s in r['servers'] as List) (s as Map)['id']],
        ['srv', 'other'],
      );
    });

    test('one dead server does not hide the others', () async {
      final dead = await FakeUpstream.start(tools: [tool('x')]);
      await gw.addServer('Dead', dead.url, id: 'dead');
      await dead.close();
      final r = await gw.adminJson('GET', '/api/tools?refresh=1');
      final byId = {
        for (final s in r['servers'] as List)
          (s as Map)['id'] as String: s.cast<String, dynamic>(),
      };
      expect(byId['dead']!['error'], isNotNull);
      expect(byId['dead']!['tools'], isEmpty);
      expect(byId['srv']!['error'], isNull);
      expect(byId['srv']!['tools'], hasLength(2));
    });
  });

  group('server health', () {
    Future<Map<String, dynamic>> check() async =>
        (await gw.adminJson('POST', '/api/health/check'))['servers']
            as Map<String, dynamic>;

    test('is empty until something has looked', () async {
      expect((await gw.adminJson('GET', '/api/health'))['servers'], isEmpty);
    });

    test('a check records who is up and how many tools they have', () async {
      final h = await check();
      expect(h['srv']['ok'], isTrue);
      expect(h['srv']['toolCount'], 2);
      expect(h['srv']['error'], isNull);
      expect(
        (await gw.adminJson('GET', '/api/health'))['servers']['srv']['ok'],
        isTrue,
      );
    });

    test('a server that is down is not ok, and says why', () async {
      await files.close();
      final h = await check();
      expect(h['srv']['ok'], isFalse);
      expect(h['srv']['error'], isNotEmpty);
    });

    test('skips disabled servers and forgets removed ones', () async {
      await check();
      await gw.adminJson('PUT', '/api/servers/srv', {
        'name': 'Files',
        'url': files.url,
        'transport': 'streamable-http',
        'enabled': false,
      });
      expect(await check(), isEmpty);
    });

    test('the test button updates it too', () async {
      await gw.adminJson('POST', '/api/servers/srv/test');
      expect(
        (await gw.adminJson('GET', '/api/health'))['servers']['srv']['ok'],
        isTrue,
      );
    });

    test('goes up and down on the event stream, once per change', () async {
      final r = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer $adminToken'},
      );
      addTearDown(r.close);
      await r.nextOf('ready');

      await check();
      var e = await r.nextOf('health');
      expect(e.data['serverId'], 'srv');
      expect(e.data['ok'], isTrue);

      await check();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        r.messages.where((m) => m.event == 'health'),
        hasLength(1),
        reason: 'no change, no event',
      );

      final port = files.port;
      await files.close();
      await check();
      e = await r.nextOf('health');
      expect(e.data['ok'], isFalse);
      expect(e.data['error'], isNotEmpty);

      files = await FakeUpstream.start(tools: [tool('read_file')], port: port);
      await check();
      e = await r.nextOf('health');
      expect(e.data['ok'], isTrue);
    });

    test('runs by itself on the configured interval', () async {
      await gw.close();
      gw = await Harness.start(
        healthInterval: const Duration(milliseconds: 100),
      );
      await gw.addServer('Files', files.url, id: 'srv');
      Map servers = {};
      for (var i = 0; i < 40 && servers.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        servers = (await gw.adminJson('GET', '/api/health'))['servers'] as Map;
      }
      expect(servers['srv']['ok'], isTrue);
    });
  });

  test('the response of a call is plain JSON', () async {
    final r = await gw.admin('POST', '/api/servers/srv/call', {
      'tool': 'read_file',
      'arguments': {'path': '/a'},
    });
    expect(r.headers['content-type'], contains('application/json'));
    expect(jsonDecode(r.body), isA<Map>());
  });
}
