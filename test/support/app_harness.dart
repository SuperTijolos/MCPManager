import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_manager/engine/app_info.dart';
import 'package:mcp_manager/engine/audit/audit_log.dart';
import 'package:mcp_manager/engine/audit/audit_models.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/server/server_events.dart';
import 'package:mcp_manager/engine/server/session.dart';
import 'package:mcp_manager/ui/sign_in.dart';
import 'package:mcp_manager/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'gateway_harness.dart';

/// The in-process server the app from [pumpApp] is signed in to.
TestGateway appGatewayOf(ProviderContainer container) => gatewayOf(container);

/// Boots the whole app on a fake browser profile and a fresh in-process
/// server, signed in unless [signedIn] is false. Returns the container so a
/// test can seed or inspect state alongside the UI.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  FakeMcpServer? server,
  http.Client? httpClient,
  LlmProvider? llm,
  FakeOAuthWorld? oauth,
  TestGateway? gateway,
  bool signedIn = true,
  http.Client? reach,
  bool defaultProvider = true,
  List<AuditEvent> audit = const [],
  Future<void> Function(TestGateway gateway)? setup,
  Map<String, Object> prefs = const {},
  Future<bool> Function(Uri)? openUrl,
  Size size = const Size(1280, 900),
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  final gw =
      gateway ??
      await TestGateway.start(
        upstream: server,
        upstreamClient: oauth != null
            ? () => oauth.client
            : httpClient == null
            ? null
            : () => httpClient,
      );
  addTearDown(gw.client.close);
  await seedAudit(gw, audit);
  await setup?.call(gw);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        if (signedIn)
          ...signedInOverrides(gw, reach: reach)
        else ...[
          serverHttpClientProvider.overrideWithValue(() => gw.client),
          serverEventsEnabledProvider.overrideWithValue(false),
        ],
        if (oauth != null)
          authPopupOpenerProvider.overrideWithValue(
            () => FakePopup.approving(oauth, gw),
          ),
        auditLogProvider.overrideWith(() => TestAuditLog(gw)),
        if (llm != null)
          llmProviderFactoryProvider.overrideWithValue((_) => llm),
        if (openUrl != null) openUrlProvider.overrideWithValue(openUrl),
        ...overrides,
      ],
      child: const MCPManagerApp(),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(MCPManagerApp)),
  );
  registerGateway(container, gw);
  if (signedIn && defaultProvider) {
    await seedDefaultProvider(container);
    await tester.pumpAndSettle();
  }
  return container;
}

/// Jumps straight to a page by path (the sidebar is not what is under test).
Future<void> goTo(WidgetTester tester, String path) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
  await tester.pumpAndSettle();
}
