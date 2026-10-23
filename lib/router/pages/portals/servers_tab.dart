import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../engine/portal/portal_controller.dart';
import '../../../engine/portal/portal_models.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'portals_tab.dart' show guarded;

/// Servers: which of this app's servers the gateway has, what it holds, and
/// the tool rules it applies.
class ServersTab extends ConsumerStatefulWidget {
  const ServersTab({super.key});

  @override
  ConsumerState<ServersTab> createState() => _ServersTabState();
}

class _ServersTabState extends ConsumerState<ServersTab> {
  final _busy = <String>{};

  /// Server id → the last test: a result, or the error that replaced one.
  final _tests = <String, Object>{};

  Future<void> _publish(McpServerConfig config) async {
    setState(() => _busy.add(config.id));
    await guarded(
      context,
      () => ref.read(portalControllerProvider.notifier).publishServer(config),
    );
    if (mounted) setState(() => _busy.remove(config.id));
  }

  Future<void> _test(String id) async {
    setState(() {
      _busy.add(id);
      _tests.remove(id);
    });
    try {
      final result = await ref
          .read(portalControllerProvider.notifier)
          .testServer(id);
      if (mounted) setState(() => _tests[id] = result);
    } catch (e) {
      if (mounted) setState(() => _tests[id] = '$e');
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  Future<void> _remove(GatewayServer server) async {
    final data = ref.read(portalControllerProvider);
    final users = data.portals
        .where((p) => p.servers.any((s) => s.serverId == server.id))
        .toList();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${server.name} from the gateway?'),
        content: Text(
          users.isEmpty
              ? 'The server itself is not touched; only this gateway forgets it.'
              : 'It is also taken out of ${users.map((p) => p.name).join(', ')}. '
                    'The server itself is not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-server'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await guarded(
        context,
        () =>
            ref.read(portalControllerProvider.notifier).removeServer(server.id),
      );
    }
  }

  Future<void> _pushRules() async {
    final sent = await guarded(
      context,
      () => ref.read(portalControllerProvider.notifier).pushRules(),
    );
    if (sent != null && mounted) {
      showSnack(
        context,
        'Sent ${sent.rules} rule${sent.rules == 1 ? '' : 's'} and '
        '${sent.overrides} per-tool setting${sent.overrides == 1 ? '' : 's'} to the gateway',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ref.watch(portalControllerProvider);
    final hub = ref.watch(mcpHubProvider);
    final rules = ref.watch(toolRulesProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      children: [
        Text('From this app', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Putting a server on the gateway sends its address and headers, '
          'including any token, to the gateway. It keeps the same id here and '
          'there, so tool rules written in this app apply to it.',
          style: muted,
        ),
        const SizedBox(height: 8),
        if (hub.servers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('This app has no servers yet. Add one in MCP Servers.'),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, s) in hub.servers.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _AppServerRow(
                    config: s.config,
                    onGateway: data.server(s.config.id) != null,
                    busy: _busy.contains(s.config.id),
                    onPublish: () => _publish(s.config),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 24),
        Text('On the gateway', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (data.servers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('The gateway has no servers yet.'),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, s) in data.servers.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _GatewayServerRow(
                    server: s,
                    portals: [
                      for (final p in data.portals)
                        if (p.servers.any((x) => x.serverId == s.id)) p.name,
                    ],
                    busy: _busy.contains(s.id),
                    test: _tests[s.id],
                    onTest: () => _test(s.id),
                    onRemove: () => _remove(s),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 24),
        Text('Tool rules', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Rules and hidden tools from MCP Tools shape what portal clients see: '
          'extra arguments kept only in the audit log, fixed values, added '
          'instructions. The gateway applies the copy you send here.',
          style: muted,
        ),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.rule),
            title: Text(
              'This app: ${rules.rules.length} rule${rules.rules.length == 1 ? '' : 's'}, '
              '${rules.overrides.length} per-tool setting${rules.overrides.length == 1 ? '' : 's'}',
            ),
            subtitle: Text(
              'Gateway has ${data.status?.rules ?? 0} rule${(data.status?.rules ?? 0) == 1 ? '' : 's'}.',
            ),
            trailing: FilledButton.tonal(
              key: const ValueKey('push-rules'),
              onPressed: _pushRules,
              child: const Text('Send to gateway'),
            ),
          ),
        ),
      ],
    );
  }
}

class _AppServerRow extends StatelessWidget {
  const _AppServerRow({
    required this.config,
    required this.onGateway,
    required this.busy,
    required this.onPublish,
  });

  final McpServerConfig config;
  final bool onGateway;
  final bool busy;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final publishable = PortalController.publishable(config);
    return ListTile(
      key: ValueKey('app-server-${config.id}'),
      leading: const Icon(Icons.dns_outlined),
      title: Text(config.name),
      subtitle: Text(
        publishable
            ? config.url
            : '${config.url}\nUses OAuth, which signs in through this browser. '
                  'A gateway cannot use it; give it a token instead.',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      isThreeLine: !publishable,
      trailing: !publishable
          ? const StatusChip(
              'OAuth',
              StatusColors.muted,
              icon: Icons.lock_outline,
            )
          : busy
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : onGateway
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const StatusChip(
                  'On gateway',
                  StatusColors.ok,
                  icon: Icons.check_circle_outline,
                ),
                const SizedBox(width: 8),
                TextButton(
                  key: ValueKey('update-${config.id}'),
                  onPressed: onPublish,
                  child: const Text('Update'),
                ),
              ],
            )
          : FilledButton.tonal(
              key: ValueKey('publish-${config.id}'),
              onPressed: onPublish,
              child: const Text('Put on gateway'),
            ),
    );
  }
}

class _GatewayServerRow extends StatelessWidget {
  const _GatewayServerRow({
    required this.server,
    required this.portals,
    required this.busy,
    required this.test,
    required this.onTest,
    required this.onRemove,
  });

  final GatewayServer server;
  final List<String> portals;
  final bool busy;
  final Object? test;
  final VoidCallback onTest;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = test;
    final lines = <Widget>[
      Text(server.url, overflow: TextOverflow.ellipsis),
      Text(
        'Tools are named ${server.slug}__… · '
        '${server.headerNames.isEmpty ? 'no headers' : '${server.headerNames.length} header${server.headerNames.length == 1 ? '' : 's'} stored'}'
        ' · ${portals.isEmpty ? 'in no portal' : 'in ${portals.join(', ')}'}',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
      if (result is GatewayTestResult)
        Text(
          result.ok
              ? '${result.toolCount} tool${result.toolCount == 1 ? '' : 's'}'
                    '${result.serverName == null ? '' : ' · ${result.serverName} ${result.serverVersion ?? ''}'}'
                    '${result.transport == null ? '' : ' · ${result.transport}'}'
              : 'Could not connect: ${result.error}',
          key: ValueKey('test-result-${server.id}'),
          style: TextStyle(
            color: result.ok ? StatusColors.ok : StatusColors.bad,
          ),
        )
      else if (result is String)
        Text(result, style: const TextStyle(color: StatusColors.bad)),
    ];
    return ListTile(
      key: ValueKey('gateway-server-${server.id}'),
      leading: const Icon(Icons.cloud_outlined),
      title: Text(server.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: lines,
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            TextButton(
              key: ValueKey('test-${server.id}'),
              onPressed: onTest,
              child: const Text('Test'),
            ),
          IconButton(
            key: ValueKey('remove-${server.id}'),
            tooltip: 'Remove from the gateway',
            icon: const Icon(Icons.delete_outline),
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
