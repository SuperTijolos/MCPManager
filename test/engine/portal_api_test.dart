import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/mcp/mcp_auto_connection.dart';
import 'package:mcp_manager/engine/portal/portal_api.dart';
import 'package:mcp_manager/engine/portal/portal_models.dart';
import 'package:mcp_manager/engine/server/server_client.dart';

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
  late ServerClient client;
  late PortalApi api;

  /// Servers are the hub's business; the portals here just need some.
  Future<void> saveServer(String id, String name, String url) =>
      client.putMap('/api/servers/$id', {'name': name, 'url': url});

  setUp(() async {
    upstream = FakeMcpServer(
      tools: _tools,
      handlers: {'read_file': (a) => textResult('contents of ${a['path']}')},
    );
    gw = await TestGateway.start(upstream: upstream);
    client = ServerClient(
      baseUrl: gatewayUrl,
      token: gatewayAdminToken,
      httpClient: gw.client,
    );
    api = PortalApi(client);
  });

  tearDown(() => gw.close());

  group('PortalApi against the real gateway', () {
    test('reads its status', () async {
      final status = await api.status();
      expect(status.version, '1.0.0');
      expect(status.baseUrl, gatewayUrl);
      expect(status.servers, 0);
    });

    test('lists the servers it can put in a portal', () async {
      await client.putMap('/api/servers/srv_app', {
        'name': 'Files',
        'url': 'https://files.test/mcp',
        'headers': {'Authorization': 'Bearer s3cret'},
        'transport': 'streamable-http',
      });
      final server = (await api.servers()).single;
      expect(server.id, 'srv_app');
      expect(server.slug, 'files');
      expect(server.headerNames, ['Authorization']);
      expect(server.transport, 'streamable-http');
    });

    test('creates, updates, previews and deletes a portal', () async {
      await saveServer('s', 'Files', 'https://files.test/mcp');
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

    test('says what went wrong', () async {
      final wrong = PortalApi(
        ServerClient(
          baseUrl: gatewayUrl,
          token: 'wrong-wrong-wrong-wrong',
          httpClient: gw.client,
        ),
      );
      await expectLater(
        wrong.status(),
        throwsA(
          isA<PortalApiException>()
              .having((e) => e.unauthorized, 'unauthorized', isTrue)
              .having((e) => e.message, 'message', contains('Sign in again')),
        ),
      );

      await api.savePortal(name: 'one', slug: 'same');
      await expectLater(
        api.savePortal(name: 'two', slug: 'same'),
        throwsA(
          isA<PortalApiException>()
              .having((e) => e.code, 'code', 'portal_slug_in_use')
              .having((e) => e.message, 'message', contains('address')),
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
        ServerClient(
          baseUrl: 'http://nowhere.test',
          token: 'x',
          httpClient: MockClient(
            (_) async => throw http.ClientException('connection refused'),
          ),
        ),
      );
      await expectLater(
        down.status(),
        throwsA(
          isA<PortalApiException>()
              .having((e) => e.message, 'message', contains('Could not reach'))
              .having((e) => e.status, 'status', isNull),
        ),
      );

      final foreign = PortalApi(
        ServerClient(
          baseUrl: 'http://web.test',
          token: 'x',
          httpClient: MockClient(
            (_) async => http.Response('<html>hi</html>', 200),
          ),
        ),
      );
      await expectLater(
        foreign.status(),
        throwsA(
          isA<PortalApiException>().having(
            (e) => e.message,
            'message',
            contains('not JSON'),
          ),
        ),
      );
    });
  });

  group('the app\'s own MCP client against a portal', () {
    Future<String> openPortal() async {
      await saveServer('s', 'Files', 'https://files.test/mcp');
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

    test('what the client did shows up in the server\'s audit log', () async {
      final secret = await openPortal();
      final connection = createMcpConnection(
        config(secret),
        httpClient: gw.client,
      );
      await connection.connect();
      await connection.callTool('files__read_file', {'path': '/x'});

      final events = (await client.getMap('/api/audit'))['events'] as List;
      final event = AuditEvent.fromServer(
        (events.single as Map).cast<String, dynamic>(),
      );
      expect(event.title, 'Files · read_file');
      expect(event.status, AuditStatus.success);
      expect(event.source, AuditSource.portal);
      expect(event.actor, 'client');
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
