import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/core/url.dart';
import '../../../engine/mcp/headers.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

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
      title: 'Servers',
      subtitle: 'Downstream MCP servers (Streamable HTTP)',
      actions: [
        IconButton(
          tooltip: 'Reconnect all',
          icon: const Icon(Icons.refresh),
          onPressed: hub.servers.isEmpty
              ? null
              : () {
                  final notifier = ref.read(mcpHubProvider.notifier);
                  for (final s in hub.servers) {
                    notifier.connect(s.config.id);
                  }
                },
        ),
        const SizedBox(width: 4),
        FilledButton.icon(
          onPressed: () => showServerDialog(context, ref),
          icon: const Icon(Icons.add),
          label: const Text('Add server'),
        ),
      ],
      child: hub.servers.isEmpty
          ? EmptyState(
              icon: Icons.dns_outlined,
              title: 'No servers yet',
              message: 'Add an MCP server that speaks Streamable HTTP. From a browser it must allow CORS for this origin.',
              action: FilledButton.icon(
                onPressed: () => showServerDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Add your first server'),
              ),
            )
          : Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search servers',
                  ),
                  onChanged: (v) =>
                      setState(() => _query = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: servers.isEmpty
                      ? const EmptyState(
                          icon: Icons.search_off,
                          title: 'No matching servers',
                        )
                      : ListView.separated(
                          itemCount: servers.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, i) => _ServerCard(servers[i]),
                        ),
                ),
              ],
            ),
    );
  }
}

class _ServerCard extends ConsumerWidget {
  const _ServerCard(this.runtime);
  final ServerRuntime runtime;

  (String, Color, IconData) get _status => switch (runtime.status) {
    ServerStatus.connected => (
      'Connected',
      StatusColors.ok,
      Icons.check_circle_outline,
    ),
    ServerStatus.connecting => ('Connecting', StatusColors.info, Icons.sync),
    ServerStatus.error => ('Error', StatusColors.bad, Icons.error_outline),
    ServerStatus.disabled => (
      'Disabled',
      StatusColors.muted,
      Icons.pause_circle_outline,
    ),
    ServerStatus.idle => ('Idle', StatusColors.muted, Icons.circle_outlined),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hub = ref.read(mcpHubProvider.notifier);
    final (label, color, icon) = _status;
    final config = runtime.config;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(config.name, style: theme.textTheme.titleMedium),
                      Text(
                        config.url,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusChip(label, color, icon: icon),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                if (runtime.info != null)
                  _Fact(
                    'Server',
                    '${runtime.info!.name} ${runtime.info!.version}',
                  ),
                if (runtime.info != null)
                  _Fact('Protocol', runtime.info!.protocolVersion),
                _Fact('Tools', '${runtime.tools.length}'),
                if (runtime.latencyMs != null)
                  _Fact('Connect', '${runtime.latencyMs} ms'),
                if (runtime.checkedAt != null)
                  _Fact('Checked', formatTime(runtime.checkedAt!)),
              ],
            ),
            if (runtime.error != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: StatusColors.bad.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  runtime.error!,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                Switch(
                  value: config.enabled,
                  onChanged: (v) => hub.setEnabled(config.id, v),
                ),
                const Text('Enabled'),
                Expanded(
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (runtime.tools.isNotEmpty)
                        TextButton.icon(
                          onPressed: () => context.go('/tools'),
                          icon: const Icon(Icons.build_outlined, size: 18),
                          label: const Text('Tools'),
                        ),
                      IconButton(
                        tooltip: 'Reconnect',
                        icon: const Icon(Icons.refresh),
                        onPressed:
                            config.enabled &&
                                runtime.status != ServerStatus.connecting
                            ? () => hub.connect(config.id)
                            : null,
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () =>
                            showServerDialog(context, ref, existing: config),
                      ),
                      IconButton(
                        tooltip: 'Remove',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => _confirmRemove(context, hub),
                      ),
                    ],
                  ),
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

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RichText(
      text: TextSpan(
        style: theme.textTheme.bodySmall,
        children: [
          TextSpan(
            text: '$label  ',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          TextSpan(text: value),
        ],
      ),
    );
  }
}

Future<void> showServerDialog(
  BuildContext context,
  WidgetRef ref, {
  McpServerConfig? existing,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _ServerDialog(existing: existing),
  );
}

class _ServerDialog extends ConsumerStatefulWidget {
  const _ServerDialog({this.existing});
  final McpServerConfig? existing;

  @override
  ConsumerState<_ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends ConsumerState<_ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _headers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    final headers = {...?c?.headers};
    final auth = headers.entries
        .where((e) => e.key.toLowerCase() == 'authorization')
        .firstOrNull;
    String token = '';
    if (auth != null && auth.value.toLowerCase().startsWith('bearer ')) {
      token = auth.value.substring(7);
      headers.remove(auth.key);
    }
    _name = TextEditingController(text: c?.name ?? '');
    _url = TextEditingController(text: c?.url ?? '');
    _token = TextEditingController(text: token);
    _headers = TextEditingController(text: formatHeaderLines(headers));
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _headers.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final headers = parseHeaderLines(_headers.text)!;
    final token = _token.text.trim();
    if (token.isNotEmpty) headers['Authorization'] = 'Bearer $token';

    setState(() => _saving = true);
    final hub = ref.read(mcpHubProvider.notifier);
    final name = _name.text.trim();
    final url = normalizeBaseUrl(_url.text);
    final existing = widget.existing;
    // Do not await the connection: the card shows its live status.
    if (existing == null) {
      hub.addServer(name: name, url: url, headers: headers);
    } else {
      hub.updateServer(
        existing.copyWith(name: name, url: url, headers: headers),
      );
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Add MCP server' : 'Edit server'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'Endpoint URL',
                    hintText: 'https://example.com/mcp',
                  ),
                  validator: (v) => isValidHttpUrl(normalizeBaseUrl(v ?? ''))
                      ? null
                      : 'Enter a valid http(s) URL',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _token,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Bearer token (optional)',
                    helperText: 'Stored in this browser only.',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _headers,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Extra headers (optional)',
                    hintText: 'X-Api-Key: value',
                    alignLabelWithHint: true,
                  ),
                  validator: (v) {
                    String? bad;
                    parseHeaderLines(v ?? '', onError: (line) => bad = line);
                    return bad == null
                        ? null
                        : 'Use "Name: value" — got "$bad"';
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(widget.existing == null ? 'Add & connect' : 'Save'),
        ),
      ],
    );
  }
}
