import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mcp_manager/engine/app_info.dart';
import 'package:mcp_manager/engine/core/prefs.dart';
import 'package:mcp_manager/engine/llm/llm_settings.dart';
import 'package:mcp_manager/engine/llm/llm_types.dart';
import 'package:mcp_manager/engine/mcp/mcp_hub.dart';
import 'package:mcp_manager/engine/mcp/oauth/oauth_service.dart';
import 'package:mcp_manager/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';

/// Boots the whole app on a fake browser profile. Returns the container so a
/// test can seed or inspect state alongside the UI.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  FakeMcpServer? server,
  http.Client? httpClient,
  LlmProvider? llm,
  FakeOAuthWorld? oauth,
  Map<String, Object> prefs = const {},
  Future<bool> Function(Uri)? openUrl,
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        oauthRedirectUriProvider.overrideWithValue(Uri.parse(oauthRedirect)),
        if (oauth != null) ...[
          mcpHttpClientFactoryProvider.overrideWithValue(() => oauth.client),
          oauthPopupOpenerProvider.overrideWithValue(
            () => FakePopup.approving(oauth),
          ),
        ],
        if (server != null)
          mcpHttpClientFactoryProvider.overrideWithValue(() => server.client),
        if (httpClient != null)
          mcpHttpClientFactoryProvider.overrideWithValue(() => httpClient),
        if (llm != null)
          llmProviderFactoryProvider.overrideWithValue((_) => llm),
        if (openUrl != null) openUrlProvider.overrideWithValue(openUrl),
      ],
      child: const MCPManagerApp(),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(MCPManagerApp)));
}

/// Jumps straight to a page by path (the sidebar is not what is under test).
Future<void> goTo(WidgetTester tester, String path) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
  await tester.pumpAndSettle();
}
