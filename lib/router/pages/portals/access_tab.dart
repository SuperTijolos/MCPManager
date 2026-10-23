import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_controller.dart';
import '../../../engine/portal/portal_models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'portals_tab.dart' show guarded;

/// Access tokens for MCP clients that send a bearer header.
class AccessTab extends ConsumerWidget {
  const AccessTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(portalControllerProvider);
    final now = DateTime.now();
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Tokens are for clients that send a bearer header, such as '
                'Claude Code. Web connectors sign in with OAuth instead and '
                'need no token. A token\'s secret is shown once, when you '
                'create it.',
                style: muted,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              key: const ValueKey('new-token'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => const _NewTokenDialog(),
              ),
              icon: const Icon(Icons.add),
              label: const Text('New token'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (data.tokens.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('No tokens yet.')),
          )
        else
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (final (i, t) in data.tokens.indexed) ...[
                  if (i > 0) const Divider(height: 1),
                  _TokenRow(token: t, now: now),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _TokenRow extends ConsumerWidget {
  const _TokenRow({required this.token, required this.now});
  final GatewayToken token;
  final DateTime now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(portalControllerProvider);
    final active = token.active(now);
    final scope = token.portalIds.isEmpty
        ? 'All portals'
        : token.portalIds.map((id) => data.portal(id)?.name ?? id).join(', ');
    final status = token.revokedAt != null
        ? ('Revoked', StatusColors.muted)
        : active
        ? ('Active', StatusColors.ok)
        : ('Expired', StatusColors.warn);
    return ListTile(
      key: ValueKey('token-${token.id}'),
      leading: const Icon(Icons.key_outlined),
      title: Text(token.name),
      subtitle: Text(
        '${token.prefix}…  ·  $scope  ·  '
        '${token.lastUsedAt == null ? 'never used' : 'used ${formatAgo(token.lastUsedAt!)}'}'
        '${token.expiresAt == null ? '' : '  ·  expires ${formatDateTime(token.expiresAt!)}'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusChip(status.$1, status.$2),
          if (active)
            TextButton(
              key: ValueKey('revoke-${token.id}'),
              onPressed: () => _revoke(context, ref),
              child: const Text('Revoke'),
            ),
        ],
      ),
    );
  }

  Future<void> _revoke(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Revoke ${token.name}?'),
        content: const Text(
          'Clients using it stop working right away. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-revoke'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await guarded(
        context,
        () => ref.read(portalControllerProvider.notifier).revokeToken(token.id),
      );
    }
  }
}

class _NewTokenDialog extends ConsumerStatefulWidget {
  const _NewTokenDialog();

  @override
  ConsumerState<_NewTokenDialog> createState() => _NewTokenDialogState();
}

class _NewTokenDialogState extends ConsumerState<_NewTokenDialog> {
  final _name = TextEditingController();
  final _portals = <String>{};
  int? _days;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(
        () => _error =
            'Give the token a name, such as the client that will use it.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final created = await guarded(
      context,
      () => ref
          .read(portalControllerProvider.notifier)
          .createToken(
            name: name,
            portalIds: _portals.toList(),
            expiresInDays: _days,
          ),
    );
    if (!mounted) return;
    if (created == null) {
      setState(() => _busy = false);
      return;
    }
    Navigator.pop(context);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SecretDialog(created),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(portalControllerProvider);
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('New access token'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('token-name'),
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Claude Code on my laptop',
                ),
              ),
              const SizedBox(height: 16),
              Text('Opens', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  ChoiceChip(
                    key: const ValueKey('token-all-portals'),
                    label: const Text('Every portal'),
                    selected: _portals.isEmpty,
                    onSelected: (_) => setState(_portals.clear),
                  ),
                  for (final p in data.portals)
                    FilterChip(
                      key: ValueKey('token-portal-${p.slug}'),
                      label: Text(p.name),
                      selected: _portals.contains(p.id),
                      onSelected: (on) => setState(
                        () => on ? _portals.add(p.id) : _portals.remove(p.id),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int?>(
                key: const ValueKey('token-expiry'),
                initialValue: _days,
                decoration: const InputDecoration(labelText: 'Expires'),
                items: const [
                  DropdownMenuItem(value: null, child: Text('Never')),
                  DropdownMenuItem(value: 30, child: Text('In 30 days')),
                  DropdownMenuItem(value: 90, child: Text('In 90 days')),
                  DropdownMenuItem(value: 365, child: Text('In a year')),
                ],
                onChanged: (v) => setState(() => _days = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
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
          key: const ValueKey('token-create'),
          onPressed: _busy ? null : _create,
          child: const Text('Create token'),
        ),
      ],
    );
  }
}

/// The one chance to copy a new token.
class _SecretDialog extends StatelessWidget {
  const _SecretDialog(this.created);
  final CreatedToken created;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Token for ${created.token.name}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Copy it now. The gateway keeps only a fingerprint, so this is '
              'the only time the token can be shown.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              decoration: BoxDecoration(
                color: kCodePanelBackground,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      created.secret,
                      key: const ValueKey('token-secret'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy token',
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: created.secret));
                      showSnack(context, 'Token copied');
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const ValueKey('token-done'),
          onPressed: () => Navigator.pop(context),
          child: const Text('I have copied it'),
        ),
      ],
    );
  }
}
