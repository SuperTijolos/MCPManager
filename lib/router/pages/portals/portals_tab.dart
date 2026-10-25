import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_api.dart';
import '../../../engine/portal/portal_controller.dart';
import '../../../engine/portal/portal_models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Runs a gateway call and reports a failure as a message instead of an error.
Future<T?> guarded<T>(BuildContext context, Future<T> Function() action) async {
  try {
    return await action();
  } on PortalApiException catch (e) {
    if (context.mounted) showSnack(context, e.message);
    return null;
  }
}

class PortalsTab extends ConsumerWidget {
  const PortalsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(portalControllerProvider);
    final theme = Theme.of(context);

    if (data.portals.isEmpty) {
      return EmptyState(
        icon: Icons.hub_outlined,
        title: 'No portals yet',
        message: data.servers.isEmpty
            ? 'Add some MCP servers first (the MCP Servers page), then group '
                  'them into a portal.'
            : 'A portal publishes a set of servers as one MCP endpoint for '
                  'Claude, ChatGPT or any MCP client.',
        action: FilledButton.icon(
          key: const ValueKey('new-portal'),
          onPressed: () => showPortalDialog(context),
          icon: const Icon(Icons.add),
          label: const Text('New portal'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${data.portals.length} portal${data.portals.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            FilledButton.icon(
              key: const ValueKey('new-portal'),
              onPressed: () => showPortalDialog(context),
              icon: const Icon(Icons.add),
              label: const Text('New portal'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1000 ? 2 : 1;
              const gap = 12.0;
              final width =
                  (constraints.maxWidth - gap * (columns - 1)) / columns;
              return SingleChildScrollView(
                child: Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final p in data.portals)
                      SizedBox(width: width, child: _PortalCard(p)),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PortalCard extends ConsumerWidget {
  const _PortalCard(this.portal);
  final GatewayPortal portal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(portalControllerProvider);
    final controller = ref.read(portalControllerProvider.notifier);
    final names = [
      for (final s in portal.servers)
        data.server(s.serverId)?.name ?? s.serverId,
    ];
    return Card(
      key: ValueKey('portal-${portal.slug}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    portal.name,
                    style: theme.textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                StatusChip(
                  portal.enabled ? 'Live' : 'Off',
                  portal.enabled ? StatusColors.ok : StatusColors.muted,
                ),
              ],
            ),
            if (portal.description.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                portal.description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 12),
            _CopyRow(text: portal.endpoint),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (names.isEmpty)
                  const StatusChip('No servers', StatusColors.warn)
                else
                  for (final n in names)
                    StatusChip(n, StatusColors.muted, icon: Icons.dns_outlined),
                if (portal.excludedTools.isNotEmpty)
                  StatusChip(
                    '${portal.excludedTools.length} tool${portal.excludedTools.length == 1 ? '' : 's'} left out',
                    StatusColors.info,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Divider(),
            // A wrapping row: on a phone the buttons flow onto a second line.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              children: [
                Switch.adaptive(
                  key: ValueKey('portal-switch-${portal.slug}'),
                  value: portal.enabled,
                  onChanged: (on) => guarded(
                    context,
                    () => controller.savePortal(
                      id: portal.id,
                      name: portal.name,
                      enabled: on,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    portal.enabled ? 'Accepting calls' : 'Switched off',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                TextButton.icon(
                  key: ValueKey('portal-connect-${portal.slug}'),
                  onPressed: () => showConnectClientDialog(context, portal),
                  icon: const Icon(Icons.power_outlined, size: 18),
                  label: const Text('Connect'),
                ),
                IconButton(
                  key: ValueKey('portal-tools-${portal.slug}'),
                  tooltip: 'Tools in this portal',
                  icon: const Icon(Icons.build_outlined),
                  onPressed: () => showPortalToolsDialog(context, portal),
                ),
                IconButton(
                  key: ValueKey('portal-edit-${portal.slug}'),
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () => showPortalDialog(context, existing: portal),
                ),
                IconButton(
                  key: ValueKey('portal-delete-${portal.slug}'),
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDelete(context, ref),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${portal.name}?'),
        content: const Text(
          'Clients using this portal\'s address stop working. The servers '
          'behind it stay as they are.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-delete'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await guarded(
        context,
        () =>
            ref.read(portalControllerProvider.notifier).deletePortal(portal.id),
      );
    }
  }
}

/// A selectable one-line value with a copy button.
class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                text,
                maxLines: 1,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy address',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              showSnack(context, 'Address copied');
            },
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------- dialogs

Future<void> showPortalDialog(
  BuildContext context, {
  GatewayPortal? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => PortalDialog(existing: existing),
);

/// Create a portal, or change its name, address and servers.
class PortalDialog extends ConsumerStatefulWidget {
  const PortalDialog({super.key, this.existing});
  final GatewayPortal? existing;

  @override
  ConsumerState<PortalDialog> createState() => _PortalDialogState();
}

class _PortalDialogState extends ConsumerState<PortalDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _slug = TextEditingController(text: widget.existing?.slug ?? '');
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final Set<String> _servers = {
    for (final s in widget.existing?.servers ?? const <GatewayPortalServer>[])
      if (s.enabled) s.serverId,
  };
  bool _slugEdited = false;
  bool _busy = false;
  String? _error;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _slugEdited = _editing;
  }

  @override
  void dispose() {
    _name.dispose();
    _slug.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final slug = _slug.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Give the portal a name.');
      return;
    }
    if (slug.isEmpty || slugify(slug) != slug) {
      setState(
        () =>
            _error = 'The address uses lowercase letters, numbers and hyphens.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final existing = widget.existing;
    try {
      await ref
          .read(portalControllerProvider.notifier)
          .savePortal(
            id: existing?.id,
            name: name,
            slug: slug,
            description: _description.text.trim(),
            servers: [
              // Keep the order the portal already had; new ones go last.
              for (final s
                  in existing?.servers ?? const <GatewayPortalServer>[])
                if (_servers.contains(s.serverId))
                  GatewayPortalServer(s.serverId),
              for (final id in _servers)
                if (!(existing?.servers.any((s) => s.serverId == id) ?? false))
                  GatewayPortalServer(id),
            ],
          );
      if (mounted) Navigator.pop(context);
    } on PortalApiException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(portalControllerProvider);
    final theme = Theme.of(context);
    final base = data.status?.baseUrl ?? data.serverUrl;
    return AlertDialog(
      title: Text(_editing ? 'Edit portal' : 'New portal'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('portal-name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name'),
                onChanged: (v) {
                  if (!_slugEdited) setState(() => _slug.text = slugify(v));
                },
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('portal-slug'),
                controller: _slug,
                decoration: InputDecoration(
                  labelText: 'Address',
                  prefixText: '$base/mcp/',
                ),
                onChanged: (_) => setState(() => _slugEdited = true),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('portal-description'),
                controller: _description,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  helperText: 'Shown to clients as the portal\'s instructions.',
                ),
              ),
              const SizedBox(height: 16),
              Text('Servers in this portal', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              if (data.servers.isEmpty)
                Text(
                  'No servers yet. Add some on the MCP Servers page first.',
                  style: theme.textTheme.bodySmall,
                )
              else
                for (final s in data.servers)
                  CheckboxListTile(
                    key: ValueKey('portal-server-${s.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _servers.contains(s.id),
                    title: Text(s.name),
                    subtitle: Text(s.url, overflow: TextOverflow.ellipsis),
                    onChanged: (on) => setState(() {
                      if (on == true) {
                        _servers.add(s.id);
                      } else {
                        _servers.remove(s.id);
                      }
                    }),
                  ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const ValueKey('portal-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('portal-save'),
          onPressed: _busy ? null : _save,
          child: Text(_editing ? 'Save' : 'Create portal'),
        ),
      ],
    );
  }
}

Future<void> showConnectClientDialog(
  BuildContext context,
  GatewayPortal portal,
) => showDialog<void>(
  context: context,
  builder: (_) => _ConnectClientDialog(portal),
);

/// How to point an MCP client at the portal.
class _ConnectClientDialog extends StatelessWidget {
  const _ConnectClientDialog(this.portal);
  final GatewayPortal portal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final url = portal.endpoint;
    return AlertDialog(
      title: Text('Connect to ${portal.name}'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Address', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              _CopyRow(text: url),
              const SizedBox(height: 18),
              Text(
                'Claude and ChatGPT (web or app)',
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                'Add a custom connector with the address above. When it asks '
                'you to sign in, sign in with GitHub on the page that opens '
                '(or enter the admin token). Nothing else to copy.',
                style: muted,
              ),
              const SizedBox(height: 18),
              Text('Claude Code', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('Replace TOKEN with one from the Access tab.', style: muted),
              const SizedBox(height: 6),
              CodeBlock(
                'claude mcp add --transport http ${portal.slug} $url \\\n'
                '  --header "Authorization: Bearer TOKEN"',
                maxHeight: 120,
              ),
              const SizedBox(height: 18),
              Text('Any other client', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              CodeBlock(
                '{\n'
                '  "mcpServers": {\n'
                '    "${portal.slug}": {\n'
                '      "url": "$url",\n'
                '      "headers": { "Authorization": "Bearer TOKEN" }\n'
                '    }\n'
                '  }\n'
                '}',
                maxHeight: 200,
              ),
              if (url.startsWith('http://') &&
                  !url.contains('localhost') &&
                  !url.contains('127.0.0.1')) ...[
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: StatusColors.warn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This address is not HTTPS, so the token travels in the '
                        'clear. Put the gateway behind HTTPS before sharing it.',
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

Future<void> showPortalToolsDialog(
  BuildContext context,
  GatewayPortal portal,
) => showDialog<void>(
  context: context,
  builder: (_) => _PortalToolsDialog(portal),
);

/// What the portal exposes right now, with a switch to leave a tool out.
class _PortalToolsDialog extends ConsumerStatefulWidget {
  const _PortalToolsDialog(this.portal);
  final GatewayPortal portal;

  @override
  ConsumerState<_PortalToolsDialog> createState() => _PortalToolsDialogState();
}

class _PortalToolsDialogState extends ConsumerState<_PortalToolsDialog> {
  GatewayToolList? _list;
  String? _error;
  late Set<String> _excluded = {...widget.portal.excludedTools};
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load(refresh: false);
  }

  Future<void> _load({required bool refresh}) async {
    setState(() {
      _list = null;
      _error = null;
    });
    try {
      final list = await ref
          .read(portalControllerProvider.notifier)
          .portalTools(widget.portal.id, refresh: refresh);
      if (mounted) setState(() => _list = list);
    } on PortalApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _toggle(GatewayTool tool, bool included) async {
    final next = {..._excluded};
    if (included) {
      next.remove(tool.key);
    } else {
      next.add(tool.key);
    }
    final saved = await guarded(
      context,
      () => ref
          .read(portalControllerProvider.notifier)
          .savePortal(
            id: widget.portal.id,
            name: widget.portal.name,
            excludedTools: next.toList(),
          ),
    );
    if (saved != null && mounted) setState(() => _excluded = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _list;
    final shown = list == null
        ? const <GatewayTool>[]
        : [
            for (final t in list.tools)
              if (_query.isEmpty ||
                  t.name.toLowerCase().contains(_query) ||
                  t.description.toLowerCase().contains(_query))
                t,
          ];
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text('Tools in ${widget.portal.name}')),
          IconButton(
            tooltip: 'Ask the servers again',
            icon: const Icon(Icons.refresh),
            onPressed: () => _load(refresh: true),
          ),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 460,
        child: _error != null
            ? Center(child: Text(_error!))
            : list == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final p in list.problems.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.error_outline,
                            size: 16,
                            color: StatusColors.bad,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${ref.read(portalControllerProvider).server(p.key)?.name ?? p.key} could not be reached: ${p.value}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: StatusColors.bad,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search tools',
                    ),
                    onChanged: (v) =>
                        setState(() => _query = v.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: shown.isEmpty
                        ? Center(
                            child: Text(
                              list.tools.isEmpty
                                  ? 'This portal exposes no tools yet.'
                                  : 'No matching tools.',
                            ),
                          )
                        : ListView(
                            children: [
                              for (final t in shown)
                                SwitchListTile(
                                  key: ValueKey('tool-${t.name}'),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  value: !_excluded.contains(t.key),
                                  onChanged: t.visible
                                      ? (on) => _toggle(t, on)
                                      : null,
                                  title: Text(t.name),
                                  subtitle: Text(
                                    [
                                      if (!t.visible)
                                        'Hidden by a tool rule on this gateway',
                                      if (t.rules.isNotEmpty)
                                        'Rules: ${t.rules.join(', ')}',
                                      t.description,
                                    ].where((x) => x.isNotEmpty).join(' · '),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
