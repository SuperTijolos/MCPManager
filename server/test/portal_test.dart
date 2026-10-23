import 'dart:convert';

import 'package:test/test.dart';

import 'support/fake_upstream.dart';
import 'support/harness.dart';

void main() {
  late Harness gw;
  late FakeUpstream files;
  late FakeUpstream notes;
  late String token;

  Map<String, dynamic> echo(Map<String, dynamic> args) =>
      textResult('echo ${jsonEncode(args)}');

  setUp(() async {
    gw = await Harness.start();
    files = await FakeUpstream.start(
      tools: [
        tool(
          'read_file',
          description: 'Read a file',
          properties: {
            'path': {'type': 'string'},
          },
          required: ['path'],
          annotations: {'readOnlyHint': true},
        ),
        tool(
          'write_file',
          properties: {
            'path': {'type': 'string'},
          },
        ),
      ],
      handlers: {
        'read_file': (a) => textResult('contents of ${a['path']}'),
        'write_file': echo,
      },
    );
    notes = await FakeUpstream.start(
      tools: [tool('search'), tool('read_file')],
      handlers: {'search': echo, 'read_file': (_) => textResult('note')},
    );
  });

  tearDown(() async {
    await gw.close();
    await files.close();
    await notes.close();
  });

  Future<String> portalOver(
    List<FakeUpstream> ups, {
    String slug = 'dev',
  }) async {
    final ids = <String>[];
    for (var i = 0; i < ups.length; i++) {
      ids.add(
        await gw.addServer(i == 0 ? 'Files' : 'Notes', ups[i].url, id: 'srv$i'),
      );
    }
    final id = await gw.addPortal('Dev', ids, slug: slug);
    token = await gw.addToken('client');
    return id;
  }

  group('authentication', () {
    test(
      'a missing or unknown credential gets a 401 that points to OAuth',
      () async {
        await portalOver([files]);
        for (final tokenValue in [null, 'mcp_not_a_real_token']) {
          final r = await gw.post('dev', {
            'jsonrpc': '2.0',
            'id': 1,
            'method': 'ping',
          }, token: tokenValue);
          expect(r.statusCode, 401);
          expect(
            r.headers['www-authenticate'],
            'Bearer resource_metadata="${gw.base}/.well-known/oauth-protected-resource/mcp/dev"',
          );
        }
      },
    );

    test('the admin token does not open a portal', () async {
      await portalOver([files]);
      final r = await gw.post('dev', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      }, token: adminToken);
      expect(r.statusCode, 401);
    });

    test('a token limited to one portal is refused by the others', () async {
      final dev = await portalOver([files]);
      await gw.addPortal('Other', ['srv0'], slug: 'other');
      final limited = await gw.addToken('limited', portalIds: [dev]);

      expect(await gw.toolNames('dev', limited), isNotEmpty);
      final r = await gw.post('other', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: limited);
      expect(r.statusCode, 403);
      expect(jsonDecode(r.body)['error'], 'portal_access_denied');
    });

    test('a token with no limit opens every portal', () async {
      await portalOver([files]);
      await gw.addPortal('Other', ['srv0'], slug: 'other');
      expect(await gw.toolNames('other', token), isNotEmpty);
    });

    test('an expired token stops working', () async {
      await portalOver([files]);
      final short = await gw.addToken('short', days: 1);
      expect(await gw.toolNames('dev', short), isNotEmpty);

      gw.clock.advance(const Duration(days: 2));
      final r = await gw.post('dev', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }, token: short);
      expect(r.statusCode, 401);
    });

    test('use records "last used" on the token', () async {
      await portalOver([files]);
      expect(gw.gateway.store.state.tokens.single.lastUsedAt, isNull);
      await gw.toolNames('dev', token);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gw.gateway.store.state.tokens.single.lastUsedAt, isNotNull);
    });

    test('unknown and disabled portals are 404', () async {
      final dev = await portalOver([files]);
      final r = await gw.post('nope', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      }, token: token);
      expect(r.statusCode, 404);

      await gw.adminJson('PUT', '/api/portals/$dev', {'enabled': false});
      final off = await gw.post('dev', {
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'ping',
      }, token: token);
      expect(off.statusCode, 404);
    });
  });

  group('the MCP protocol', () {
    test(
      'initialize describes the portal and negotiates the version',
      () async {
        await portalOver([files]);
        await gw.adminJson(
          'PUT',
          '/api/portals/${gw.gateway.store.state.portals.single.id}',
          {'description': 'Developer tools'},
        );

        final reply = await gw.rpc(
          'dev',
          'initialize',
          token: token,
          params: {
            'protocolVersion': '2025-03-26',
            'capabilities': {},
            'clientInfo': {'name': 'test', 'version': '1'},
          },
        );
        final result = reply['result'] as Map;
        expect(reply['id'], 1);
        expect(result['protocolVersion'], '2025-03-26');
        expect(result['serverInfo'], {'name': 'Dev', 'version': '1.0.0'});
        expect(result['instructions'], 'Developer tools');
        expect((result['capabilities'] as Map).keys, ['tools']);

        final unknown = await gw.rpc(
          'dev',
          'initialize',
          token: token,
          params: {'protocolVersion': '1999-01-01'},
        );
        expect(unknown['result']['protocolVersion'], '2025-06-18');
      },
    );

    test('ping answers and notifications get a 202 with no body', () async {
      await portalOver([files]);
      expect((await gw.rpc('dev', 'ping', token: token))['result'], isEmpty);

      final r = await gw.post('dev', {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, token: token);
      expect(r.statusCode, 202);
      expect(r.body, isEmpty);
    });

    test('GET and DELETE are 405: there is no stream and no session', () async {
      await portalOver([files]);
      for (final method in ['GET', 'DELETE']) {
        final r = await gw.client.send(
          rawRequest(method, '${gw.base}/mcp/dev', {
            'authorization': 'Bearer $token',
          }),
        );
        expect(r.statusCode, 405, reason: method);
        expect(r.headers['allow'], 'POST');
      }
    });

    test('unknown methods and malformed input get JSON-RPC errors', () async {
      await portalOver([files]);
      final unknown = await gw.rpc(
        'dev',
        'resources/list',
        token: token,
        id: 7,
      );
      expect(unknown['id'], 7);
      expect(unknown['error']['code'], -32601);

      final notJson = await gw.post('dev', '{oops', token: token);
      expect(notJson.statusCode, 400);
      expect(jsonDecode(notJson.body)['error']['code'], -32700);

      final wrong = await gw.post('dev', {
        'id': 1,
        'method': 'ping',
      }, token: token);
      expect(jsonDecode(wrong.body)['error']['code'], -32600);
    });

    test('a batch is answered in order, leaving out notifications', () async {
      await portalOver([files]);
      final r = await gw.post('dev', [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'ping'},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      ], token: token);
      final replies = jsonDecode(r.body) as List;
      expect(replies.map((x) => (x as Map)['id']), [1, 2]);
      expect(
        jsonDecode(
          (await gw.post('dev', [], token: token)).body,
        )['error']['code'],
        -32600,
      );
    });

    test('a request that is too large is refused', () async {
      await portalOver([files]);
      final big = 'x' * (5 * 1024 * 1024);
      final r = await gw.post(
        'dev',
        '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"a":"$big"}}',
        token: token,
      );
      expect(r.statusCode, 413);
    });
  });

  group('tools', () {
    test('are listed with the server slug as their prefix', () async {
      await portalOver([files, notes]);
      final reply = await gw.rpc('dev', 'tools/list', token: token);
      final tools = (reply['result']['tools'] as List).cast<Map>();
      expect(tools.map((t) => t['name']), [
        'files__read_file',
        'files__write_file',
        'notes__search',
        'notes__read_file',
      ]);
      final read = tools.first;
      expect(read['description'], '[Files] Read a file');
      expect(read['inputSchema']['required'], ['path']);
      expect(read['annotations'], {'readOnlyHint': true});
    });

    test('keep unique names when two servers share a slug', () async {
      final a = await gw.addServer('Same', files.url, id: 'a');
      final b = await gw.addServer('Same', notes.url, id: 'b');
      await gw.adminJson('PUT', '/api/servers/b', {'slug': 'same-two'});
      await gw.addPortal('Dev', [a, b], slug: 'dev');
      token = await gw.addToken('c');
      final names = await gw.toolNames('dev', token);
      expect(names.toSet().length, names.length);
    });

    test(
      'are forwarded to the server they came from and answered as-is',
      () async {
        await portalOver([files, notes]);
        final reply = await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a.txt',
        });
        expect(gw.textOf(reply), 'contents of /a.txt');
        expect(reply['result'].containsKey('isError'), isFalse);

        final other = await gw.callTool('dev', token, 'notes__read_file');
        expect(gw.textOf(other), 'note');
        expect(
          files.requests.where((r) => r['method'] == 'tools/call'),
          hasLength(1),
        );
        expect(
          notes.requests.where((r) => r['method'] == 'tools/call'),
          hasLength(1),
        );
        // The upstream saw its own tool name, not the exposed one.
        final call = files.requests.firstWhere(
          (r) => r['method'] == 'tools/call',
        );
        expect(call['params']['name'], 'read_file');
      },
    );

    test('keep the full upstream result, not only its text', () async {
      files.handlers['read_file'] = (_) => {
        'content': [
          {'type': 'text', 'text': 'hello'},
          {'type': 'image', 'data': 'AAAA', 'mimeType': 'image/png'},
        ],
        'structuredContent': {'size': 5},
      };
      await portalOver([files]);
      final reply = await gw.callTool('dev', token, 'files__read_file', {
        'path': 'x',
      });
      final result = reply['result'] as Map;
      expect((result['content'] as List).length, 2);
      expect((result['content'] as List).last['type'], 'image');
      expect(result['structuredContent'], {'size': 5});
    });

    test('pass an upstream tool error through as an error result', () async {
      files.handlers['read_file'] = (_) =>
          textResult('no such file', isError: true);
      await portalOver([files]);
      final reply = await gw.callTool('dev', token, 'files__read_file', {
        'path': 'x',
      });
      expect(reply['result']['isError'], isTrue);
      expect(gw.textOf(reply), 'no such file');
    });

    test('an unknown tool is an invalid-params error', () async {
      await portalOver([files]);
      final reply = await gw.callTool('dev', token, 'files__nothing');
      expect(reply['error']['code'], -32602);
      expect(reply['error']['message'], contains('Unknown tool'));
    });

    test('a call without a name is an invalid-params error', () async {
      await portalOver([files]);
      final reply = await gw.rpc('dev', 'tools/call', token: token, params: {});
      expect(reply['error']['code'], -32602);
    });

    test('left out of a portal can no longer be called', () async {
      final dev = await portalOver([files]);
      await gw.adminJson('PUT', '/api/portals/$dev', {
        'excludedTools': ['srv0/write_file'],
      });

      expect(await gw.toolNames('dev', token), ['files__read_file']);
      final reply = await gw.callTool('dev', token, 'files__write_file');
      expect(reply['error']['code'], -32602);
      expect(files.requests.where((r) => r['method'] == 'tools/call'), isEmpty);
    });

    test(
      'of a disabled server disappear, and so does the server\'s portal membership',
      () async {
        final dev = await portalOver([files, notes]);
        await gw.adminJson('PUT', '/api/servers/srv1', {'enabled': false});
        expect(await gw.toolNames('dev', token), [
          'files__read_file',
          'files__write_file',
        ]);

        await gw.adminJson('PUT', '/api/portals/$dev', {
          'servers': [
            {'serverId': 'srv0', 'enabled': false},
            'srv1',
          ],
        });
        expect(await gw.toolNames('dev', token), isEmpty);
      },
    );
  });

  group('rules and overrides', () {
    Future<void> setRules(Map<String, dynamic> body) =>
        gw.adminJson('PUT', '/api/rules', body);

    test('hide a tool', () async {
      await portalOver([files]);
      await setRules({
        'rules': [],
        'overrides': {
          'srv0/write_file': {'hidden': true},
        },
      });
      expect(await gw.toolNames('dev', token), ['files__read_file']);
      expect(
        (await gw.callTool('dev', token, 'files__write_file'))['error']['code'],
        -32602,
      );
    });

    test('add instructions to a description', () async {
      await portalOver([files]);
      await setRules({
        'rules': [],
        'overrides': {
          'srv0/read_file': {'instructions': 'Never read /etc.'},
        },
      });
      final tools =
          ((await gw.rpc('dev', 'tools/list', token: token))['result']['tools']
                  as List)
              .cast<Map>();
      expect(
        tools.first['description'],
        allOf(contains('Read a file'), contains('Never read /etc.')),
      );
    });

    test(
      'require a reason that is kept in the audit log, not sent upstream',
      () async {
        await portalOver([files]);
        await setRules({
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
                  'description': 'Why call it',
                },
              ],
            },
          ],
          'overrides': {},
        });

        final schema =
            ((await gw.rpc(
                          'dev',
                          'tools/list',
                          token: token,
                        ))['result']['tools']
                        as List)
                    .first['inputSchema']
                as Map;
        expect(
          (schema['properties'] as Map).keys,
          containsAll(['path', 'reason']),
        );
        expect(schema['required'], containsAll(['path', 'reason']));

        final missing = await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a',
        });
        expect(missing['result']['isError'], isTrue);
        expect(
          gw.textOf(missing),
          contains('Missing required argument: reason'),
        );
        expect(
          files.requests.where((r) => r['method'] == 'tools/call'),
          isEmpty,
        );

        final ok = await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a',
          'reason': 'checking',
        });
        expect(gw.textOf(ok), 'contents of /a');
        final sent = files.requests.firstWhere(
          (r) => r['method'] == 'tools/call',
        );
        expect(sent['params']['arguments'], {
          'path': '/a',
        }, reason: 'the reason stays here');

        final event = gw.gateway.audit.recent().first;
        expect(event.context, contains('checking'));
        expect(event.rules, ['Why']);
      },
    );

    test('inject a fixed value the client never sees', () async {
      await portalOver([files]);
      await setRules({
        'rules': [
          {
            'id': 'ws',
            'name': 'Workspace',
            'scope': 'all',
            'args': [
              {
                'name': 'workspace',
                'type': 'string',
                'source': 'hardcoded',
                'fixedValue': 'dev',
              },
            ],
          },
        ],
        'overrides': {},
      });
      final schema =
          ((await gw.rpc('dev', 'tools/list', token: token))['result']['tools']
                      as List)
                  .last['inputSchema']
              as Map;
      expect((schema['properties'] as Map).containsKey('workspace'), isFalse);

      await gw.callTool('dev', token, 'files__write_file', {'path': '/b'});
      final sent = files.requests.lastWhere((r) => r['method'] == 'tools/call');
      expect(sent['params']['arguments'], {'path': '/b', 'workspace': 'dev'});
    });
  });

  group('upstreams that misbehave', () {
    test('a server that is down is left out; the others still work', () async {
      await portalOver([files, notes]);
      await files.close();
      gw.gateway.pool.invalidate('srv0');

      final names = await gw.toolNames('dev', token);
      expect(names, ['notes__search', 'notes__read_file']);

      final preview = await gw.adminJson(
        'GET',
        '/api/portals/${gw.gateway.store.state.portals.single.id}/tools?refresh=1',
      );
      expect((preview['problems'] as Map).keys, ['srv0']);
    });

    test(
      'a call to a server that went down comes back as a tool error',
      () async {
        await portalOver([files]);
        await gw.toolNames('dev', token);
        await files.close();

        final reply = await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a',
        });
        expect(reply['result']['isError'], isTrue);
        expect(gw.textOf(reply), startsWith('Upstream error:'));
        final event = gw.gateway.audit.recent().first;
        expect(event.status, 'error');
      },
    );

    test('the gateway sends the server\'s own headers upstream', () async {
      files.requireToken = 'upstream-secret';
      final id = await gw.addServer(
        'Files',
        files.url,
        id: 'srv0',
        headers: {'Authorization': 'Bearer upstream-secret'},
      );
      await gw.addPortal('Dev', [id], slug: 'dev');
      token = await gw.addToken('c');

      expect(await gw.toolNames('dev', token), isNotEmpty);
      expect(
        (await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a',
        }))['result'],
        isNotNull,
      );
      expect(
        files.headers.every(
          (h) => h['authorization'] == 'Bearer upstream-secret',
        ),
        isTrue,
      );
      // The client's own credential is never passed on.
      expect(
        files.headers.any((h) => (h['authorization'] ?? '').contains(token)),
        isFalse,
      );
    });

    test(
      'one connection serves many calls, and a restart is recovered from',
      () async {
        await portalOver([files]);
        for (var i = 0; i < 3; i++) {
          await gw.callTool('dev', token, 'files__read_file', {'path': '/$i'});
        }
        expect(
          files.requests.where((r) => r['method'] == 'initialize'),
          hasLength(1),
        );

        final port = files.port;
        await files.close();
        files = await FakeUpstream.start(
          tools: [
            tool(
              'read_file',
              properties: {
                'path': {'type': 'string'},
              },
            ),
          ],
          handlers: {'read_file': (a) => textResult('again ${a['path']}')},
          port: port,
        );
        final reply = await gw.callTool('dev', token, 'files__read_file', {
          'path': '/x',
        });
        expect(gw.textOf(reply), 'again /x');
      },
    );

    test('the tool list is cached briefly, and refreshed when asked', () async {
      await portalOver([files]);
      await gw.toolNames('dev', token);
      await gw.toolNames('dev', token);
      expect(
        files.requests.where((r) => r['method'] == 'tools/list'),
        hasLength(1),
      );

      final id = gw.gateway.store.state.portals.single.id;
      await gw.adminJson('GET', '/api/portals/$id/tools?refresh=1');
      expect(
        files.requests.where((r) => r['method'] == 'tools/list'),
        hasLength(2),
      );
    });
  });

  group('the audit log', () {
    test(
      'records successes, errors and unknown tools without secrets',
      () async {
        await portalOver([files]);
        await gw.callTool('dev', token, 'files__read_file', {
          'path': '/a',
          'password': 'hunter2',
        });
        files.handlers['read_file'] = (_) => textResult('boom', isError: true);
        await gw.callTool('dev', token, 'files__read_file', {'path': '/b'});
        await gw.callTool('dev', token, 'files__ghost');

        final r = await gw.adminJson('GET', '/api/audit');
        final events = (r['events'] as List).cast<Map>();
        expect(events.map((e) => e['status']), ['denied', 'error', 'success']);
        final ok = events.last;
        expect(ok['tool'], 'read_file');
        expect(ok['exposedName'], 'files__read_file');
        expect(ok['serverName'], 'Files');
        expect(ok['portalSlug'], 'dev');
        expect(ok['principal'], {
          'kind': 'token',
          'id': isA<String>(),
          'name': 'client',
        });
        expect(ok['durationMs'], isA<int>());
        expect(jsonEncode(r), isNot(contains('hunter2')));
        expect(ok['args'], contains('[redacted]'));
      },
    );

    test('can be filtered by portal, status and text', () async {
      final dev = await portalOver([files]);
      await gw.addPortal('Other', ['srv0'], slug: 'other');
      await gw.callTool('dev', token, 'files__read_file', {'path': '/a'});
      await gw.callTool('other', token, 'files__write_file', {
        'path': '/needle',
      });
      files.handlers['read_file'] = (_) => textResult('x', isError: true);
      await gw.callTool('dev', token, 'files__read_file', {'path': '/c'});

      Future<List> events(String query) async =>
          (await gw.adminJson('GET', '/api/audit$query'))['events'] as List;
      expect(await events('?portal=$dev'), hasLength(2));
      expect(await events('?status=error'), hasLength(1));
      expect(await events('?q=needle'), hasLength(1));
      expect(await events('?limit=1'), hasLength(1));
    });

    test('needs the admin token', () async {
      final r = await gw.admin('GET', '/api/audit', null, {});
      expect(r.statusCode, 401);
    });
  });

  group('CORS', () {
    test('portals answer a browser preflight for any origin', () async {
      final r = await gw.client.send(
        rawRequest('OPTIONS', '${gw.base}/mcp/dev', {
          'origin': 'https://app.example.com',
          'access-control-request-method': 'POST',
          'access-control-request-headers': 'authorization,content-type',
        }),
      );
      expect(r.statusCode, 204);
      expect(r.headers['access-control-allow-origin'], '*');
      expect(
        r.headers['access-control-allow-headers'],
        contains('authorization'),
      );
    });

    test('the admin API answers only localhost and allowed origins', () async {
      final custom = await Harness.start(
        allowedOrigins: ['https://admin.example.com'],
      );
      addTearDown(custom.close);

      Future<String?> allowOrigin(String origin) async {
        final r = await custom.client.send(
          rawRequest('OPTIONS', '${custom.base}/api/status', {
            'origin': origin,
            'access-control-request-method': 'GET',
          }),
        );
        return r.headers['access-control-allow-origin'];
      }

      expect(
        await allowOrigin('http://localhost:5173'),
        'http://localhost:5173',
      );
      expect(
        await allowOrigin('http://127.0.0.1:9090'),
        'http://127.0.0.1:9090',
      );
      expect(
        await allowOrigin('https://admin.example.com'),
        'https://admin.example.com',
      );
      expect(await allowOrigin('https://evil.example.com'), isNull);
    });

    test('a response carries nosniff', () async {
      final r = await gw.client.get(Uri.parse('${gw.base}/health'));
      expect(r.headers['x-content-type-options'], 'nosniff');
      expect(jsonDecode(r.body)['ok'], isTrue);
    });
  });
}
