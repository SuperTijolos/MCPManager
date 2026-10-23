import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/fake_github.dart';
import 'support/fake_llm.dart';
import 'support/github_login.dart';
import 'support/harness.dart';
import 'support/sse.dart';

void main() {
  late Harness gw;
  late FakeLlm llm;

  setUp(() async {
    gw = await Harness.start();
    llm = await FakeLlm.start();
  });

  tearDown(() async {
    await gw.close();
    await llm.close();
  });

  Future<Map<String, dynamic>> create([Map<String, dynamic>? extra]) =>
      gw.adminJson('POST', '/api/llm/providers', {
        'name': 'Local',
        'kind': 'openaiCompatible',
        'baseUrl': llm.v1,
        ...?extra,
      });

  group('providers', () {
    test('start empty', () async {
      final r = await gw.admin('GET', '/api/llm/providers');
      expect(jsonDecode(r.body), isEmpty);
    });

    test('are created and listed', () async {
      final p = await create({
        'models': ['model-a', 'model-b'],
        'contextLength': 8192,
      });
      expect(p['id'], startsWith('llm_'));
      expect(p['name'], 'Local');
      expect(p['kind'], 'openaiCompatible');
      expect(p['baseUrl'], llm.v1);
      expect(p['models'], ['model-a', 'model-b']);
      expect(p['contextLength'], 8192);
      expect(p['hasKey'], isFalse);
      final list = jsonDecode(
        (await gw.admin('GET', '/api/llm/providers')).body,
      );
      expect(list, hasLength(1));
    });

    test('keep their order and can be fetched, changed and deleted', () async {
      final a = await create({'name': 'A'});
      final b = await create({'name': 'B'});
      var list =
          jsonDecode((await gw.admin('GET', '/api/llm/providers')).body)
              as List;
      expect([for (final p in list) p['name']], ['A', 'B']);

      final one = await gw.adminJson('GET', '/api/llm/providers/${a['id']}');
      expect(one['name'], 'A');
      final changed = await gw.adminJson(
        'PUT',
        '/api/llm/providers/${a['id']}',
        {'name': 'A2'},
      );
      expect(changed['name'], 'A2');
      expect(changed['baseUrl'], llm.v1, reason: 'unchanged fields stay');

      expect(
        (await gw.admin('DELETE', '/api/llm/providers/${b['id']}')).statusCode,
        204,
      );
      list =
          jsonDecode((await gw.admin('GET', '/api/llm/providers')).body)
              as List;
      expect(list, hasLength(1));
      expect(
        (await gw.admin('GET', '/api/llm/providers/${b['id']}')).statusCode,
        404,
      );
      expect(
        (await gw.admin('DELETE', '/api/llm/providers/${b['id']}')).statusCode,
        404,
      );
    });

    test('PUT creates under the id you choose', () async {
      final p = await gw.adminJson('PUT', '/api/llm/providers/mine', {
        'name': 'Mine',
        'kind': 'ollama',
        'baseUrl': 'http://localhost:11434',
      });
      expect(p['id'], 'mine');
    });

    test('tidy the address and the model list', () async {
      final p = await create({
        'baseUrl': '${llm.v1}///',
        'models': ['a', ' a ', '', 'b'],
      });
      expect(p['baseUrl'], llm.v1);
      expect(p['models'], ['a', 'b']);
    });

    test('the context length can be cleared', () async {
      final p = await create({'contextLength': 4096});
      final cleared = await gw.adminJson(
        'PUT',
        '/api/llm/providers/${p['id']}',
        {'contextLength': null},
      );
      expect(cleared['contextLength'], isNull);
    });

    group('are refused when', () {
      Future<int> status(Map<String, dynamic> body) async => (await gw.admin(
        'POST',
        '/api/llm/providers',
        {'name': 'x', 'kind': 'ollama', 'baseUrl': 'http://h:1', ...body},
      )).statusCode;

      test('the name is missing or long', () async {
        expect(await status({'name': ''}), 400);
        expect(await status({'name': 'x' * 101}), 400);
        expect(await status({'name': 3}), 400);
      });
      test('the kind is unknown', () async {
        expect(await status({'kind': 'magic'}), 400);
        expect(await status({'kind': null}), 400);
      });
      test('the address is not an http(s) URL', () async {
        expect(await status({'baseUrl': 'ftp://h'}), 400);
        expect(await status({'baseUrl': 'localhost'}), 400);
        expect(await status({'baseUrl': 'http://h:1/v1?key=secret'}), 400);
      });
      test('the models are not a list of names', () async {
        expect(await status({'models': 'a'}), 400);
        expect(
          await status({
            'models': [1],
          }),
          400,
        );
      });
      test('the context length is silly', () async {
        expect(await status({'contextLength': 10}), 400);
        expect(await status({'contextLength': 'big'}), 400);
        expect(await status({'contextLength': 1.5}), 400);
      });
      test('an OpenRouter key is malformed', () async {
        final r = await gw.admin('POST', '/api/llm/providers', {
          'name': 'OR',
          'kind': 'openaiCompatible',
          'baseUrl': 'https://openrouter.ai/api/v1',
          'apiKey': 'sk-or-v1-short',
        });
        expect(r.statusCode, 400);
        expect(jsonDecode(r.body)['message'], contains('OpenRouter'));
      });
    });

    test('nothing is stored by a refused request', () async {
      await gw.admin('POST', '/api/llm/providers', {
        'name': 'x',
        'kind': 'nope',
        'baseUrl': 'http://h',
      });
      expect(
        jsonDecode((await gw.admin('GET', '/api/llm/providers')).body),
        isEmpty,
      );
    });

    test('need a credential', () async {
      final r = await gw.client.get(Uri.parse('${gw.base}/api/llm/providers'));
      expect(r.statusCode, 401);
    });

    test('announce a change on the event stream', () async {
      final events = await SseReader.open(
        '${gw.base}/api/events',
        headers: {'authorization': 'Bearer $adminToken'},
      );
      addTearDown(events.close);
      await events.nextOf('ready');
      await create();
      expect((await events.nextOf('changed')).data['collections'], [
        'llmProviders',
      ]);
    });
  });

  group('the key', () {
    const key = 'sk-test-key-0123456789';

    test('is kept but never shown', () async {
      final p = await create({'apiKey': key});
      expect(p['hasKey'], isTrue);
      final seen = [
        jsonEncode(p),
        (await gw.admin('GET', '/api/llm/providers')).body,
        (await gw.admin('GET', '/api/llm/providers/${p['id']}')).body,
        (await gw.admin('GET', '/api/status')).body,
      ].join();
      expect(seen, isNot(contains(key)));
      expect(seen, isNot(contains('apiKey')));
    });

    test('is cleaned of quotes and Bearer prefixes', () async {
      final p = await create({'apiKey': '"Bearer Bearer $key"'});
      await gw.admin('GET', '/api/llm/providers/${p['id']}/proxy/models');
      expect(llm.requests.last.headers['authorization'], 'Bearer $key');
    });

    test('stays when other fields change', () async {
      final p = await create({'apiKey': key});
      await gw.adminJson('PUT', '/api/llm/providers/${p['id']}', {
        'name': 'Renamed',
      });
      await gw.admin('GET', '/api/llm/providers/${p['id']}/proxy/models');
      expect(llm.requests.last.headers['authorization'], 'Bearer $key');
    });

    test('can be replaced and removed', () async {
      final p = await create({'apiKey': key});
      await gw.adminJson('PUT', '/api/llm/providers/${p['id']}', {
        'apiKey': 'sk-other-key-9876543210',
      });
      await gw.admin('GET', '/api/llm/providers/${p['id']}/proxy/models');
      expect(
        llm.requests.last.headers['authorization'],
        'Bearer sk-other-key-9876543210',
      );

      final cleared = await gw.adminJson(
        'PUT',
        '/api/llm/providers/${p['id']}',
        {'clearApiKey': true},
      );
      expect(cleared['hasKey'], isFalse);
      await gw.admin('GET', '/api/llm/providers/${p['id']}/proxy/models');
      expect(llm.requests.last.headers.containsKey('authorization'), isFalse);
    });
  });

  group('the proxy', () {
    late String id;
    setUp(
      () async => id =
          (await create({'apiKey': 'sk-test-key-0123456789'}))['id'] as String,
    );

    Future<http.Response> via(
      String path, {
      String method = 'GET',
      Object? body,
      Map<String, String>? headers,
    }) {
      final request = http.Request(
        method,
        Uri.parse('${gw.base}/api/llm/providers/$id/proxy/$path'),
      )..headers.addAll({'authorization': 'Bearer $adminToken', ...?headers});
      if (body != null) request.body = body is String ? body : jsonEncode(body);
      return gw.client.send(request).then(http.Response.fromStream);
    }

    test(
      'forwards a GET below the provider\'s address, with the key',
      () async {
        final r = await via('models');
        expect(r.statusCode, 200);
        expect(jsonDecode(r.body)['data'][0]['id'], 'model-a');
        final seen = llm.requests.single;
        expect(seen.path, '/v1/models');
        expect(seen.headers['authorization'], 'Bearer sk-test-key-0123456789');
      },
    );

    test('forwards a POST body, content type and query', () async {
      llm.gate.complete();
      final r = await via(
        'chat/completions?x=1&y=two',
        method: 'POST',
        body: {'model': 'a', 'stream': true},
        headers: {'content-type': 'application/json'},
      );
      expect(r.statusCode, 200);
      final seen = llm.requests.single;
      expect(seen.method, 'POST');
      expect(seen.query, 'x=1&y=two');
      expect(seen.headers['content-type'], contains('application/json'));
      expect(jsonDecode(seen.body), {'model': 'a', 'stream': true});
    });

    test('never passes the dashboard\'s own credentials on', () async {
      await via(
        'models',
        headers: {'cookie': 'mcp_session=mcps_secret', 'x-api-key': 'leak'},
      );
      final h = llm.requests.single.headers;
      expect(h['authorization'], isNot(contains(adminToken)));
      expect(h.containsKey('cookie'), isFalse);
      expect(h.containsKey('x-api-key'), isFalse);
      expect(jsonEncode(h), isNot(contains(adminToken)));
    });

    test('gives the provider\'s status and body back as they are', () async {
      final r = await via('unauthorized');
      expect(r.statusCode, 401);
      expect(jsonDecode(r.body), {'error': 'bad key'});
      expect((await via('nothing')).statusCode, 404);
    });

    test(
      'streams: the first part arrives before the reply is finished',
      () async {
        final request =
            http.Request(
                'POST',
                Uri.parse(
                  '${gw.base}/api/llm/providers/$id/proxy/chat/completions',
                ),
              )
              ..headers['authorization'] = 'Bearer $adminToken'
              ..body = '{}';
        final response = await gw.client.send(request);
        final chunks = StreamIterator(response.stream.transform(utf8.decoder));
        expect(
          await chunks.moveNext().timeout(const Duration(seconds: 5)),
          isTrue,
        );
        expect(chunks.current, contains('first'));
        expect(
          llm.gate.isCompleted,
          isFalse,
          reason: 'the reply is still going',
        );

        llm.gate.complete();
        final rest = StringBuffer();
        while (await chunks.moveNext()) {
          rest.write(chunks.current);
        }
        expect(rest.toString(), contains('[DONE]'));
      },
    );

    test(
      'stops the request at the provider when the dashboard stops listening',
      () async {
        final client = http.Client();
        final request =
            http.Request(
                'POST',
                Uri.parse(
                  '${gw.base}/api/llm/providers/$id/proxy/chat/completions',
                ),
              )
              ..headers['authorization'] = 'Bearer $adminToken'
              ..body = '{}';
        final response = await client.send(request);
        final chunks = StreamIterator(response.stream.transform(utf8.decoder));
        await chunks.moveNext();
        client.close(); // the person pressed Stop
        llm.gate.complete(); // the model produces more
        await llm.disconnected.future.timeout(const Duration(seconds: 8));
      },
    );

    group('refuses', () {
      test('a path that climbs out', () async {
        // Dot segments are resolved before routing, so they can never leave
        // the provider's address: they land on another route of this API.
        expect((await via('%2e%2e/admin')).statusCode, isNot(200));
        expect((await via('%2e%2e/%2e%2e/x')).statusCode, isNot(200));
        expect(llm.requests, isEmpty);
        // Encoded slashes are refused outright.
        expect((await via('%2fetc')).statusCode, 400);
        expect((await via('a%2f..%2fb')).statusCode, 400);
        expect(llm.requests, isEmpty);
        // Inside the prefix, a resolved dot segment is simply a shorter path.
        await via('a/%2e%2e/b');
        expect(llm.requests.single.path, '/v1/b');
      });
      test('methods other than GET and POST', () async {
        expect((await via('models', method: 'DELETE')).statusCode, 405);
        expect(
          (await via('models', method: 'PUT', body: '{}')).statusCode,
          405,
        );
      });
      test('an unknown provider', () async {
        final r = await gw.admin('GET', '/api/llm/providers/nope/proxy/models');
        expect(r.statusCode, 404);
        expect(llm.requests, isEmpty);
      });
      test('callers without a credential', () async {
        final r = await gw.client.get(
          Uri.parse('${gw.base}/api/llm/providers/$id/proxy/models'),
        );
        expect(r.statusCode, 401);
        expect(llm.requests, isEmpty);
      });
      test('a request body over the limit', () async {
        final r = await via(
          'chat/completions',
          method: 'POST',
          body: 'x' * (17 * 1024 * 1024),
        );
        expect(r.statusCode, 413);
        expect(llm.requests, isEmpty);
      });
    });

    test('says so when the provider cannot be reached', () async {
      await llm.close();
      final r = await via('models');
      expect(r.statusCode, 502);
      expect(jsonDecode(r.body)['error'], 'provider_unreachable');
    });

    test('works for a signed-in member too', () async {
      final github = await FakeGitHub.start();
      addTearDown(github.close);
      await gw.close();
      gw = await Harness.start(github: github, githubOrgs: ['acme']);
      final p = await create({'apiKey': 'sk-test-key-0123456789'});
      final session = await gw.signInAs(
        github,
        GhUser(1, 'ada', orgs: ['acme']),
      );
      final r = await gw.admin(
        'GET',
        '/api/llm/providers/${p['id']}/proxy/models',
        null,
        {'authorization': 'Bearer $session'},
      );
      expect(r.statusCode, 200);
      expect(
        llm.requests.last.headers['authorization'],
        'Bearer sk-test-key-0123456789',
      );
      expect(
        llm.requests.last.headers['authorization'],
        isNot(contains(session)),
      );
    });
  });
}
