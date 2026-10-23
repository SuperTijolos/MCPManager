import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_controller.dart';
import '../../../ui/widgets.dart';

/// Asks for the gateway's address and admin token.
class GatewayConnectCard extends ConsumerStatefulWidget {
  const GatewayConnectCard({super.key, this.initialUrl = '', this.error});

  final String initialUrl;

  /// Why the last attempt (or the saved connection) failed.
  final String? error;

  @override
  ConsumerState<GatewayConnectCard> createState() => _GatewayConnectCardState();
}

class _GatewayConnectCardState extends ConsumerState<GatewayConnectCard> {
  late final _url = TextEditingController(
    text: widget.initialUrl.isEmpty
        ? 'http://localhost:8787'
        : widget.initialUrl,
  );
  final _token = TextEditingController();
  bool _show = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await ref
        .read(portalControllerProvider.notifier)
        .connect(_url.text, _token.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = problem;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final error = _error ?? widget.error;
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.hub_outlined,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Connect to a gateway',
                        style: theme.textTheme.titleLarge,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'A portal publishes a chosen set of your MCP servers as one '
                    'authenticated MCP endpoint that Claude, ChatGPT or any MCP '
                    'client can use. Portals run on the MCP Manager gateway, a '
                    'small server you host yourself.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    key: const ValueKey('gateway-url'),
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Gateway address',
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('gateway-token'),
                    controller: _token,
                    obscureText: !_show,
                    onSubmitted: (_) => _busy ? null : _connect(),
                    decoration: InputDecoration(
                      labelText: 'Admin token',
                      prefixIcon: const Icon(Icons.key_outlined),
                      helperText: 'Stored in this browser only.',
                      suffixIcon: IconButton(
                        tooltip: _show ? 'Hide token' : 'Show token',
                        icon: Icon(
                          _show ? Icons.visibility_off : Icons.visibility,
                        ),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            error,
                            key: const ValueKey('gateway-error'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('gateway-connect'),
                    onPressed: _busy ? null : _connect,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.power_outlined, size: 18),
                    label: const Text('Connect'),
                  ),
                  const Divider(height: 36),
                  Text(
                    'Don\'t have a gateway yet?',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'It lives in the server folder of this project. Start it, '
                    'and copy the admin token it prints the first time:',
                    style: muted,
                  ),
                  const SizedBox(height: 8),
                  const CodeBlock(
                    'cd server\ndart pub get\ndart run bin/mcp_portal.dart',
                    maxHeight: 120,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'To put it on the internet, run it behind HTTPS (a reverse '
                    'proxy or a tunnel) and set PORTAL_PUBLIC_URL to that address. '
                    'The README in the server folder has the details.',
                    style: muted,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
