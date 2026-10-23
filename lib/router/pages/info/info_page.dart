import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/app_info.dart';
import '../../../engine/mcp/oauth/oauth_service.dart';
import '../../../ui/links.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class InfoPage extends ConsumerWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );

    return PageScaffold(
      title: 'About',
      subtitle: '$appName · a control panel for MCP servers',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 900 ? 2 : 1;
          final width = (constraints.maxWidth - 16 * (columns - 1)) / columns;
          Widget tile(Widget child) => SizedBox(width: width, child: child);

          return ListView(
            children: [
              _Hero(muted: muted),
              const SizedBox(height: 16),
              const _HowItFits(),
              const SizedBox(height: 16),
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  tile(
                    _Feature(
                      icon: Icons.dns_outlined,
                      title: 'MCP Servers',
                      route: '/mcp-servers',
                      body:
                          'Connect MCP servers over Streamable HTTP or the older HTTP+SSE transport; the app detects which '
                          'one a server speaks, including a bare host:port. Authenticate with a bearer token or OAuth, '
                          'add custom headers, and test a connection before saving it. Every card shows status, protocol, '
                          'latency and a trace of what was tried.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.build_outlined,
                      title: 'MCP Tools & rules',
                      route: '/mcp-tools',
                      body:
                          'Browse every tool, read its schema, and run it by hand. Rules reshape what the Operator sees: '
                          'add arguments such as "reason" or "expected result" to many tools at once (kept in the audit log, '
                          'not sent to the server), inject fixed values the model never sees, append instructions, or hide '
                          'tools from the Operator. Compare original and effective schemas in a diff.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.hub_outlined,
                      title: 'Portals',
                      route: '/portals',
                      body:
                          'Publish chosen servers as authenticated MCP endpoints for Claude, ChatGPT or any MCP client. '
                          'Portals run on the gateway, a small server you host: it applies your tool rules, checks access '
                          'tokens or OAuth sign-ins, forwards each call and keeps its own audit log. This page manages it.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.chat_bubble_outline,
                      title: 'Chat',
                      route: '/chat',
                      body:
                          'Chat with Gemma 4 (through Ollama) or any OpenAI-compatible model. It can inspect and manage your '
                          'servers, find the right tool for a job, recover from failed calls on its own, and run tools, '
                          'asking you first. Conversations are saved and searchable.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.receipt_long_outlined,
                      title: 'Audit',
                      route: '/audit',
                      body:
                          'Every tool call, connection, sign-in and management action is recorded with who did it, how it '
                          'was approved, what the model sent, what was forwarded to the server, and the result. Secrets are '
                          'redacted. Filter, search and page through up to 1000 events.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.tune_outlined,
                      title: 'Settings',
                      route: '/settings',
                      body:
                          'Model providers and which models are on, Operator limits and your own instructions, plus storage, '
                          'backup and restore (credentials left out unless you ask) and a full reset.',
                    ),
                  ),
                  tile(
                    _Feature(
                      icon: Icons.dashboard_outlined,
                      title: 'Overview',
                      route: '/',
                      body:
                          'Servers online, tools available, calls per hour, error rate and latency, the busiest tools and '
                          'a reachability check for the Operator\'s model.',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const _Details(
                icon: Icons.shield_outlined,
                title: 'Safety, in detail',
                initiallyExpanded: true,
                points: [
                  'Only tools a server marks readOnly run without asking; everything else, including tools with no '
                      'annotations, waits for your Approve, Always allow (this conversation only) or Deny.',
                  'Changes to configuration or data (add, update or remove a server, switch model, clear the audit log) '
                      'are approved every time and can never be "always allowed".',
                  'Tool output, audit text and server descriptions reach the model as untrusted data. The system prompt '
                      'tells it never to follow instructions found there, and even a model that disobeys is stopped at '
                      'the approval gate.',
                  'The tools-by-purpose list the model sees contains only tool names the app computed, never text written '
                      'by a server, so a server cannot slip instructions into the system prompt.',
                  'Denied calls never reach the server and are recorded. Rejected-before-forwarding calls (missing a '
                      'required rule argument) are recorded too.',
                  'Arguments and results are stored redacted (secret-looking keys, tokens) and size-limited; management '
                      'actions and their denials are audited with the actor and approval mode.',
                ],
              ),
              const _Details(
                icon: Icons.cable_outlined,
                title: 'Connecting servers',
                points: [
                  'Transports: Streamable HTTP (usually /mcp) and legacy HTTP+SSE (usually /sse). Auto-detect tries both, '
                      'tries the sibling path, and accepts a transport only when it can also list tools.',
                  'Authentication: none, a bearer token, or OAuth with PKCE and dynamic client registration. Sign-in '
                      'returns to this app\'s callback page, which the server\'s OAuth provider must allow. Servers set up '
                      'only for ChatGPT (https://chatgpt.com/connector/oauth/*) reject it until that is added.',
                  'Because this runs in a browser, every server must allow CORS for this origin and accept the '
                      'Authorization header; for Streamable HTTP sessions it must also expose Mcp-Session-Id.',
                  'stdio servers cannot be reached from a browser.',
                ],
              ),
              const _Details(
                icon: Icons.storage_outlined,
                title: 'Where your data lives',
                points: [
                  'Everything is stored in this browser\'s local storage, per origin. Nothing is sent to a MCP Manager '
                      'server because there is none.',
                  'Tokens and API keys are stored there too, unencrypted, so use a browser profile you trust. Backups '
                      'leave credentials out unless you tick the box.',
                  'A browser gives an origin about 5 MB; Settings → Data & privacy shows how much is used.',
                  'Another browser, device or address (even localhost vs an IP) starts empty: use export and import.',
                ],
              ),
              const _Details(
                icon: Icons.keyboard_outlined,
                title: 'Tips',
                points: [
                  'Operator: Enter sends, Shift+Enter adds a line. Switching conversations stops a run in progress.',
                  'Tools: drag the divider to resize the list (double-click resets it, ←/→ nudge it when focused). '
                      'Use Select to add the same argument to several tools at once.',
                  'Rules at the top of the list win when two define the same argument; drag to reorder.',
                  'Audit: expand an event to compare what the model sent with what the server received.',
                ],
              ),
              const SizedBox(height: 8),
              _Facts(ref: ref),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => openLink(context, ref, appRepoUrl),
                    icon: const Icon(Icons.code, size: 18),
                    label: const Text('Source on GitHub'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => openLink(context, ref, mcpSpecUrl),
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('About MCP'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => openLink(context, ref, ollamaUrl),
                    icon: const Icon(Icons.memory, size: 18),
                    label: const Text('Ollama'),
                  ),
                  TextButton.icon(
                    onPressed: () => context.go('/contributors'),
                    icon: const Icon(Icons.group_outlined, size: 18),
                    label: const Text('Contributors'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Built with Flutter, Riverpod, go_router, fl_chart and ollama_dart. MIT licensed.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.muted});
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.hub_rounded,
                  size: 40,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(appName, style: theme.textTheme.headlineSmall),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          const StatusChip('v$appVersion', StatusColors.info),
                          StatusChip(
                            kReleaseMode ? 'release build' : 'debug build',
                            kReleaseMode ? StatusColors.ok : StatusColors.warn,
                          ),
                          const StatusChip('web', StatusColors.muted),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'MCP Manager connects the Model Context Protocol servers you use, lets you test and audit every '
              'call, and puts a local model, Gemma 4 through Ollama or any OpenAI-compatible endpoint, in front '
              'of them as an Operator that can diagnose and act, with your approval for anything that is not read-only. '
              'It was built for the Hacktober Portimão festival.',
              style: muted,
            ),
          ],
        ),
      ),
    );
  }
}

/// You → Operator → MCP Manager → servers, as a picture in words.
class _HowItFits extends StatelessWidget {
  const _HowItFits();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget box(IconData icon, String title, String sub) => Container(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 210),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        color: theme.colorScheme.primary.withValues(alpha: 0.06),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.primary),
          const SizedBox(height: 6),
          Text(title, style: theme.textTheme.titleSmall),
          Text(
            sub,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
    Widget arrow() => const Padding(
      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Icon(Icons.arrow_forward_rounded, size: 18),
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How it fits together', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 8,
              children: [
                box(Icons.person_outline, 'You', 'Ask, approve, review'),
                arrow(),
                box(
                  Icons.smart_toy_outlined,
                  'Operator',
                  'Gemma 4 · Ollama · any /v1 model',
                ),
                arrow(),
                box(
                  Icons.verified_user_outlined,
                  'MCP Manager',
                  'Approvals · rules · audit',
                ),
                arrow(),
                box(
                  Icons.dns_outlined,
                  'MCP servers',
                  'Streamable HTTP · SSE · OAuth',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({
    required this.icon,
    required this.title,
    required this.body,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String body;
  final String route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title, style: theme.textTheme.titleMedium),
                ),
                TextButton(
                  onPressed: () => context.go(route),
                  child: const Text('Open'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({
    required this.icon,
    required this.title,
    required this.points,
    this.initiallyExpanded = false,
  });

  final IconData icon;
  final String title;
  final List<String> points;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            leading: Icon(icon, color: theme.colorScheme.primary),
            title: Text(title, style: theme.textTheme.titleMedium),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in points)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 6, right: 10),
                        child: Icon(Icons.circle, size: 5),
                      ),
                      Expanded(
                        child: Text(
                          p,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Facts about this running copy, useful when asking for help.
class _Facts extends StatelessWidget {
  const _Facts({required this.ref});
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final redirect = ref.watch(oauthRedirectUriProvider);
    final rows = {
      'Version': '$appVersion (${kReleaseMode ? 'release' : 'debug'})',
      'Origin': '${redirect.scheme}://${redirect.authority}',
      'OAuth redirect URI': redirect.toString(),
      'Platform': 'Web',
    };
    return Card(
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading: const Icon(Icons.info_outline),
          title: Text('This copy', style: theme.textTheme.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in rows.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 150,
                      child: Text(
                        e.key,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Expanded(child: SelectableText(e.value)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
