import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/app_info.dart';

import '../support/app_harness.dart';
import '../support/fakes.dart';

/// The pages are lazy lists: scroll until the widget is built, then tap it.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  final list = find.byType(Scrollable).first;
  for (var i = 0; i < 40 && f.evaluate().isEmpty; i++) {
    await tester.drag(list, const Offset(0, -300));
    await tester.pump();
  }
  expect(f, findsWidgets, reason: 'never scrolled into view');
  await tester.ensureVisible(f.first);
  await tester.pump();
}

Future<void> _tapVisible(WidgetTester tester, Finder f) async {
  await _reveal(tester, f);
  await tester.tap(f.first);
  await tester.pumpAndSettle();
}

void main() {
  group('Contributor', () {
    test('profile and avatar URLs come from the GitHub login', () {
      const c = Contributor(login: 'AjaxR0', name: 'Ajax', role: 'x');
      expect(c.profileUrl, 'https://github.com/AjaxR0');
      expect(c.avatarUrl, 'https://github.com/AjaxR0.png?size=160');
    });

    test('initials for the avatar fallback', () {
      String i(String name, [String login = 'x']) =>
          Contributor(login: login, name: name, role: '').initials;
      expect(i('Ajax'), 'A');
      expect(i('tr_18'), 'T', reason: 'digits are not initials');
      expect(i('Ana Maria Silva'), 'AM');
      expect(i('1234', 'zed'), 'Z', reason: 'falls back to the login');
    });

    test('the people the user named are all listed', () {
      expect(contributors.map((c) => c.login), [
        'GuikiPT',
        'AjaxR0',
        'TeeAr18',
      ]);
      expect(contributors.map((c) => c.login).toSet(), hasLength(3));
    });
  });

  group('about', () {
    testWidgets('introduces the app, its version and how the pieces fit', (
      tester,
    ) async {
      await pumpApp(tester);
      await goTo(tester, '/info');
      expect(find.text('MCP Manager'), findsWidgets);
      expect(find.text('v$appVersion'), findsOneWidget);
      expect(
        find.text('debug build'),
        findsOneWidget,
        reason: 'tests run in debug mode',
      );
      expect(find.textContaining('Hacktober Portimão'), findsOneWidget);
      for (final box in ['You', 'Operator', 'MCP servers']) {
        expect(find.text(box), findsWidgets);
      }
      expect(find.text('Approvals · rules · audit'), findsOneWidget);
    });

    testWidgets('each feature explains itself and opens its page', (
      tester,
    ) async {
      await pumpApp(tester);
      await goTo(tester, '/info');
      for (final feature in [
        'MCP Servers',
        'MCP Tools & rules',
        'Chat',
        'Audit',
        'Settings',
        'Overview',
      ]) {
        await _reveal(tester, find.text(feature));
        expect(find.text(feature), findsWidgets, reason: feature);
      }
      expect(
        find.textContaining('Streamable HTTP or the older HTTP+SSE'),
        findsOneWidget,
      );
      expect(
        find.textContaining('"reason" or "expected result"'),
        findsOneWidget,
      );

      await _tapVisible(tester, find.widgetWithText(TextButton, 'Open'));
      expect(find.text('Connect and manage your MCP servers'), findsOneWidget);
    });

    testWidgets(
      'the safety section is open by default; the others expand on tap',
      (tester) async {
        await pumpApp(tester);
        await goTo(tester, '/info');
        await _reveal(tester, find.text('Safety, in detail'));
        expect(
          find.textContaining('Only tools a server marks readOnly'),
          findsOneWidget,
        );
        expect(
          find.textContaining('can never be "always allowed"'),
          findsOneWidget,
        );

        expect(
          find.textContaining('stdio servers cannot be reached'),
          findsNothing,
        );
        await _tapVisible(tester, find.text('Connecting servers'));
        expect(
          find.textContaining('stdio servers cannot be reached'),
          findsOneWidget,
        );
        expect(
          find.textContaining('https://chatgpt.com/connector/oauth/*'),
          findsOneWidget,
        );

        await _tapVisible(tester, find.text('Where your data lives'));
        expect(find.textContaining('local storage'), findsWidgets);
        await _tapVisible(tester, find.text('Tips'));
        expect(find.textContaining('Shift+Enter'), findsOneWidget);
      },
    );

    testWidgets('"This copy" shows the origin and the OAuth redirect URI', (
      tester,
    ) async {
      await pumpApp(tester);
      await goTo(tester, '/info');
      await _tapVisible(tester, find.text('This copy'));
      expect(find.text('https://app.test'), findsOneWidget);
      expect(find.text(oauthRedirect), findsOneWidget);
    });

    testWidgets('links open through the launcher', (tester) async {
      final opened = <Uri>[];
      await pumpApp(
        tester,
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      await goTo(tester, '/info');
      await _tapVisible(tester, find.text('Source on GitHub'));
      await _tapVisible(tester, find.text('About MCP'));
      await _tapVisible(tester, find.text('Ollama'));
      expect(opened.map((u) => u.toString()), [
        appRepoUrl,
        mcpSpecUrl,
        ollamaUrl,
      ]);
    });

    testWidgets('a blocked link is copied instead of lost', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpApp(tester, openUrl: (_) async => false);
      await goTo(tester, '/info');
      await _tapVisible(tester, find.text('Source on GitHub'));
      expect(copied, appRepoUrl);
      expect(find.textContaining('Could not open the link'), findsOneWidget);
    });

    testWidgets('fits a phone with everything expanded', (tester) async {
      await pumpApp(tester, size: const Size(400, 800));
      await goTo(tester, '/info');
      for (final t in [
        'Connecting servers',
        'Where your data lives',
        'Tips',
        'This copy',
      ]) {
        await _tapVisible(tester, find.text(t));
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('contributors page', () {
    testWidgets('lists the three people with handle, role and profile link', (
      tester,
    ) async {
      final opened = <Uri>[];
      await pumpApp(
        tester,
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      await goTo(tester, '/contributors');

      for (final c in contributors) {
        expect(find.text(c.name), findsOneWidget);
        expect(find.text('@${c.login}'), findsOneWidget);
      }
      expect(find.text('Co-author'), findsNWidgets(2));
      expect(find.text('Flutter rewrite · project owner'), findsOneWidget);

      await tester.tap(find.text('@AjaxR0'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), 'https://github.com/AjaxR0');

      await tester.tap(find.widgetWithText(TextButton, 'GitHub profile').last);
      await tester.pumpAndSettle();
      expect(opened.last.toString(), 'https://github.com/TeeAr18');
    });

    testWidgets('avatars fall back to initials when the image cannot load', (
      tester,
    ) async {
      await pumpApp(tester);
      await goTo(tester, '/contributors');
      await tester.pump(const Duration(milliseconds: 100));
      // No network in tests: the fallbacks are shown.
      expect(find.text('G'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('T'), findsOneWidget);
    });

    testWidgets('reaches the contributors graph and fits a phone', (
      tester,
    ) async {
      final opened = <Uri>[];
      await pumpApp(
        tester,
        size: const Size(400, 800),
        openUrl: (u) async {
          opened.add(u);
          return true;
        },
      );
      await goTo(tester, '/contributors');
      expect(tester.takeException(), isNull);
      await _tapVisible(tester, find.text('All contributors on GitHub'));
      expect(opened.single.toString(), '$appRepoUrl/graphs/contributors');
    });
  });
}
