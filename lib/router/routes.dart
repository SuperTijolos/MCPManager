import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/audit/audit_page.dart';
import 'pages/chat/chat_page.dart';
import 'pages/contributors/contributors_page.dart';
import 'pages/info/info_page.dart';
import 'pages/overview/overview_page.dart';
import 'pages/portals/portals_page.dart';
import 'pages/servers/servers_page.dart';
import 'pages/settings/settings_page.dart';
import 'pages/sign_in/sign_in_page.dart';
import 'pages/tools/tool_focus.dart';
import 'pages/tools/tools_page.dart';
import 'shell.dart';

class AppDestination {
  const AppDestination(this.path, this.label, this.icon, this.selectedIcon);

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

const mainDestinations = [
  AppDestination('/', 'Overview', Icons.dashboard_outlined, Icons.dashboard),
  AppDestination('/mcp-servers', 'MCP Servers', Icons.dns_outlined, Icons.dns),
  AppDestination('/mcp-tools', 'MCP Tools', Icons.build_outlined, Icons.build),
  AppDestination('/portals', 'Portals', Icons.hub_outlined, Icons.hub),
  AppDestination('/chat', 'Chat', Icons.chat_bubble_outline, Icons.chat_bubble),
  AppDestination(
    '/audit',
    'Audit',
    Icons.receipt_long_outlined,
    Icons.receipt_long,
  ),
  AppDestination('/settings', 'Settings', Icons.tune_outlined, Icons.tune),
];

const secondaryDestinations = [
  AppDestination('/info', 'About', Icons.info_outline, Icons.info),
  AppDestination(
    '/contributors',
    'Contributors',
    Icons.group_outlined,
    Icons.group,
  ),
];

Page<void> _page(Widget child, GoRouterState state) =>
    NoTransitionPage<void>(key: state.pageKey, child: child);

const signInPath = '/sign-in';

/// [signedIn] decides whether the dashboard or the sign-in page is shown;
/// [refresh] tells the router to ask again when that changes.
GoRouter createRouter({
  bool Function()? signedIn,
  Listenable? refresh,
}) => GoRouter(
  refreshListenable: refresh,
  redirect: signedIn == null
      ? null
      : (context, state) {
          final inside = signedIn();
          final onSignIn = state.uri.path == signInPath;
          if (!inside && !onSignIn) return signInPath;
          if (inside && onSignIn) return '/';
          return null;
        },
  routes: [
    GoRoute(
      path: signInPath,
      name: 'Sign in',
      pageBuilder: (c, s) => _page(const SignInPage(), s),
    ),
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(
          path: '/',
          name: 'Overview',
          pageBuilder: (c, s) => _page(const OverviewPage(), s),
        ),
        GoRoute(
          path: '/mcp-servers',
          name: 'MCP Servers',
          pageBuilder: (c, s) => _page(const ServersPage(), s),
        ),
        // Preserve existing bookmarks and older incoming links.
        GoRoute(path: '/servers', redirect: (context, state) => '/mcp-servers'),
        GoRoute(
          path: '/mcp-tools',
          name: 'MCP Tools',
          pageBuilder: (c, s) => _page(
            ToolsPage(
              focus: s.extra is ToolFocus ? s.extra as ToolFocus : null,
            ),
            s,
          ),
        ),
        GoRoute(path: '/tools', redirect: (c, s) => '/mcp-tools'),
        GoRoute(
          path: '/portals',
          name: 'Portals',
          pageBuilder: (c, s) => _page(const PortalsPage(), s),
        ),
        GoRoute(
          path: '/chat',
          name: 'Chat',
          pageBuilder: (c, s) => _page(const ChatPage(), s),
        ),
        GoRoute(
          path: '/audit',
          name: 'Audit',
          pageBuilder: (c, s) => _page(const AuditPage(), s),
        ),
        GoRoute(
          path: '/settings',
          name: 'Settings',
          pageBuilder: (c, s) => _page(const SettingsPage(), s),
        ),
        GoRoute(
          path: '/info',
          name: 'Info',
          pageBuilder: (c, s) => _page(const InfoPage(), s),
        ),
        GoRoute(
          path: '/contributors',
          name: 'Contributors',
          pageBuilder: (c, s) => _page(const ContributorsPage(), s),
        ),
      ],
    ),
  ],
);
