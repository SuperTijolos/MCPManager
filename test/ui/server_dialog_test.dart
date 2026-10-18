import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/mcp_models.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

final _tools = [
  {
    'name': 'lookup',
    'description': 'Read something',
    'inputSchema': {'type': 'object'},
    'annotations': {'readOnlyHint': true},
  },
  {
    'name': 'wipe',
    'description': 'Destroys',
    'inputSchema': {'type': 'object'},
  },
];

Finder field(String label) => find.widgetWithText(TextFormField, label);

Future<ProviderContainer> _open(
  WidgetTester tester, {
  FakeMcpServer? server,
  FakeOAuthWorld? oauth,
  Size size = const Size(1280, 900),
  dynamic httpClient,
}) async {
  final c = await pumpApp(
    tester,
    server:
        server ??
        (oauth == null && httpClient == null
            ? FakeMcpServer(tools: _tools)
            : null),
    oauth: oauth,
    httpClient: httpClient,
    size: size,
  );
  await goTo(tester, '/mcp-servers');
  return c;
}

Future<void> _openAdd(WidgetTester tester) async {
  await tester.tap(find.text('Add your first server'));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String name = 'Demo',
  String url = 'mcp.test/mcp',
}) async {
  await tester.enterText(field('Name'), name);
  await tester.enterText(field('Endpoint URL'), url);
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  group('adding', () {
    testWidgets('sections, validation, and the URL that will really be used', (
      tester,
    ) async {
      await _open(tester);
      await _openAdd(tester);
      for (final section in [
        'Connection',
        'Authentication',
        'Extra headers',
        'Try it',
      ]) {
        expect(find.text(section), findsOneWidget);
      }
      expect(
        find.text('Danger zone'),
        findsNothing,
        reason: 'nothing to remove yet',
      );

      await tester.tap(find.text('Add & connect'));
      await tester.pumpAndSettle();
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Enter a valid http(s) URL'), findsOneWidget);

      await tester.enterText(field('Endpoint URL'), 'localhost:3333');
      await tester.pumpAndSettle();
      expect(
        find.text('Will connect to http://localhost:3333'),
        findsOneWidget,
      );
      await tester.enterText(field('Endpoint URL'), 'http://localhost:3333');
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Will connect to'),
        findsNothing,
        reason: 'nothing to explain when it is already complete',
      );
    });

    testWidgets('adds the server with the chosen transport', (tester) async {
      final c = await _open(tester);
      await _openAdd(tester);
      await _fill(tester);
      await tester.tap(find.text('Auto-detect'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Streamable HTTP').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add & connect'));
      await tester.pumpAndSettle();

      final runtime = c.read(mcpHubProvider).servers.single;
      expect(runtime.config.name, 'Demo');
      expect(runtime.config.url, 'http://mcp.test/mcp');
      expect(runtime.config.transport, McpTransport.streamableHttp);
      expect(runtime.status, ServerStatus.connected);
    });
  });

  group('headers editor', () {
    testWidgets('rows are added, validated and saved; empty rows are ignored', (
      tester,
    ) async {
      final c = await _open(tester);
      await _openAdd(tester);
      await _fill(tester);

      await _tapVisible(tester, find.text('Add header'));
      await _tapVisible(tester, find.text('Add header'));
      await _tapVisible(tester, find.text('Add header'));
      expect(find.byTooltip('Remove header'), findsNWidgets(3));

      final names = find.widgetWithText(TextFormField, 'Header name');
      final values = find.widgetWithText(TextFormField, 'Value');
      await tester.enterText(names.at(0), 'X-Api-Key');
      await tester.enterText(values.at(0), 'abc');
      await tester.enterText(names.at(1), 'bad name!');
      await tester.enterText(values.at(1), 'x');
      await _tapVisible(tester, find.text('Add & connect'));
      expect(find.text('Invalid name'), findsOneWidget);

      await tester.enterText(names.at(1), 'x-api-key');
      await _tapVisible(tester, find.text('Add & connect'));
      expect(
        find.text('Duplicate'),
        findsWidgets,
        reason: 'names compare case-insensitively',
      );

      await tester.tap(find.byTooltip('Remove header').at(1));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Add & connect'));

      expect(c.read(mcpHubProvider).servers.single.config.headers, {
        'X-Api-Key': 'abc',
      });
    });

    testWidgets(
      'existing headers load as rows; the bearer token is not shown as a header',
      (tester) async {
        final c = await _open(tester);
        await c
            .read(mcpHubProvider.notifier)
            .addServer(
              name: 'Demo',
              url: 'https://mcp.test/mcp',
              headers: {'Authorization': 'Bearer tok-123', 'X-Team': 'blue'},
            );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Edit'));
        await tester.pumpAndSettle();

        expect(find.widgetWithText(TextFormField, 'X-Team'), findsOneWidget);
        expect(
          find.widgetWithText(TextFormField, 'Authorization'),
          findsNothing,
        );
      },
    );
  });

  group('bearer token', () {
    testWidgets(
      'is hidden until you reveal it, required, and saved as an Authorization header',
      (tester) async {
        final c = await _open(tester);
        await _openAdd(tester);
        await _fill(tester);
        await tester.tap(find.text('Bearer token').first);
        await tester.pumpAndSettle();

        await tester.tap(find.text('Add & connect'));
        await tester.pumpAndSettle();
        expect(find.text('Enter a token, or choose None'), findsOneWidget);

        await tester.enterText(field('Bearer token'), 'secret-token-123');
        await tester.pumpAndSettle();
        EditableText editable() => tester.widget<EditableText>(
          find.descendant(
            of: field('Bearer token'),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable().obscureText, isTrue);
        await tester.tap(find.byTooltip('Show token'));
        await tester.pumpAndSettle();
        expect(editable().obscureText, isFalse);
        await tester.tap(find.byTooltip('Hide token'));
        await tester.pumpAndSettle();
        expect(editable().obscureText, isTrue);

        await tester.tap(find.text('Add & connect'));
        await tester.pumpAndSettle();
        expect(
          c.read(mcpHubProvider).servers.single.config.headers['Authorization'],
          'Bearer secret-token-123',
        );
      },
    );

    testWidgets('editing a server with a token pre-fills it (hidden)', (
      tester,
    ) async {
      final c = await _open(tester);
      await c
          .read(mcpHubProvider.notifier)
          .addServer(
            name: 'Demo',
            url: 'https://mcp.test/mcp',
            headers: {'Authorization': 'Bearer tok-123'},
          );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: field('Bearer token'),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.controller.text, 'tok-123');
      expect(editable.obscureText, isTrue);
    });
  });

  group('test connection', () {
    testWidgets(
      'reports what it found without saving anything or touching the audit log',
      (tester) async {
        final c = await _open(tester);
        await _openAdd(tester);
        await _fill(tester, url: 'https://mcp.test/mcp');
        await tester.tap(find.text('Test connection'));
        await tester.pumpAndSettle();

        expect(find.text('Connected'), findsOneWidget);
        expect(find.textContaining('2 tools'), findsOneWidget);
        expect(find.textContaining('Streamable HTTP'), findsWidgets);
        expect(find.textContaining('fake 1.2.3'), findsOneWidget);
        expect(
          c.read(mcpHubProvider).servers,
          isEmpty,
          reason: 'testing must not add the server',
        );
        expect(
          c.read(auditLogProvider),
          isEmpty,
          reason: 'nor write to the audit log',
        );
      },
    );

    testWidgets('shows the endpoint it discovered for a bare host:port', (
      tester,
    ) async {
      final bridge = FakeSseServer(tools: _tools, requireToken: 'tok');
      await _open(tester, httpClient: bridge.client);
      await _openAdd(tester);
      await _fill(tester, url: 'localhost:3333');
      await tester.tap(find.text('Bearer token').first);
      await tester.pumpAndSettle();
      await tester.enterText(field('Bearer token'), 'tok');
      await _tapVisible(tester, find.text('Test connection'));

      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('Legacy SSE'), findsWidgets);
      expect(
        find.textContaining('Found at http://localhost:3333/sse'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a missing token is explained as "reachable, sign-in required"',
      (tester) async {
        final bridge = FakeSseServer(tools: _tools, requireToken: 'tok');
        await _open(tester, httpClient: bridge.client);
        await _openAdd(tester);
        await _fill(tester, url: 'localhost:3333');
        await _tapVisible(tester, find.text('Test connection'));
        expect(find.textContaining('Reachable'), findsOneWidget);
        expect(
          find.textContaining('Choose Bearer token or OAuth'),
          findsOneWidget,
        );
      },
    );

    testWidgets('failures show the reason and a details trace', (tester) async {
      final server = SessionTroubleServer(hideSessionHeader: true);
      await _open(tester, httpClient: server.client);
      await _openAdd(tester);
      await _fill(tester, url: 'https://cf.test/mcp');
      await _tapVisible(tester, find.text('Test connection'));
      expect(find.text('Could not connect'), findsOneWidget);
      expect(find.textContaining('No MCP transport worked'), findsOneWidget);
      await _tapVisible(tester, find.text('Details'));
      expect(find.textContaining('POST initialize → 200'), findsOneWidget);
    });

    testWidgets('an invalid URL is caught before trying', (tester) async {
      await _open(tester);
      await _openAdd(tester);
      await _tapVisible(tester, find.text('Test connection'));
      expect(find.text('Enter a valid http(s) URL first.'), findsOneWidget);
    });

    testWidgets('changing the URL clears a stale result', (tester) async {
      await _open(tester);
      await _openAdd(tester);
      await _fill(tester, url: 'https://mcp.test/mcp');
      await _tapVisible(tester, find.text('Test connection'));
      expect(find.text('Connected'), findsOneWidget);
      await tester.enterText(field('Endpoint URL'), 'https://other.test/mcp');
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsNothing);
    });
  });

  group('editing', () {
    testWidgets('shows status, saves changes, and removes after confirmation', (
      tester,
    ) async {
      final c = await _open(tester);
      final runtime = await c
          .read(mcpHubProvider.notifier)
          .addServer(name: 'Demo', url: 'https://mcp.test/mcp');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Edit server'), findsOneWidget);
      expect(find.text('Connected'), findsWidgets);
      expect(find.textContaining('2 tools'), findsWidgets);

      await tester.enterText(field('Name'), 'Renamed');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        c.read(mcpHubProvider).byId(runtime.config.id)!.config.name,
        'Renamed',
      );

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      await _tapVisible(tester, find.text('Remove this server'));
      expect(find.textContaining('Past audit events are kept'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();
      expect(c.read(mcpHubProvider).servers, isEmpty);
    });
  });

  testWidgets('desktop dialog shows two side-by-side settings panels', (
    tester,
  ) async {
    await _open(tester, size: const Size(1280, 900));
    await _openAdd(tester);
    final panels = find.byKey(const ValueKey('server-editor-columns'));
    expect(panels, findsOneWidget);
    expect(find.text('Connection'), findsOneWidget);
    expect(find.text('Authentication'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('phone width', () {
    testWidgets(
      'the dialog is full screen and everything fits, including results',
      (tester) async {
        await _open(tester, size: const Size(400, 800));
        await _openAdd(tester);
        expect(
          find.byKey(const ValueKey('server-editor-columns')),
          findsNothing,
        );
        await _fill(tester, url: 'https://mcp.test/mcp');
        await _tapVisible(tester, find.text('Add header'));
        await tester.tap(find.text('Bearer token').first);
        await tester.pumpAndSettle();
        await _tapVisible(tester, find.text('Test connection'));
        expect(tester.takeException(), isNull);
        expect(find.text('Connected'), findsOneWidget);
      },
    );
  });
}
