import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/core/url.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../engine/mcp/mcp_models.dart';
import '../../../engine/mcp/oauth/oauth_service.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Add a server (no [existing]) or edit one.
Future<void> showServerDialog(
  BuildContext context, {
  McpServerConfig? existing,
}) {
  final narrow = MediaQuery.sizeOf(context).width < 700;
  final body = ServerDialog(existing: existing);
  return showDialog<void>(
    context: context,
    builder: (_) => narrow
        ? Dialog.fullscreen(child: body)
        : Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680, maxHeight: 860),
              child: body,
            ),
          ),
  );
}

enum _Auth { none, bearer, oauth }

class _HeaderRow {
  _HeaderRow([String name = '', String value = ''])
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}

/// A header name per RFC 9110 (a "token").
final _headerName = RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$");

class ServerDialog extends ConsumerStatefulWidget {
  const ServerDialog({super.key, this.existing});
  final McpServerConfig? existing;

  @override
  ConsumerState<ServerDialog> createState() => _ServerDialogState();
}

class _ServerDialogState extends ConsumerState<ServerDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _token;
  late final TextEditingController _clientId;
  late final TextEditingController _scope;
  late final List<_HeaderRow> _headers;
  late _Auth _auth;
  late McpTransport _transport;
  bool _showToken = false;
  bool _testing = false;
  ProbeResult? _probe;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final c = widget.existing;
    final extra = {...?c?.headers};
    String token = '';
    final authEntry = extra.entries
        .where((e) => e.key.toLowerCase() == 'authorization')
        .firstOrNull;
    if (authEntry != null &&
        authEntry.value.toLowerCase().startsWith('bearer ')) {
      token = authEntry.value.substring(7);
      extra.remove(authEntry.key);
    }
    _auth = c == null
        ? _Auth.none
        : c.oauth
        ? _Auth.oauth
        : token.isNotEmpty
        ? _Auth.bearer
        : _Auth.none;
    _transport = c?.transport ?? McpTransport.auto;
    _name = TextEditingController(text: c?.name ?? '');
    _url = TextEditingController(text: c?.url ?? '');
    _token = TextEditingController(text: token);
    _clientId = TextEditingController(text: c?.oauthClientId ?? '');
    _scope = TextEditingController(text: c?.oauthScope ?? '');
    _headers = [for (final e in extra.entries) _HeaderRow(e.key, e.value)];
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _token.dispose();
    _clientId.dispose();
    _scope.dispose();
    for (final h in _headers) {
      h.dispose();
    }
    super.dispose();
  }

  String get _normalizedUrl => normalizeBaseUrl(_url.text);

  Map<String, String> _headerMap() => {
    for (final h in _headers)
      if (h.name.text.trim().isNotEmpty)
        h.name.text.trim(): h.value.text.trim(),
  };

  /// The configuration described by the form right now.
  McpServerConfig _draft() {
    final headers = _headerMap();
    if (_auth == _Auth.bearer && _token.text.trim().isNotEmpty) {
      headers['Authorization'] = 'Bearer ${_token.text.trim()}';
    }
    final oauth = _auth == _Auth.oauth;
    final clientId = _clientId.text.trim();
    final scope = _scope.text.trim();
    final base =
        widget.existing ?? McpServerConfig(id: 'draft', name: '', url: '');
    return base.copyWith(
      name: _name.text.trim(),
      url: _normalizedUrl,
      headers: headers,
      transport: _transport,
      oauth: oauth,
      clearOAuthOptions: true,
      oauthClientId: oauth && clientId.isNotEmpty ? clientId : null,
      oauthScope: oauth && scope.isNotEmpty ? scope : null,
    );
  }

  Future<void> _test() async {
    final url = _normalizedUrl;
    if (!isValidHttpUrl(url)) {
      setState(
        () => _probe = const ProbeResult(
          error: 'Enter a valid http(s) URL first.',
        ),
      );
      return;
    }
    setState(() {
      _testing = true;
      _probe = null;
    });
    final result = await ref
        .read(mcpHubProvider.notifier)
        .probe(_draft(), signedInAs: widget.existing?.id);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _probe = result;
    });
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final hub = ref.read(mcpHubProvider.notifier);
    final draft = _draft();
    final existing = widget.existing;
    // Do not await the connection: the card shows its live status.
    if (existing == null) {
      hub.addServer(
        name: draft.name,
        url: draft.url,
        headers: draft.headers,
        oauth: draft.oauth,
        oauthClientId: draft.oauthClientId,
        oauthScope: draft.oauthScope,
        transport: draft.transport,
      );
    } else {
      hub.updateServer(draft);
    }
    Navigator.pop(context);
  }

  Future<void> _remove() async {
    final existing = widget.existing!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${existing.name}?'),
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
    if (ok == true && mounted) {
      ref.read(mcpHubProvider.notifier).removeServer(existing.id);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final typed = _url.text.trim();
    final normalized = _normalizedUrl;
    final runtime = widget.existing == null
        ? null
        : ref.watch(mcpHubProvider).byId(widget.existing!.id);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.transparent,
        title: Text(_editing ? 'Edit server' : 'Add MCP server'),
        actions: [
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Form(
        key: _form,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (runtime != null) _Status(runtime: runtime),
              _section(theme, 'Connection', Icons.link),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Endpoint URL',
                  hintText: 'https://example.com/mcp',
                ),
                onChanged: (_) => setState(() => _probe = null),
                validator: (v) => isValidHttpUrl(normalizeBaseUrl(v ?? ''))
                    ? null
                    : 'Enter a valid http(s) URL',
              ),
              if (typed.isNotEmpty &&
                  normalized != typed &&
                  isValidHttpUrl(normalized))
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 4),
                  child: Text('Will connect to $normalized', style: muted),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<McpTransport>(
                initialValue: _transport,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Transport',
                  helperText: 'Auto tries Streamable HTTP (…/mcp), then legacy SSE (…/sse).',
                  helperMaxLines: 2,
                ),
                items: [
                  for (final t in McpTransport.values)
                    DropdownMenuItem(
                      value: t,
                      child: Text(t.label, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _transport = v ?? _transport;
                  _probe = null;
                }),
              ),
              _section(theme, 'Authentication', Icons.vpn_key_outlined),
              SegmentedButton<_Auth>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _Auth.none, label: Text('None')),
                  ButtonSegment(
                    value: _Auth.bearer,
                    label: Text('Bearer token'),
                  ),
                  ButtonSegment(value: _Auth.oauth, label: Text('OAuth')),
                ],
                selected: {_auth},
                onSelectionChanged: (s) => setState(() {
                  _auth = s.first;
                  _probe = null;
                }),
              ),
              if (_auth == _Auth.bearer) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Bearer token',
                    helperText: 'Stored in this browser only.',
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: _showToken ? 'Hide token' : 'Show token',
                          icon: Icon(
                            _showToken
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 20,
                          ),
                          onPressed: () =>
                              setState(() => _showToken = !_showToken),
                        ),
                        IconButton(
                          tooltip: 'Paste',
                          icon: const Icon(Icons.content_paste, size: 20),
                          onPressed: () async {
                            final data = await Clipboard.getData(
                              Clipboard.kTextPlain,
                            );
                            final text = data?.text?.trim();
                            if (text != null && text.isNotEmpty) {
                              setState(() => _token.text = text);
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  validator: (v) =>
                      _auth == _Auth.bearer && (v ?? '').trim().isEmpty
                      ? 'Enter a token, or choose None'
                      : null,
                ),
              ],
              if (_auth == _Auth.oauth) ...[
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
                        helperMaxLines: 2,
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
              _section(theme, 'Extra headers', Icons.data_object),
              for (var i = 0; i < _headers.length; i++)
                Padding(
                  key: ObjectKey(_headers[i]),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _headers[i].name,
                          decoration: const InputDecoration(
                            hintText: 'Header name',
                          ),
                          validator: (v) {
                            final name = (v ?? '').trim();
                            if (name.isEmpty &&
                                _headers[i].value.text.trim().isEmpty) {
                              return null;
                            }
                            if (!_headerName.hasMatch(name)) {
                              return 'Invalid name';
                            }
                            final dupes = _headers
                                .where(
                                  (h) =>
                                      h.name.text.trim().toLowerCase() ==
                                      name.toLowerCase(),
                                )
                                .length;
                            return dupes > 1 ? 'Duplicate' : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 3,
                        child: TextFormField(
                          controller: _headers[i].value,
                          decoration: const InputDecoration(hintText: 'Value'),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Remove header',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () =>
                            setState(() => _headers.removeAt(i).dispose()),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _headers.add(_HeaderRow())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add header'),
                ),
              ),
              _section(theme, 'Try it', Icons.network_check),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _testing ? null : _test,
                    icon: _testing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Test connection'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Connects with these settings and lists the tools, without saving.',
                      style: muted,
                    ),
                  ),
                ],
              ),
              if (_probe != null)
                _ProbeCard(result: _probe!, requestedUrl: normalized),
              if (_editing) ...[
                _section(theme, 'Danger zone', Icons.warning_amber_rounded),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _remove,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove this server'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: StatusColors.bad,
                      side: BorderSide(
                        color: StatusColors.bad.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _save,
              child: Text(_editing ? 'Save' : 'Add & connect'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(ThemeData theme, String title, IconData icon) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 10),
    child: Row(
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text(title, style: theme.textTheme.titleSmall),
        const SizedBox(width: 12),
        Expanded(child: Divider(color: theme.dividerColor)),
      ],
    ),
  );
}

/// Where this server stands right now (edit mode).
class _Status extends StatelessWidget {
  const _Status({required this.runtime});
  final ServerRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (runtime.status) {
      ServerStatus.connected => ('Connected', StatusColors.ok),
      ServerStatus.connecting => ('Connecting', StatusColors.info),
      ServerStatus.needsAuth => ('Sign-in required', StatusColors.warn),
      ServerStatus.error => ('Error', StatusColors.bad),
      ServerStatus.disabled => ('Disabled', StatusColors.muted),
      ServerStatus.idle => ('Idle', StatusColors.muted),
    };
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusChip(label, color),
          Text(
            '${runtime.tools.length} tools'
            '${runtime.checkedAt == null ? '' : ' · checked ${formatTime(runtime.checkedAt!)}'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _ProbeCard extends StatelessWidget {
  const _ProbeCard({required this.result, required this.requestedUrl});
  final ProbeResult result;
  final String requestedUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (color, icon, title) = result.connected
        ? (StatusColors.ok, Icons.check_circle_outline, 'Connected')
        : result.needsAuth
        ? (
            StatusColors.warn,
            Icons.lock_outline,
            'Reachable — sign-in required',
          )
        : (StatusColors.bad, Icons.error_outline, 'Could not connect');
    final info = result.info;
    final differs = result.endpoint != null && result.endpoint != requestedUrl;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            ],
          ),
          const SizedBox(height: 6),
          if (result.connected) ...[
            Text(
              '${info?.name ?? 'Server'} ${info?.version ?? ''} · '
              '${result.toolCount} tool${result.toolCount == 1 ? '' : 's'} · '
              '${result.transport?.label ?? ''} · ${result.latencyMs} ms',
            ),
            if (differs)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Found at ${result.endpoint}. That endpoint is what gets saved.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ] else
            SelectableText(
              result.error ?? 'Unknown error',
              style: const TextStyle(fontSize: 12.5),
            ),
          if (result.needsAuth)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Choose Bearer token or OAuth above; with OAuth, sign in from the server card after saving.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (result.trace.isNotEmpty)
            // Its own Material, so the tile's ink is not hidden by the tinted
            // container around it.
            Material(
              type: MaterialType.transparency,
              child: Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Details'),
                  children: [
                    CodeBlock(result.trace.join('\n'), maxHeight: 160),
                  ],
                ),
              ),
            ),
        ],
      ),
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
