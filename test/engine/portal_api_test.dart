import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_auto_connection.dart';
import 'package:mcp_manager/engine/portal/portal_api.dart';
import 'package:mcp_manager/engine/portal/portal_models.dart';

import '../support/fakes.dart';
import '../support/gateway_harness.dart';

final _tools = [
  {
    'name': 'read_file',
    'description': 'Read a file',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
      'required': ['path'],
    },
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'write_file',
    'description': 'Write',
    'inputSchema': {'type': 'object'},
  },
];

void main() {
  late TestGateway gw;
  late FakeMcpServer upstream;
  late PortalApi api;

  setUp(() async {
    upstream = FakeMcpServer(
      tools: _tools,
      handlers: {'read_file': (a) => textResult('contents of ${a['path']}')},
    );
    gw = await TestGateway.start(upstream: upstream);
    api = PortalApi(
      baseUrl: gatewayUrl,
      token: gatewayAdminToken,
      client: gw.client,
    );
  });

  tearDown(() => gw.close());

  group('PortalApi against the real gateway', () {
    test('reads its status', () async {
      final status = await api.status();
      expect(status.version, '1.0.0');
      expect(status.baseUrl, gatewayUrl);
      expect(status.servers, 0);
    });

    test(
      'saves a server under the id given and never gets its headers back',
      () async {
        final saved = await api.saveServer(
          id: 'srv_app',
          name: 'Files',
          url: 'https://files.test/mcp',
          headers: {'Authorization': 'Bearer s3cret'},
          transport: 'streamable-http',
        );
        expect(saved.id, 'srv_app');
        expect(saved.slug, 'files');
        expect(saved.headerNames, ['Authorization']);
        expect(saved.transport, 'streamable-http');
        expect((await api.servers()).single.headerNames, ['Authorization']);
        // The gateway really holds the secret, to use it upstream.
        expect(
          gw.state.servers.single.headers['Authorization'],
          'Bearer s3cret',
        );
      },
    );

    test('tests a server', () async {
      await api.saveServer(
        id: 's',
        name: 'Files',
        url: 'https://files.test/mcp',
      );
      final result = await api.testServer('s');
      expect(result.ok, isTrue);
      expect(result.toolCount, 2);
      expect(result.tools, ['read_file', 'write_file']);
      expect(result.serverName, 'fake');
    });

    test('creates, updates, previews and deletes a portal', () async {
      await api.saveServer(
        id: 's',
        name: 'Files',
        url: 'https://files.test/mcp',
      );
      final portal = await api.savePortal(
        name: 'Dev Tools',
        description: 'For developers',
        servers: [const GatewayPortalServer('s')],
      );
      expect(portal.slug, 'dev-tools');
      expect(portal.endpoint, '$gatewayUrl/mcp/dev-tools');
      expect(portal.description, 'For developers');
      expect(portal.servers.single.serverId, 's');

      await api.savePortal(
        id: portal.id,
        name: 'Dev Tools',
        excludedTools: ['s/write_file'],
      );
      final shown = await api.portalTools(portal.id);
      expect(shown.tools.map((t) => t.name), ['files__read_file']);
      expect(shown.tools.single.readOnly, isTrue);

      final all = await api.portalTools(portal.id, includeHidden: true);
      final write = all.tools.firstWhere((t) => t.name == 'files__write_file');
      expect(write.excluded, isTrue);
      expect(write.key, 's/write_file');

      await api.deletePortal(portal.id);
      expect(await api.portals(), isEmpty);
    });

    test('creates a token, shows its secret once and revokes it', () async {
      final created = await api.createToken(name: 'Claude', expiresInDays: 30);
      expect(created.secret, startsWith('mcp_'));
      expect(created.token.prefix, created.secret.substring(0, 8));
      expect(created.token.expiresAt, isNotNull);

      final listed = (await api.tokens()).single;
      expect(listed.active(DateTime.now()), isTrue);
      expect(listed.portalIds, isEmpty);

      await api.revokeToken(listed.id);
      expect((await api.tokens()).single.active(DateTime.now()), isFalse);
    });

    test('sends rules in the app\'s own format', () async {
      await api.putRules({
        'rules': [
          {
            'id': 'why',
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
      });
      expect((await api.status()).rules, 1);
      expect((await api.rules())['overrides'], {
        's/t': {'hidden': true, 'instructions': ''},
      });
    });

    test('says what went wrong', () async {
      final wrong = PortalApi(
        baseUrl: gatewayUrl,
        token: 'wrong-wrong-wrong-wrong',
        client: gw.client,
      );
      await expectLater(
        wrong.status(),
        throwsA(
          isA<PortalApiException>()
              .having((e) => e.unauthorized, 'unauthorized', isTrue)
              .having((e) => e.message, 'message', contains('admin token')),
        ),
      );

      await api.saveServer(id: 'a', name: 'Same', url: 'https://a.test/mcp');
      await expectLater(
        api.saveServer(
          id: 'b',
          name: 'Other',
          url: 'https://b.test/mcp',
          slug: 'same',
        ),
        throwsA(
          isA<PortalApiException>().having(
            (e) => e.message,
            'message',
            contains('name prefix'),
          ),
        ),
      );
      await expectLater(
        api.savePortal(name: 'x', slug: 'Bad Slug'),
        throwsA(
          isA<PortalApiException>().having(
            (e) => e.code,
            'code',
            'invalid_slug',
          ),
        ),
      );
    });

    test('reports an unreachable or foreign server', () async {
      final down = PortalApi(
        baseUrl: 'http://nowhere.test',
        token: 'x',
        client: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      await expectLater(
        down.status(),
        throwsA(
          isA<PortalApiException>().having(
            (e) => e.message,
            'message',
            contains('Could not reach the gateway'),
          ),
        ),
      );

      final foreign = PortalApi(
        baseUrl: 'http://web.test',
        token: 'x',
        client: MockClient((_) async => http.Response('<html>hi</html>', 200)),
      );
      await expectLater(
        foreign.status(),
        throwsA(
          isA<PortalApiException>().having(
            (e) => e.message,
            'message',
            contains('did not answer like'),
          ),
        ),
      );
    });
  });

  group('the app\'s own MCP client against a portal', () {
    Future<String> openPortal() async {
      await api.saveServer(
        id: 's',
        name: 'Files',
        url: 'https://files.test/mcp',
      );
      await api.savePortal(
        name: 'Dev',
        slug: 'dev',
        servers: [const GatewayPortalServer('s')],
      );
      return (await api.createToken(name: 'client')).secret;
    }

    McpServerConfig config(
      String secret, {
      McpTransport transport = McpTransport.streamableHttp,
    }) => McpServerConfig(
      id: 'portal',
      name: 'Portal',
      url: '$gatewayUrl/mcp/dev',
      headers: {'Authorization': 'Bearer $secret'},
      transport: transport,
    );

    test('connects, lists the exposed tools and calls one', () async {
      final secret = await openPortal();
      final connection = createMcpConnection(
        config(secret),
        httpClient: gw.client,
      );

      final info = await connection.connect();
      expect(info.name, 'Dev');
      final tools = await connection.listTools();
      expect(tools.map((t) => t.name), [
        'files__read_file',
        'files__write_file',
      ]);
      expect(tools.first.isReadOnly, isTrue);

      final result = await connection.callTool('files__read_file', {
        'path': '/a.txt',
      });
      expect(result.text, 'contents of /a.txt');
      expect(result.isError, isFalse);
      connection.close();
    });

    test('auto-detection finds the Streamable HTTP endpoint', () async {
      final secret = await openPortal();
      final connection = createMcpConnection(
        config(secret, transport: McpTransport.auto),
        httpClient: gw.client,
      );
      await connection.connect();
      expect(connection.transport, McpTransport.streamableHttp);
      expect(await connection.listTools(), hasLength(2));
    });

    test(
      'without a token it is told to sign in, with the discovery pointer',
      () async {
        await openPortal();
        final connection = createMcpConnection(
          config('not-a-token'),
          httpClient: gw.client,
        );
        await expectLater(
          connection.connect(),
          throwsA(
            isA<McpAuthRequired>().having(
              (e) => e.wwwAuthenticate,
              'wwwAuthenticate',
              contains('/.well-known/oauth-protected-resource/mcp/dev'),
            ),
          ),
        );
      },
    );

    test('what the client did shows up in the gateway\'s audit log', () async {
      final secret = await openPortal();
      final connection = createMcpConnection(
        config(secret),
        httpClient: gw.client,
      );
      await connection.connect();
      await connection.callTool('files__read_file', {'path': '/x'});

      final events = await api.audit();
      final event = events.single;
      expect(event.title, 'Files · read_file');
      expect(event.status, 'success');
      expect(event.callerName, 'client');
      expect(event.callerKind, 'token');
      expect(event.portalSlug, 'dev');
      expect(jsonDecode(event.args!), {'path': '/x'});
      expect(event.result, 'contents of /x');
    });
  });

  group('models', () {
    test('slugify matches what the gateway makes of a name', () {
      expect(slugify('Dev Tools!'), 'dev-tools');
      expect(slugify('  --A  b--'), 'a-b');
      expect(slugify('!!!'), '');
      expect(slugify('x' * 100).length, 63);
    });

    test('a token is active until it is revoked or expires', () {
      final now = DateTime(2026, 1, 10);
      GatewayToken token({DateTime? revoked, DateTime? expires}) =>
          GatewayToken(
            id: 't',
            name: 'n',
            prefix: 'mcp_abcd',
            createdAt: now,
            revokedAt: revoked,
            expiresAt: expires,
          );
      expect(token().active(now), isTrue);
      expect(token(revoked: now).active(now), isFalse);
      expect(
        token(expires: now.add(const Duration(days: 1))).active(now),
        isTrue,
      );
      expect(
        token(expires: now.subtract(const Duration(seconds: 1))).active(now),
        isFalse,
      );
    });
  });
}
