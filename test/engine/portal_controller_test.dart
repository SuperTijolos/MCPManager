import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/portal/portal_controller.dart';
import 'package:mcp_manager/engine/portal/portal_models.dart';
import 'package:mcp_manager/engine/server/session.dart';

import '../support/fakes.dart';
import '../support/gateway_harness.dart';

void main() {
  late TestGateway gw;

  setUp(() async {
    gw = await TestGateway.start(
      upstream: FakeMcpServer(
        tools: [
          {
            'name': 'lookup',
            'description': 'Look',
            'inputSchema': {'type': 'object'},
          },
        ],
      ),
    );
  });

  Future<ProviderContainer> container({
    bool liveEvents = false,
    http.Client? reach,
  }) async {
    final c = await makeContainer(
      gateway: gw,
      defaultProvider: false,
      liveEvents: liveEvents,
      reach: reach,
    );
    addTearDown(c.dispose);
    await c.read(portalControllerProvider.notifier).loaded;
    return c;
  }

  PortalController controller(ProviderContainer c) =>
      c.read(portalControllerProvider.notifier);
  PortalData data(ProviderContainer c) => c.read(portalControllerProvider);

  Future<String> addServer(ProviderContainer c, String name) async {
    final runtime = await c
        .read(mcpHubProvider.notifier)
        .addServer(name: name, url: 'https://docs.test/mcp');
    await controller(c).refresh();
    return runtime.config.id;
  }

  group('loading', () {
    test('reads the server when it starts', () async {
      final c = await container();
      expect(data(c).connected, isTrue);
      expect(data(c).serverUrl, gatewayUrl);
      expect(data(c).status!.version, '1.0.0');
      expect(data(c).portals, isEmpty);
      expect(data(c).tokens, isEmpty);
    });

    test('is not configured when nobody is signed in', () async {
      final c = ProviderContainer(
        overrides: [sessionProvider.overrideWith(SessionNotifierSignedOut.new)],
      );
      addTearDown(c.dispose);
      expect(data(c).connection, PortalConnection.notConfigured);
    });

    test('a server that does not answer is "failed", with an error', () async {
      final c = await container(
        reach: MockClient(
          (_) async => throw http.ClientException('connection refused'),
        ),
      );
      expect(data(c).connection, PortalConnection.failed);
      expect(data(c).error, contains('Could not reach'));
    });
  });

  group('working with portals and tokens', () {
    test('creates portals and tokens and refreshes the lists', () async {
      final c = await container();
      final id = await addServer(c, 'Docs');
      final portal = await controller(c)
          .savePortal(name: 'Docs', servers: [GatewayPortalServer(id)]);
      expect(data(c).portals.single.id, portal.id);

      final created = await controller(c)
          .createToken(name: 'client', portalIds: [portal.id]);
      expect(created.secret, startsWith('mcp_'));
      expect(data(c).tokens.single.portalIds, [portal.id]);

      await controller(c).revokeToken(created.token.id);
      expect(data(c).tokens.single.revokedAt, isNotNull);
      await controller(c).deletePortal(portal.id);
      expect(data(c).portals, isEmpty);
    });

    test('lists the servers it can offer a portal', () async {
      final c = await container();
      await addServer(c, 'Docs');
      expect(data(c).servers.single.name, 'Docs');
    });

    test('previews the tools a portal exposes', () async {
      final c = await container();
      final id = await addServer(c, 'Docs');
      final portal = await controller(c)
          .savePortal(name: 'Docs', servers: [GatewayPortalServer(id)]);
      final tools = await controller(c).portalTools(portal.id);
      expect(tools.tools.map((t) => t.name), ['docs__lookup']);
    });

    test('removing a server takes it out of its portals', () async {
      final c = await container();
      final id = await addServer(c, 'Docs');
      await controller(c)
          .savePortal(name: 'Docs', servers: [GatewayPortalServer(id)]);

      await c.read(mcpHubProvider.notifier).removeServer(id);
      await controller(c).refresh();

      expect(data(c).servers, isEmpty);
      expect(data(c).portals.single.servers, isEmpty);
    });
  });

  group('live updates', () {
    test('a portal made elsewhere appears without a refresh', () async {
      final c = await container(liveEvents: true);
      // Someone else (another browser) creates a portal on the server.
      await gw.client.post(
        Uri.parse('$gatewayUrl/api/portals'),
        headers: {
          'authorization': 'Bearer $gatewayAdminToken',
          'content-type': 'application/json',
        },
        body: '{"name":"Elsewhere"}',
      );
      for (var i = 0; i < 40 && data(c).portals.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(data(c).portals.single.name, 'Elsewhere');
    });
  });
}
