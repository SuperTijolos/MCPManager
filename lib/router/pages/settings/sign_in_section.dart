import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/server/access.dart';
import '../../../engine/server/access_control.dart';
import '../../../engine/server/auth_providers.dart';
import '../../../engine/server/server_client.dart';
import '../../../engine/server/session.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'access_widgets.dart';

/// The ways people can sign in to this server (GitHub, Google), and who each
/// lets in. Client secrets go to the server and are never shown again.
class SignInSection extends ConsumerWidget {
  const SignInSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final providers = ref.watch(authProvidersProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      children: [
        Text('Sign-in', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Who may use this dashboard, and how they prove who they are. '
          'Register this server as an OAuth app with GitHub or Google, paste '
          'the client id and secret here, and say who is let in: people by '
          'GitHub login or organisation, or by email address or domain. '
          'The admin token keeps working whatever is set here.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey('add-github'),
              onPressed: () => showAuthProviderDialog(context, kind: 'github'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add GitHub'),
            ),
            OutlinedButton.icon(
              key: const ValueKey('add-google'),
              onPressed: () => showAuthProviderDialog(context, kind: 'google'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add Google'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        providers.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) =>
              Text('$e', style: const TextStyle(color: StatusColors.bad)),
          data: (list) => list.isEmpty
              ? const EmptyState(
                  icon: Icons.lock_open,
                  title: 'No sign-in set up',
                  message:
                      'Only the admin token can get in. Add GitHub or Google '
                      'so people can sign in as themselves.',
                )
              : Column(
                  children: [
                    for (final p in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ProviderCard(provider: p),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ProviderCard extends ConsumerWidget {
  const _ProviderCard({required this.provider});
  final AuthProviderInfo provider;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final p = provider;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final roleName = ref.watch(accessControlProvider).roleName(p.defaultRole);
    final lines = <String>[
      if (p.orgs.isNotEmpty) 'Organisations: ${p.orgs.join(', ')}',
      if (p.users.isNotEmpty) 'GitHub logins: ${p.users.join(', ')}',
      if (p.domains.isNotEmpty)
        'Email domains: ${p.domains.map((d) => '@$d').join(', ')}',
      if (p.emails.isNotEmpty) 'Emails: ${p.emails.join(', ')}',
    ];
    final problem = !p.configured
        ? 'Needs a client id and secret before it can be turned on.'
        : p.enabled && !p.hasAllowList
        ? 'Nobody is on the list, so nobody can sign in through it yet.'
        : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  p.kind == 'google' ? Icons.g_mobiledata : Icons.hub_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(p.name, style: theme.textTheme.titleSmall),
                ),
                if (p.fromEnvironment)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Tag('Set by the server'),
                  ),
                Switch(
                  key: ValueKey('enabled-${p.id}'),
                  value: p.enabled,
                  onChanged: p.fromEnvironment || !p.configured
                      ? null
                      : (v) => serverAction(
                          context,
                          () => ref
                              .read(authProvidersProvider.notifier)
                              .update(p.id, enabled: v),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              lines.isEmpty
                  ? 'Nobody is let in.'
                  : '${lines.join('\n')}\nThey start as: $roleName',
              style: muted,
            ),
            if (problem != null) ...[
              const SizedBox(height: 6),
              Text(
                problem,
                key: ValueKey('problem-${p.id}'),
                style: const TextStyle(color: StatusColors.warn),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (!p.fromEnvironment) ...[
                  OutlinedButton(
                    key: ValueKey('edit-${p.id}'),
                    onPressed: () => showAuthProviderDialog(
                      context,
                      kind: p.kind,
                      existing: p,
                    ),
                    child: const Text('Edit'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    key: ValueKey('remove-${p.id}'),
                    onPressed: () => _confirmRemove(context, ref),
                    child: const Text('Remove'),
                  ),
                ] else
                  Expanded(
                    child: Text(
                      'Change it in the server\'s environment '
                      '(GITHUB_CLIENT_ID and friends).',
                      style: muted,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${provider.name}?'),
        content: const Text(
          'People who signed in through it are signed out. The admin token '
          'still works.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-provider'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await serverAction(
        context,
        () => ref.read(authProvidersProvider.notifier).remove(provider.id),
      );
    }
  }
}

/// Add a sign-in provider of [kind], or edit [existing].
Future<void> showAuthProviderDialog(
  BuildContext context, {
  required String kind,
  AuthProviderInfo? existing,
}) => showDialog<void>(
  context: context,
  builder: (_) => AuthProviderDialog(kind: kind, existing: existing),
);

class AuthProviderDialog extends ConsumerStatefulWidget {
  const AuthProviderDialog({super.key, required this.kind, this.existing});
  final String kind;
  final AuthProviderInfo? existing;

  @override
  ConsumerState<AuthProviderDialog> createState() => _AuthProviderDialogState();
}

class _AuthProviderDialogState extends ConsumerState<AuthProviderDialog> {
  late final _name = TextEditingController(
    text:
        widget.existing?.name ??
        (widget.kind == 'google' ? 'Google' : 'GitHub'),
  );
  late final _clientId = TextEditingController(
    text: widget.existing?.clientId ?? '',
  );
  final _secret = TextEditingController();
  late final _orgs = TextEditingController(text: _join(widget.existing?.orgs));
  late final _users = TextEditingController(
    text: _join(widget.existing?.users),
  );
  late final _domains = TextEditingController(
    text: _join(widget.existing?.domains),
  );
  late final _emails = TextEditingController(
    text: _join(widget.existing?.emails),
  );
  String? _error;
  bool _saving = false;
  late String _defaultRole = widget.existing?.defaultRole ?? 'viewer';

  static String _join(List<String>? l) => (l ?? const []).join(', ');

  static List<String> _split(String text) => [
    for (final part in text.split(RegExp(r'[,\n;\s]+')))
      if (part.trim().isNotEmpty) part.trim(),
  ];

  @override
  void dispose() {
    for (final c in [
      _name,
      _clientId,
      _secret,
      _orgs,
      _users,
      _domains,
      _emails,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final store = ref.read(authProvidersProvider.notifier);
    final github = widget.kind == 'github';
    try {
      final existing = widget.existing;
      if (existing == null) {
        await store.create(
          kind: widget.kind,
          id: _id,
          name: _name.text.trim(),
          clientId: _clientId.text.trim(),
          secret: _secret.text.trim(),
          orgs: github ? _split(_orgs.text) : const [],
          users: github ? _split(_users.text) : const [],
          domains: _split(_domains.text),
          emails: _split(_emails.text),
          defaultRole: _defaultRole,
        );
      } else {
        await store.update(
          existing.id,
          name: _name.text.trim(),
          clientId: _clientId.text.trim(),
          // Empty means "keep the stored secret".
          secret: _secret.text.trim().isEmpty ? null : _secret.text.trim(),
          orgs: github ? _split(_orgs.text) : null,
          users: github ? _split(_users.text) : null,
          domains: _split(_domains.text),
          emails: _split(_emails.text),
          defaultRole: _defaultRole,
        );
      }
      if (mounted) Navigator.pop(context);
    } on ServerException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  /// The roles that can be the default: ones this person has all the
  /// permissions of (and the current choice, so it stays visible).
  List<RoleInfo> _roleChoices(WidgetRef ref) {
    final access = ref.watch(accessProvider);
    final roles = ref.watch(accessControlProvider).roles;
    final list = [
      for (final r in roles)
        if (r.id == _defaultRole || r.permissions.every(access.can)) r,
    ];
    if (list.every((r) => r.id != _defaultRole)) {
      list.add(
        RoleInfo(
          id: _defaultRole,
          name: _defaultRole,
          description: '',
          permissions: const {},
          builtin: false,
          members: 0,
          invites: 0,
        ),
      );
    }
    return list;
  }

  /// What the server would call this provider: its id is the address segment.
  String get _id =>
      widget.existing?.id ??
      (() {
        final slug = _name.text
            .toLowerCase()
            .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
            .replaceAll(RegExp(r'^-+|-+$'), '');
        return slug.isEmpty ? widget.kind : slug;
      })();

  Widget _heading(ThemeData theme, String title, [String? hint]) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final existing = widget.existing;
    final github = widget.kind == 'github';
    final provider = github ? 'GitHub' : 'Google';
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final server = ref.watch(sessionProvider.select((s) => s.serverUrl)) ?? '';
    final callback = existing?.callbackUrl.isNotEmpty == true
        ? existing!.callbackUrl
        : '$server/auth/$_id/callback';

    return AlertDialog(
      title: Text(
        existing == null ? 'Add $provider sign-in' : 'Edit ${existing.name}',
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                github
                    ? 'In GitHub, open Settings → Developer settings → OAuth '
                          'Apps and create an app with this callback URL, then '
                          'paste its client id and secret below.'
                    : 'In the Google Cloud console, create an OAuth client '
                          '(web application) with this authorised redirect '
                          'URI, then paste its client id and secret below.',
                style: muted,
              ),
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('provider-callback'),
                padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Callback URL', style: muted),
                          SelectableText(
                            callback,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy callback URL',
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: callback)),
                    ),
                  ],
                ),
              ),
              _heading(theme, 'Credentials'),
              TextField(
                key: const ValueKey('provider-name'),
                controller: _name,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Name',
                  helperText: 'Shown on the sign-in button.',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('provider-client-id'),
                controller: _clientId,
                decoration: const InputDecoration(labelText: 'Client id'),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('provider-client-secret'),
                controller: _secret,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Client secret',
                  helperText: existing?.hasSecret == true
                      ? 'Stored on the server. Leave empty to keep it.'
                      : 'Stored on the server and never shown again.',
                ),
              ),
              _heading(
                theme,
                'Who is let in',
                'Anyone who matches one entry. Separate entries with commas. '
                    'Emails count only when $provider has verified them.',
              ),
              if (github) ...[
                TextField(
                  key: const ValueKey('provider-orgs'),
                  controller: _orgs,
                  decoration: const InputDecoration(
                    labelText: 'GitHub organisations',
                    hintText: 'acme, other-org',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('provider-users'),
                  controller: _users,
                  decoration: const InputDecoration(
                    labelText: 'GitHub logins',
                    hintText: 'octocat',
                  ),
                ),
                const SizedBox(height: 16),
              ],
              TextField(
                key: const ValueKey('provider-domains'),
                controller: _domains,
                decoration: const InputDecoration(
                  labelText: 'Email domains',
                  hintText: 'example.com',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('provider-emails'),
                controller: _emails,
                decoration: const InputDecoration(
                  labelText: 'Email addresses',
                  hintText: 'ann@example.com',
                ),
              ),
              _heading(theme, 'Role'),
              DropdownButtonFormField<String>(
                key: const ValueKey('provider-default-role'),
                initialValue: _defaultRole,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'New members start as',
                  helperText: 'Change it for one person under Members.',
                ),
                items: [
                  for (final r in _roleChoices(ref))
                    DropdownMenuItem(value: r.id, child: Text(r.name)),
                ],
                onChanged: (v) => setState(() => _defaultRole = v ?? 'viewer'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  key: const ValueKey('provider-error'),
                  style: const TextStyle(color: StatusColors.bad),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('provider-save'),
          onPressed: _saving ? null : _save,
          child: Text(existing == null ? 'Add' : 'Save'),
        ),
      ],
    );
  }
}
