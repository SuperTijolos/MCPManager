import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/audit/audit_log.dart';
import '../../../engine/server/server_client.dart';
import '../../../engine/server/session.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Who is signed in, where the data lives, and clean-up.
class DataSection extends ConsumerWidget {
  const DataSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final events = ref.watch(auditLogProvider);
    final chats = ref.watch(chatControllerProvider).conversations;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final who = session.identity;

    return ListView(
      children: [
        Text('This dashboard', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'The dashboard is a window onto a server. Servers, tokens, rules, '
          'portals, the audit log, conversations and model providers (with '
          'their keys) all live on the server, in its database: back that '
          'up to back everything up. This browser only remembers where the '
          'server is, who you are signed in as, and a few preferences.',
          style: muted,
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Fact('Server', session.serverUrl ?? 'Not set'),
                _Fact(
                  'Signed in as',
                  who == null
                      ? 'Nobody'
                      : who.kind == 'admin'
                      ? 'The admin token'
                      : '${who.name ?? who.login}'
                            '${who.login != null && who.name != null ? ' (${who.login})' : ''}',
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => ref.read(sessionProvider.notifier).signOut(),
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Sign out'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Signing out forgets the session on this browser. Nothing on '
                  'the server is deleted.',
                  style: muted,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Clean up', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              _DangerTile(
                icon: Icons.receipt_long_outlined,
                title: 'Clear the audit log',
                subtitle: '${events.length} recent events shown here',
                action: 'Clear',
                confirmTitle: 'Clear the audit log?',
                confirmBody: 'Every recorded event is deleted from the server, for everyone.',
                onConfirmed: () => ref.read(auditLogProvider.notifier).clear(),
              ),
              const Divider(height: 1),
              _DangerTile(
                icon: Icons.chat_outlined,
                title: 'Delete all my conversations',
                subtitle: '${chats.length} saved',
                action: 'Delete',
                confirmTitle: 'Delete all conversations?',
                confirmBody: 'Every Operator conversation of yours is removed from the server.',
                onConfirmed: () =>
                    ref.read(chatControllerProvider.notifier).deleteAll(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class _DangerTile extends StatelessWidget {
  const _DangerTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
    required this.confirmTitle,
    required this.confirmBody,
    required this.onConfirmed,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String action;
  final String confirmTitle;
  final String confirmBody;
  final Future<void> Function() onConfirmed;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: OutlinedButton(
        onPressed: () async {
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(confirmTitle),
              content: Text('$confirmBody This cannot be undone.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: StatusColors.bad,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(action),
                ),
              ],
            ),
          );
          if (ok != true) return;
          try {
            await onConfirmed();
          } on ServerException catch (e) {
            if (context.mounted) showSnack(context, e.message);
          }
        },
        child: Text(action),
      ),
    );
  }
}
