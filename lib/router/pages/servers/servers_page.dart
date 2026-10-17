import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/core/url.dart';
import '../../../engine/mcp/headers.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../engine/mcp/oauth/oauth_service.dart';
import '../../../ui/sign_in.dart';
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
      subtitle: 'Downstream MCP servers (Streamable HTTP or legacy SSE)',
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
              message: 'Add an MCP server (Streamable HTTP or legacy SSE, detected automatically). From a browser it must allow CORS for this origin.',
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
                Wrap(
                  spacing: 6,
                  children: [
                    if (config.transport == McpTransport.sse)
                      const StatusChip('SSE', StatusColors.muted),
                    if (config.oauth)
                      const StatusChip(
                        'OAuth',
                        StatusColors.info,
                        icon: Icons.vpn_key_outlined,
                      ),
                    StatusChip(label, color, icon: icon),
                  ],
                ),
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
                  color:
                      (runtime.status == ServerStatus.needsAuth
                              ? StatusColors.warn
                              : StatusColors.bad)
                          .withValues(alpha: 0.1),
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
                      if (runtime.status == ServerStatus.needsAuth)
                        FilledButton.tonalIcon(
                          onPressed: () =>
                              signInToServer(context, ref, config.id),
                          icon: const Icon(Icons.login, size: 18),
                          label: const Text('Sign in'),
                        ),
                      if (config.oauth &&
                          runtime.status == ServerStatus.connected)
                        TextButton.icon(
                          onPressed: () => hub.signOut(config.id),
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Sign out'),
                        ),
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

enum _AuthMode { none, bearer, oauth }

class _ServerDialogState extends ConsumerState<_ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _headers;
  late final TextEditingController _clientId;
  late final TextEditingController _scope;
  late _AuthMode _mode;
  late McpTransport _transport;
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
    _mode = c == null
        ? _AuthMode.none
        : c.oauth
        ? _AuthMode.oauth
        : token.isNotEmpty
        ? _AuthMode.bearer
        : _AuthMode.none;
    _transport = c?.transport ?? McpTransport.auto;
    _name = TextEditingController(text: c?.name ?? '');
    _url = TextEditingController(text: c?.url ?? '');
    _token = TextEditingController(text: token);
    _headers = TextEditingController(text: formatHeaderLines(headers));
    _clientId = TextEditingController(text: c?.oauthClientId ?? '');
    _scope = TextEditingController(text: c?.oauthScope ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _headers.dispose();
    _clientId.dispose();
    _scope.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final headers = parseHeaderLines(_headers.text)!;
    final token = _token.text.trim();
    if (_mode == _AuthMode.bearer && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    final oauth = _mode == _AuthMode.oauth;
    final clientId = _clientId.text.trim();
    final scope = _scope.text.trim();

    setState(() => _saving = true);
    final hub = ref.read(mcpHubProvider.notifier);
    final name = _name.text.trim();
    final url = normalizeBaseUrl(_url.text);
    final existing = widget.existing;
    // Do not await the connection: the card shows its live status.
    if (existing == null) {
      hub.addServer(
        name: name,
        url: url,
        headers: headers,
        oauth: oauth,
        oauthClientId: oauth && clientId.isNotEmpty ? clientId : null,
        oauthScope: oauth && scope.isNotEmpty ? scope : null,
        transport: _transport,
      );
    } else {
      hub.updateServer(
        existing.copyWith(
          name: name,
          url: url,
          headers: headers,
          oauth: oauth,
          clearOAuthOptions: true,
          oauthClientId: oauth && clientId.isNotEmpty ? clientId : null,
          oauthScope: oauth && scope.isNotEmpty ? scope : null,
          transport: _transport,
        ),
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
                DropdownButtonFormField<McpTransport>(
                  initialValue: _transport,
                  decoration: const InputDecoration(
                    labelText: 'Transport',
                    helperText:
                        'Auto tries Streamable HTTP, then legacy SSE (…/sse).',
                    helperMaxLines: 2,
                  ),
                  items: [
                    for (final t in McpTransport.values)
                      DropdownMenuItem(value: t, child: Text(t.label)),
                  ],
                  onChanged: (v) =>
                      setState(() => _transport = v ?? _transport),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Authentication',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 6),
                SegmentedButton<_AuthMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: _AuthMode.none, label: Text('None')),
                    ButtonSegment(
                      value: _AuthMode.bearer,
                      label: Text('Bearer token'),
                    ),
                    ButtonSegment(value: _AuthMode.oauth, label: Text('OAuth')),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                if (_mode == _AuthMode.bearer) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _token,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Bearer token',
                      helperText: 'Stored in this browser only.',
                    ),
                    validator: (v) =>
                        _mode == _AuthMode.bearer && (v ?? '').trim().isEmpty
                        ? 'Enter a token, or choose None'
                        : null,
                  ),
                ],
                if (_mode == _AuthMode.oauth) ...[
                  const SizedBox(height: 12),
                  OAuthInfo(redirectUri: ref.watch(oauthRedirectUriProvider)),
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Advanced'),
                    children: [
                      TextFormField(
                        controller: _clientId,
                        decoration: const InputDecoration(
                          labelText: 'Client ID (optional)',
                          helperText: 'Only if the server has no dynamic client registration.',
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _scope,
                        decoration: const InputDecoration(
                          labelText: 'Scope (optional)',
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ],
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

/// Explains which redirect URI to allow on the server's OAuth provider. Some
/// servers only list one client's callback (for example ChatGPT connectors use
/// `https://chatgpt.com/connector/oauth/<id>`) and will refuse this app until
/// this app's own callback is added.
class OAuthInfo extends StatelessWidget {
  const OAuthInfo({super.key, required this.redirectUri});

  final Uri redirectUri;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    final local =
        redirectUri.host == 'localhost' ||
        redirectUri.host == '127.0.0.1' ||
        redirectUri.host == '[::1]';
    final insecure = redirectUri.scheme == 'http' && !local;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: StatusColors.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StatusColors.info.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Redirect URI for this app', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          CodeBlock(redirectUri.toString(), maxHeight: 70),
          const SizedBox(height: 8),
          Text(
            'Allow this exact URI in the server\'s OAuth / authorization '
            'provider. Servers set up only for ChatGPT '
            '(https://chatgpt.com/connector/oauth/*) or another client\'s '
            'callback will reject this app until it is added, or until you '
            'enter a pre-registered Client ID that already allows it.',
            style: muted,
          ),
          const SizedBox(height: 6),
          Text(
            'The authorization server must also allow CORS from '
            '${redirectUri.scheme}://${redirectUri.authority} on its metadata, '
            'registration and token endpoints.',
            style: muted,
          ),
          if (insecure) ...[
            const SizedBox(height: 6),
            Text(
              'This page is served over plain http from a non-local address. '
              'Many providers only accept https or localhost redirect URIs: '
              'open the app via localhost or serve it over https.',
              style: muted?.copyWith(color: StatusColors.warn),
            ),
          ],
        ],
      ),
    );
  }
}
