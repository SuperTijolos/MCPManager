import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/github_login.dart';
import 'support/harness.dart';
import 'support/pg.dart';
import 'support/sse.dart';

void main() {
  group('in memory', () => chatSuite(memory: true));
  group('in Postgres', () => chatSuite(memory: false));
}

Map<String, dynamic> user(String text) => {'type': 'user', 'text': text};
Map<String, dynamic> bot(String text) => {'type': 'assistant', 'text': text};

void chatSuite({required bool memory}) {
  late Harness gw;
  late FakeGitHub github;
  TestDatabase? db;

  Future<Harness> start({int maxChats = 200}) => Harness.start(
    databaseUrl: db?.url,
    github: github,
    githubOrgs: ['acme'],
    maxChatsPerOwner: maxChats,
  );

  setUp(() async {
    github = await FakeGitHub.start();
    if (!memory) db = await TestDatabase.create();
    gw = await start();
  });

  tearDown(() async {
    await gw.close();
    await github.close();
    await db?.drop();
  });

  Future<http.Response> send(
    String method,
    String path, [
    Object? body,
    String? session,
  ]) async {
    final headers = session == null
        ? null
        : {
            'authorization': 'Bearer $session',
            'content-type': 'application/json',
          };
    return gw.admin(method, path, body, headers);
  }

  Future<Map<String, dynamic>> save(
    String id,
    Map<String, dynamic> body, {
    String? session,
  }) async {
    final r = await send('PUT', '/api/chats/$id', body, session);
    expect(r.statusCode, 200, reason: r.body);
    return (jsonDecode(r.body) as Map).cast<String, dynamic>();
  }

  Future<List<Map<String, dynamic>>> list({String? session}) async {
    final r = await send('GET', '/api/chats', null, session);
    expect(r.statusCode, 200, reason: r.body);
    return [
      for (final e in jsonDecode(r.body) as List)
        (e as Map).cast<String, dynamic>(),
    ];
  }

  Future<String> member(String login, int id) =>
      gw.signInAs(github, GhUser(id, login, orgs: ['acme']));

  test('starts empty', () async {
    expect(await list(), isEmpty);
  });

  test('a conversation is created, read back and listed', () async {
    final meta = await save('c1', {
      'title': 'Fix the build',
      'items': [user('why red?'), bot('a typo'), user('thanks')],
      'history': [
        {'role': 'user', 'content': 'why red?'},
      ],
    });
    expect(meta['id'], 'c1');
    expect(meta['title'], 'Fix the build');
    expect(meta['messageCount'], 2, reason: 'two prompts');
    expect(meta['autoApprove'], isFalse);

    final r = await send('GET', '/api/chats/c1');
    final doc = jsonDecode(r.body) as Map;
    expect(doc['items'], hasLength(3));
    expect(doc['history'], [
      {'role': 'user', 'content': 'why red?'},
    ]);
    expect(doc['title'], 'Fix the build');

    final all = await list();
    expect(all.single['id'], 'c1');
    expect(
      all.single.containsKey('items'),
      isFalse,
      reason: 'the list is light',
    );
  });

  test(
    'a new conversation without a title is called "New conversation"',
    () async {
      final meta = await save('c1', {});
      expect(meta['title'], 'New conversation');
      expect(meta['messageCount'], 0);
      final doc = jsonDecode((await send('GET', '/api/chats/c1')).body) as Map;
      expect(doc['items'], isEmpty);
    },
  );

  test(
    'renaming keeps the content, and saving content keeps the title',
    () async {
      await save('c1', {
        'title': 'A',
        'items': [user('hi')],
        'history': [],
      });
      await save('c1', {'title': 'B'});
      var doc = jsonDecode((await send('GET', '/api/chats/c1')).body) as Map;
      expect(doc['title'], 'B');
      expect(doc['items'], hasLength(1));

      await save('c1', {
        'items': [user('hi'), user('again')],
        'history': [],
      });
      doc = jsonDecode((await send('GET', '/api/chats/c1')).body) as Map;
      expect(doc['title'], 'B');
      expect(doc['messageCount'], 2);
    },
  );

  test('auto-approve is kept per conversation', () async {
    await save('c1', {'autoApprove': true});
    await save('c2', {});
    final byId = {for (final c in await list()) c['id']: c};
    expect(byId['c1']!['autoApprove'], isTrue);
    expect(byId['c2']!['autoApprove'], isFalse);
  });

  test('the most recently used comes first', () async {
    await save('old', {});
    gw.clock.advance(const Duration(minutes: 1));
    await save('mid', {});
    gw.clock.advance(const Duration(minutes: 1));
    await save('new', {});
    expect([for (final c in await list()) c['id']], ['new', 'mid', 'old']);
    gw.clock.advance(const Duration(minutes: 1));
    await save('old', {'title': 'touched'});
    expect([for (final c in await list()) c['id']].first, 'old');
  });

  test('a conversation can be deleted', () async {
    await save('c1', {
      'items': [user('x')],
      'history': [],
    });
    expect((await send('DELETE', '/api/chats/c1')).statusCode, 204);
    expect(await list(), isEmpty);
    expect((await send('GET', '/api/chats/c1')).statusCode, 404);
    expect((await send('DELETE', '/api/chats/c1')).statusCode, 404);
  });

  test('keeps the most recent conversations up to the limit', () async {
    await gw.close();
    gw = await start(maxChats: 3);
    for (var i = 0; i < 5; i++) {
      await save('c$i', {});
      gw.clock.advance(const Duration(minutes: 1));
    }
    expect([for (final c in await list()) c['id']], ['c4', 'c3', 'c2']);
    expect((await send('GET', '/api/chats/c0')).statusCode, 404);
  });

  group('refuses bad input', () {
    Future<int> put(String id, Object? body) async =>
        (await send('PUT', '/api/chats/$id', body)).statusCode;

    test('ids with odd characters or too long', () async {
      expect(await put('a.b', {}), 400);
      expect(await put('a b', {}), 400);
      expect(await put('x' * 65, {}), 400);
      expect((await send('GET', '/api/chats/a.b')).statusCode, 400);
    });
    test('titles that are empty, long or not text', () async {
      expect(await put('c', {'title': ''}), 400);
      expect(await put('c', {'title': '   '}), 400);
      expect(await put('c', {'title': 'x' * 201}), 400);
      expect(await put('c', {'title': 7}), 400);
    });
    test('content that is not lists of objects', () async {
      expect(await put('c', {'items': 'x', 'history': []}), 400);
      expect(
        await put('c', {
          'items': [1],
          'history': [],
        }),
        400,
      );
      expect(
        await put('c', {
          'items': [],
          'history': [[]],
        }),
        400,
      );
    });
    test('items without history, or history without items', () async {
      expect(await put('c', {'items': []}), 400);
      expect(await put('c', {'history': []}), 400);
    });
    test('auto-approve that is not a boolean', () async {
      expect(await put('c', {'autoApprove': 'yes'}), 400);
    });
    test('nothing is stored by a refused request', () async {
      await put('c', {'title': ''});
      expect(await list(), isEmpty);
    });
  });

  group('size limits', () {
    test('other requests are capped at one megabyte', () async {
      final r = await send('POST', '/api/servers', {
        'name': 'x',
        'url': 'http://127.0.0.1:1/mcp',
        'headers': {'X': 'a' * (1024 * 1024 + 10)},
      });
      expect(r.statusCode, 413);
    });

    test('a conversation may be several megabytes', () async {
      final big = 'x' * (3 * 1024 * 1024);
      final meta = await save('big', {
        'items': [user(big)],
        'history': [],
      });
      expect(meta['messageCount'], 1);
      final doc = jsonDecode((await send('GET', '/api/chats/big')).body) as Map;
      expect(
        ((doc['items'] as List).first as Map)['text'],
        hasLength(big.length),
      );
    });

    test('but not unbounded', () async {
      final r = await send('PUT', '/api/chats/huge', {
        'items': [user('x' * (17 * 1024 * 1024))],
        'history': [],
      });
      expect(r.statusCode, 413);
      expect(await list(), isEmpty);
    });
  });

  group('between people', () {
    test('each sees only their own', () async {
      final ada = await member('ada', 1);
      final bob = await member('bob', 2);
      await save('a1', {'title': 'Ada\'s'}, session: ada);
      await save('b1', {'title': 'Bob\'s'}, session: bob);
      await save('t1', {'title': 'Token\'s'});
      expect([for (final c in await list(session: ada)) c['id']], ['a1']);
      expect([for (final c in await list(session: bob)) c['id']], ['b1']);
      expect([for (final c in await list()) c['id']], ['t1']);
    });

    test('someone else\'s conversation looks like it does not exist', () async {
      final ada = await member('ada', 1);
      final bob = await member('bob', 2);
      await save('a1', {
        'title': 'Private',
        'items': [user('secret')],
        'history': [],
      }, session: ada);

      expect((await send('GET', '/api/chats/a1', null, bob)).statusCode, 404);
      expect(
        (await send('DELETE', '/api/chats/a1', null, bob)).statusCode,
        404,
      );
      final put = await send('PUT', '/api/chats/a1', {
        'title': 'Hijacked',
      }, bob);
      expect(put.statusCode, 404);
      expect((await send('GET', '/api/chats/a1', null, ada)).statusCode, 200);
      final doc =
          jsonDecode((await send('GET', '/api/chats/a1', null, ada)).body)
              as Map;
      expect(doc['title'], 'Private');
      expect(doc['items'], hasLength(1));
    });

    test('the same member keeps them across sign-ins', () async {
      final first = await member('ada', 1);
      await save('a1', {'title': 'Mine'}, session: first);
      final second = await member('ada', 1);
      expect(
        [for (final c in await list(session: second)) c['title']],
        ['Mine'],
      );
    });
  });

  group('on the event stream', () {
    test('saving and deleting announce the conversation', () async {
      final events = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer $adminToken'},
      );
      addTearDown(events.close);
      await events.nextOf('ready');
      await save('c1', {'title': 'secret title'});
      var e = await events.nextOf('chat');
      expect(e.data, {'id': 'c1'}, reason: 'the id only, never the title');
      await send('DELETE', '/api/chats/c1');
      e = await events.nextOf('chat');
      expect(e.data, {'id': 'c1'});
    });
  });

  test('needs a credential', () async {
    final r = await gw.client.get(Uri.parse('${gw.base}/api/chats'));
    expect(r.statusCode, 401);
  });
}
