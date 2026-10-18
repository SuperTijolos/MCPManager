import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../ui/sign_in.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'server_dialog.dart';

class ServersPage extends ConsumerStatefulWidget {
  const ServersPage({super.key});

  @override
  ConsumerState<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends ConsumerState<ServersPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(mcpHubProvider);
    final servers = [
      for (final s in hub.servers)
        if (_query.isEmpty ||
            s.config.name.toLowerCase().contains(_query) ||
            s.config.url.toLowerCase().contains(_query))
          s,
    ];

    return PageScaffold(
      title: 'MCP Servers',
      subtitle: 'Connect and manage your MCP servers',
      actions: [
        IconButton(
          tooltip: 'Reconnect all',
          icon: const Icon(Icons.refresh),
          onPressed: hub.servers.isEmpty
              ? null
              : () {
                  final notifier = ref.read(mcpHubProvider.notifier);
                  for (final s in hub.servers) {
                    if (s.config.enabled) notifier.connect(s.config.id);
                  }
                },
        ),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () => showServerDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('Add server'),
        ),
      ],
      child: hub.servers.isEmpty
          ? EmptyState(
              icon: Icons.dns_outlined,
              title: 'No servers yet',
              message: 'Add an MCP server (Streamable HTTP or legacy SSE, detected automatically). From a browser it must allow CORS for this origin.',
              action: FilledButton.icon(
                onPressed: () => showServerDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add your first server'),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ServerSummary(servers: hub.servers),
                const SizedBox(height: 16),
                TextField(
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Search servers',
                    suffixText: '${servers.length} shown',
                  ),
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: servers.isEmpty
                      ? const EmptyState(
                          icon: Icons.search_off,
                          title: 'No matching servers',
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            // Keep each card wide enough for its quick actions.
                            final columns = constraints.maxWidth >= 1140
                                ? 3
                                : constraints.maxWidth >= 740
                                ? 2
                                : 1;
                            // Fixed grid extents kept unused space below the
                            // metrics when the software row was removed. Let
                            // each card use its natural height instead.
                            const gap = 12.0;
                            final cardWidth =
                                (constraints.maxWidth - gap * (columns - 1)) /
                                columns;
                            return SingleChildScrollView(
                              key: const ValueKey('server-grid'),
                              child: Wrap(
                                spacing: gap,
                                runSpacing: gap,
                                children: [
                                  for (final server in servers)
                                    SizedBox(
                                      width: cardWidth,
                                      child: _ServerCard(
                                        key: ValueKey(server.config.id),
                                        runtime: server,
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
    );
  }
}

/// The full endpoint remains selectable even if it is wider than the card.
/// A dedicated copy action is easier to discover than tapping a truncated URL.
class _ServerEndpoint extends StatelessWidget {
  const _ServerEndpoint({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(
          alpha: 0.50,
        ),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Tooltip(
              message: url,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SelectableText(
                  url,
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy endpoint',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(content: Text('Endpoint copied')),
                );
            },
          ),
        ],
      ),
    );
  }
}

class _ServerSummary extends StatelessWidget {
  const _ServerSummary({required this.servers});
  final List<ServerRuntime> servers;

  @override
  Widget build(BuildContext context) {
    final connected = servers
        .where((s) => s.status == ServerStatus.connected)
        .length;
    final attention = servers
        .where(
          (s) =>
              s.status == ServerStatus.error ||
              s.status == ServerStatus.needsAuth,
        )
        .length;
    final theme = Theme.of(context);
    return Wrap(
      spacing: 18,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _SummaryStat(
          Icons.dns_outlined,
          '${servers.length} total',
          theme.colorScheme.onSurfaceVariant,
        ),
        _SummaryStat(
          Icons.check_circle_outline,
          '$connected connected',
          StatusColors.ok,
        ),
        if (attention > 0)
          _SummaryStat(
            Icons.warning_amber_rounded,
            '$attention need attention',
            StatusColors.warn,
          ),
      ],
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat(this.icon, this.label, this.color);
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

(String, Color, IconData) _serverStatus(ServerStatus status) =>
    switch (status) {
      ServerStatus.connected => (
        'Connected',
        StatusColors.ok,
        Icons.check_circle_outline,
      ),
      ServerStatus.connecting => ('Connecting', StatusColors.info, Icons.sync),
      ServerStatus.needsAuth => (
        'Sign-in required',
        StatusColors.warn,
        Icons.lock_outline,
      ),
      ServerStatus.error => ('Error', StatusColors.bad, Icons.error_outline),
      ServerStatus.disabled => (
        'Disabled',
        StatusColors.muted,
        Icons.pause_circle_outline,
      ),
      ServerStatus.idle => ('Idle', StatusColors.muted, Icons.circle_outlined),
    };

class _ServerCard extends ConsumerWidget {
  const _ServerCard({super.key, required this.runtime});
  final ServerRuntime runtime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hub = ref.read(mcpHubProvider.notifier);
    final (label, color, icon) = _serverStatus(runtime.status);
    final config = runtime.config;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    config.name,
                    style: theme.textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(label, color, icon: icon),
              ],
            ),
            const SizedBox(height: 12),
            _ServerEndpoint(url: config.url),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                StatusChip(
                  config.transport == McpTransport.auto
                      ? 'Auto transport'
                      : config.transport.label,
                  StatusColors.muted,
                ),
                if (config.oauth)
                  const StatusChip(
                    'OAuth',
                    StatusColors.info,
                    icon: Icons.vpn_key_outlined,
                  )
                else if (config.hasStaticAuthorization)
                  const StatusChip(
                    'Token',
                    StatusColors.muted,
                    icon: Icons.key_outlined,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _CardMetric('TOOLS', '${runtime.tools.length}'),
                ),
                Expanded(
                  child: _CardMetric(
                    'CONNECT',
                    runtime.latencyMs == null ? '—' : '${runtime.latencyMs} ms',
                  ),
                ),
                Expanded(
                  child: _CardMetric(
                    'CHECKED',
                    runtime.checkedAt == null
                        ? '—'
                        : formatTime(runtime.checkedAt!),
                  ),
                ),
              ],
            ),
            if (runtime.error != null) ...[
              const SizedBox(height: 8),
              Tooltip(
                message: runtime.error!,
                child: Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 14,
                      color: StatusColors.bad,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        runtime.error!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted?.copyWith(color: StatusColors.bad),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 8),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 4),
            Row(
              key: const ValueKey('server-card-actions'),
              children: [
                Switch.adaptive(
                  value: config.enabled,
                  onChanged: (value) => hub.setEnabled(config.id, value),
                ),
                Expanded(child: Text('Enabled', style: muted, maxLines: 1)),
                if (runtime.status == ServerStatus.needsAuth)
                  TextButton.icon(
                    onPressed: () => signInToServer(context, ref, config.id),
                    icon: const Icon(Icons.login_outlined, size: 18),
                    label: const Text('Sign in'),
                  ),
                if (runtime.tools.isNotEmpty)
                  IconButton(
                    tooltip: 'Tools',
                    icon: const Icon(Icons.build_outlined),
                    onPressed: () => context.go('/mcp-tools'),
                  ),
                IconButton(
                  tooltip: 'Connection details',
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => _showServerDetails(context, runtime),
                ),
                IconButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showServerDialog(context, existing: config),
                ),
                PopupMenuButton<_ServerAction>(
                  tooltip: 'More server actions',
                  onSelected: (action) => switch (action) {
                    _ServerAction.reconnect => hub.connect(config.id),
                    _ServerAction.signOut => hub.signOut(config.id),
                    _ServerAction.remove => _confirmRemove(context, hub),
                  },
                  itemBuilder: (context) => [
                    if (config.enabled &&
                        runtime.status != ServerStatus.connecting)
                      const PopupMenuItem(
                        value: _ServerAction.reconnect,
                        child: _ActionLabel(Icons.refresh, 'Reconnect'),
                      ),
                    if (config.oauth &&
                        runtime.status == ServerStatus.connected)
                      const PopupMenuItem(
                        value: _ServerAction.signOut,
                        child: _ActionLabel(Icons.logout, 'Sign out'),
                      ),
                    const PopupMenuItem(
                      value: _ServerAction.remove,
                      child: _ActionLabel(Icons.delete_outline, 'Remove'),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, McpHub hub) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${runtime.config.name}?'),
        content: const Text(
          'The server and its tools disappear from the app. Past audit events are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) hub.removeServer(runtime.config.id);
  }
}

enum _ServerAction { reconnect, signOut, remove }

class _ActionLabel extends StatelessWidget {
  const _ActionLabel(this.icon, this.title);
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(title)],
  );
}

class _CardMetric extends StatelessWidget {
  const _CardMetric(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          maxLines: 1,
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
      ],
    );
  }
}

Future<void> _showServerDetails(BuildContext context, ServerRuntime runtime) {
  final config = runtime.config;
  final (label, color, icon) = _serverStatus(runtime.status);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(config.name, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: 'Close details',
            onPressed: () => Navigator.pop(dialogContext),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              StatusChip(label, color, icon: icon),
              const SizedBox(height: 16),
              SelectableText(
                config.url,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: config.url)),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy endpoint'),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 22,
                runSpacing: 16,
                children: [
                  _DetailFact('Transport', config.transport.label),
                  _DetailFact(
                    'Authentication',
                    config.oauth
                        ? 'OAuth'
                        : config.hasStaticAuthorization
                        ? 'Bearer token'
                        : 'None',
                  ),
                  _DetailFact('Tools', '${runtime.tools.length}'),
                  _DetailFact(
                    'Connect latency',
                    runtime.latencyMs == null
                        ? 'Not measured'
                        : '${runtime.latencyMs} ms',
                  ),
                  _DetailFact(
                    'Last checked',
                    runtime.checkedAt == null
                        ? 'Not checked'
                        : formatTime(runtime.checkedAt!),
                  ),
                  if (runtime.info != null) ...[
                    _DetailFact(
                      'Server software',
                      '${runtime.info!.name} ${runtime.info!.version}',
                    ),
                    _DetailFact('MCP protocol', runtime.info!.protocolVersion),
                  ],
                ],
              ),
              if (runtime.error != null) ...[
                const SizedBox(height: 18),
                SelectableText(
                  runtime.error!,
                  style: const TextStyle(color: StatusColors.bad),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'Connection trace',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (runtime.trace.isEmpty)
                const Text('No connection attempts recorded yet.')
              else
                CodeBlock(runtime.trace.join('\n'), maxHeight: 260),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
        FilledButton.tonalIcon(
          onPressed: () {
            Navigator.pop(dialogContext);
            showServerDialog(context, existing: config);
          },
          icon: const Icon(Icons.edit_outlined, size: 18),
          label: const Text('Edit server'),
        ),
      ],
    ),
  );
}

class _DetailFact extends StatelessWidget {
  const _DetailFact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 180,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 3),
          SelectableText(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}
