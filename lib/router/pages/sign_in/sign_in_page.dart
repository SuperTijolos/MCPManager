import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/core/prefs.dart';
import '../../../engine/server/server_client.dart';
import '../../../engine/server/session.dart';
import '../../../ui/theme.dart';

/// Where someone signs in to a server, or waits while a saved session is
/// checked.
IconData _iconFor(String? kind) => switch (kind) {
  'google' => Icons.g_mobiledata,
  _ => Icons.login,
};

class SignInPage extends ConsumerStatefulWidget {
  const SignInPage({super.key});

  @override
  ConsumerState<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends ConsumerState<SignInPage> {
  late final TextEditingController _url;
  final _token = TextEditingController();
  bool _showToken = false;
  bool _busy = false;
  String? _error;
  ServerSignIn? _options;

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    final env = ref.read(appEnvProvider);
    _url = TextEditingController(
      text:
          session.serverUrl ??
          env.portalUrl ??
          ref.read(sameOriginServerProvider) ??
          'http://localhost:8787',
    );
    // Find out what this server offers, so the buttons are the right ones.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && session.status != SessionStatus.checking) _inspect();
    });
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _begin([String? providerId]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref
        .read(sessionProvider.notifier)
        .beginSignIn(_url.text, providerId);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  Future<void> _adminToken() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await ref
        .read(sessionProvider.notifier)
        .signInWithAdminToken(_url.text, _token.text);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = error;
      });
    }
  }

  /// Looks at what the server offers, so the page can say what will work.
  Future<void> _inspect() async {
    final url = normalizeServerUrl(_url.text);
    if (url.isEmpty) return;
    try {
      final options = await ref.read(sessionProvider.notifier).inspect(url);
      if (mounted) setState(() => _options = options);
    } on ServerException {
      if (mounted) setState(() => _options = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    if (session.status == SessionStatus.checking) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('Connecting to ${session.serverUrl}…'),
            ],
          ),
        ),
      );
    }

    // What this page just found out, else why the session ended.
    final error = _error ?? session.error;
    final waitingForServer = session.token != null && session.error != null;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('MCP Manager', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Sign in to your server. Servers, tools, audit and chats '
                      'live there; this page is the dashboard.',
                      style: muted,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      key: const ValueKey('server-url'),
                      controller: _url,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'Server address',
                        hintText: 'https://mcp.example.com',
                      ),
                      onSubmitted: (_) => _inspect(),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        error,
                        key: const ValueKey('sign-in-error'),
                        style: const TextStyle(color: StatusColors.bad),
                      ),
                    ],
                    const SizedBox(height: 16),
                    if (waitingForServer)
                      FilledButton(
                        key: const ValueKey('sign-in-retry'),
                        onPressed: _busy
                            ? null
                            : () => ref.read(sessionProvider.notifier).retry(),
                        child: const Text('Try again'),
                      )
                    else if (_options != null && _options!.providers.length > 1)
                      for (final p in _options!.providers) ...[
                        FilledButton.icon(
                          key: ValueKey('sign-in-${p.id}'),
                          onPressed: _busy ? null : () => _begin(p.id),
                          icon: Icon(_iconFor(p.kind), size: 18),
                          label: Text('Sign in with ${p.name}'),
                        ),
                        const SizedBox(height: 8),
                      ]
                    else
                      FilledButton.icon(
                        key: ValueKey(
                          'sign-in-${_options?.providers.firstOrNull?.id ?? 'github'}',
                        ),
                        onPressed: _busy ? null : _begin,
                        icon: Icon(
                          _iconFor(_options?.providers.firstOrNull?.kind),
                          size: 18,
                        ),
                        label: Text(
                          'Sign in with '
                          '${_options?.providers.firstOrNull?.name ?? 'GitHub'}',
                        ),
                      ),
                    if (_options != null && !_options!.any)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'This server has no sign-in set up yet. Use the '
                          'admin token, then set one up under Settings.',
                          style: muted,
                        ),
                      ),
                    if (_options != null &&
                        _options!.providers.length == 1 &&
                        _options!.orgs.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Open to members of ${_options!.orgs.join(', ')}.',
                          style: muted,
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (!_showToken)
                      TextButton(
                        key: const ValueKey('sign-in-use-token'),
                        onPressed: () => setState(() => _showToken = true),
                        child: const Text('Use the admin token instead'),
                      )
                    else ...[
                      TextField(
                        key: const ValueKey('admin-token'),
                        controller: _token,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Admin token',
                          helperText: 'Printed in the server\'s log at its first start.',
                        ),
                        onSubmitted: (_) => _adminToken(),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const ValueKey('sign-in-token'),
                        onPressed: _busy ? null : _adminToken,
                        child: const Text('Sign in with the token'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
