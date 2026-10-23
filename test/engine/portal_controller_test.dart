import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';
import 'package:mcp_manager/engine/portal/portal_controller.dart';
import 'package:mcp_manager/engine/portal/portal_models.dart';
import 'package:mcp_manager/engine/rules/tool_rules_store.dart';
import 'package:mcp_manager/engine/rules/tool_rules.dart';

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

  tearDown(() => gw.close());

  Future<ProviderContainer> container({
    Map<String, Object> prefs = const {},
  }) async {
    final c = await makeContainer(
      server: FakeMcpServer(),
      prefs: prefs,
      overrides: [portalHttpClientProvider.overrideWithValue(gw.client)],
    );
    addTearDown(c.dispose);
    return c;
  }

  PortalController controller(ProviderContainer c) =>
      c.read(portalControllerProvider.notifier);
  PortalData data(ProviderContainer c) => c.read(portalControllerProvider);

  group('connecting', () {
    test('starts unconfigured', () async {
      final c = await container();
      expect(data(c).connection, PortalConnection.notConfigured);
      expect(data(c).settings.configured, isFalse);
    });

    test('saves a working address and token and loads the gateway', () async {
      final c = await container();
      final problem = await controller(c)
          .connect('gateway.test', gatewayAdminToken);
      // "gateway.test" has no scheme: it is read as http://gateway.test.
      expect(problem, isNull);
      expect(data(c).connected, isTrue);
      expect(data(c).settings.url, 'http://gateway.test');
      expect(data(c).status!.version, '1.0.0');

      final saved =
          readJson(c.read(sharedPreferencesProvider), 'mcpm.portal.v1') as Map;
      expect(saved['url'], 'http://gateway.test');
      expect(saved['token'], gatewayAdminToken);
    });

    test('does not save a wrong token', () async {
      final c = await container();
      final problem = await controller(c)
          .connect(gatewayUrl, 'wrong-wrong-wrong-wrong');
      expect(problem, contains('admin token'));
      expect(data(c).connection, PortalConnection.notConfigured);
      expect(
        readJson(c.read(sharedPreferencesProvider), 'mcpm.portal.v1'),
        isNull,
      );
    });

    test('refuses an address or token that is obviously wrong', () async {
      final c = await container();
      expect(
        await controller(c).connect('not a url', 'x'),
        contains('gateway address'),
      );
      expect(
        await controller(c).connect(gatewayUrl, '  '),
        contains('admin token'),
      );
    });

    test('remembers the settings across restarts', () async {
      final first = await container();
      await controller(first).connect(gatewayUrl, gatewayAdminToken);
      final saved = readJson(
        first.read(sharedPreferencesProvider),
        'mcpm.portal.v1',
      );

      final second = await container(
        prefs: {
          'mcpm.portal.v1':
              '{"url":"$gatewayUrl","token":"$gatewayAdminToken"}',
        },
      );
      expect(saved, isNotNull);
      expect(data(second).settings.configured, isTrue);
      expect(data(second).connection, PortalConnection.connecting);
      await controller(second).refresh();
      expect(data(second).connected, isTrue);
    });

    test(
      'a saved gateway that rejects the saved token is "failed", with an error',
      () async {
        final c = await container(
          prefs: {
            'mcpm.portal.v1': '{"url":"http://gone.test","token":"abcdefgh"}',
          },
        );
        await controller(c).refresh();
        expect(data(c).connection, PortalConnection.failed);
        expect(data(c).error, isNotNull);
      },
    );

    test('disconnecting forgets everything', () async {
      final c = await container();
      await controller(c).connect(gatewayUrl, gatewayAdminToken);
      await controller(c).disconnect();
      expect(data(c).settings.configured, isFalse);
      expect(data(c).connection, PortalConnection.notConfigured);
      expect(
        readJson(c.read(sharedPreferencesProvider), 'mcpm.portal.v1'),
        isNull,
      );
    });
  });

  group('working with the gateway', () {
    Future<ProviderContainer> connected() async {
      final c = await container();
      await controller(c).connect(gatewayUrl, gatewayAdminToken);
      return c;
    }

    test(
      'puts an app server on the gateway under its own id, headers included',
      () async {
        final c = await connected();
        const config = McpServerConfig(
          id: 'srv_app',
          name: 'Docs',
          url: 'https://docs.test/mcp',
          headers: {'Authorization': 'Bearer abc'},
          transport: McpTransport.streamableHttp,
        );

        await controller(c).publishServer(config);

        expect(data(c).server('srv_app')!.name, 'Docs');
        expect(gw.state.servers.single.headers, {
          'Authorization': 'Bearer abc',
        });
        expect(gw.state.servers.single.transport.wire, 'streamable-http');
      },
    );

    test('only servers without OAuth can be put on a gateway', () {
      expect(
        PortalController.publishable(
          const McpServerConfig(id: 'a', name: 'a', url: 'https://a.test'),
        ),
        isTrue,
      );
      expect(
        PortalController.publishable(
          const McpServerConfig(
            id: 'a',
            name: 'a',
            url: 'https://a.test',
            oauth: true,
          ),
        ),
        isFalse,
      );
    });

    test('lists the app servers the gateway does not have yet', () async {
      final c = await connected();
      final hub = c.read(mcpHubProvider.notifier);
      await hub.addServer(name: 'One', url: 'https://one.test/mcp');
      await hub.addServer(name: 'Two', url: 'https://two.test/mcp');
      final first = c.read(mcpHubProvider).servers.first.config;
      await controller(c).publishServer(first);

      final missing = unpublishedServers(c.read(mcpHubProvider), data(c));
      expect(missing.map((s) => s.name), ['Two']);
    });

    test('sends the app\'s tool rules and overrides', () async {
      final c = await connected();
      final rules = c.read(toolRulesProvider.notifier);
      rules.upsert(
        const ToolRule(
          id: 'why',
          name: 'Why',
          args: [RuleArg(name: 'reason', required: true)],
        ),
      );
      rules.setHidden(['srv/secret_tool'], true);

      final sent = await controller(c).pushRules();

      expect(sent, (rules: 1, overrides: 1));
      expect(gw.state.rules.single.name, 'Why');
      expect(gw.state.overrides['srv/secret_tool']!.hidden, isTrue);
      expect(data(c).status!.rules, 1);
    });

    test('creates portals and tokens and refreshes the lists', () async {
      final c = await connected();
      await controller(c).publishServer(
        const McpServerConfig(
          id: 's',
          name: 'Docs',
          url: 'https://docs.test/mcp',
        ),
      );
      final portal = await controller(c)
          .savePortal(name: 'Docs', servers: [const GatewayPortalServer('s')]);
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

    test(
      'removing a server takes it out of the gateway and its portals',
      () async {
        final c = await connected();
        await controller(c).publishServer(
          const McpServerConfig(
            id: 's',
            name: 'Docs',
            url: 'https://docs.test/mcp',
          ),
        );
        await controller(
          c,
        ).savePortal(name: 'Docs', servers: [const GatewayPortalServer('s')]);

        await controller(c).removeServer('s');

        expect(data(c).servers, isEmpty);
        expect(data(c).portals.single.servers, isEmpty);
      },
    );
  });
}
