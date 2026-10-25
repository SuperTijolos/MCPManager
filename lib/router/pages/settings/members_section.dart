import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/server/access.dart';
import '../../../engine/server/access_control.dart';
import '../../../engine/server/server_client.dart';
import '../../../engine/server/session.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'access_widgets.dart';

/// Who can use this server, what they may do, and invitations.
class MembersSection extends ConsumerWidget {
  const MembersSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(accessControlProvider);
    final access = ref.watch(accessProvider);
    final me = ref.watch(sessionProvider.select((s) => s.identity?.id));
    final options = scopeOptions(ref);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final canManage = access.can('members.manage');
    final pending = [
      for (final i in data.invites)
        if (i.status == 'pending') i,
    ];

    return ListView(
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Members', style: theme.textTheme.titleMedium),
            ),
            if (canManage)
              FilledButton.icon(
                key: const ValueKey('invite-member'),
                onPressed: () => showInviteDialog(context),
                icon: const Icon(Icons.person_add_alt_1, size: 18),
                label: const Text('Invite'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Everyone who has signed in, with the role that decides what they '
          'may do. People are let in by a sign-in provider\'s list '
          '(Settings → Sign-in) or by an invitation. Nobody can give a role '
          'with more permissions than they have themselves.',
          style: muted,
        ),
        if (data.error != null) ...[
          const SizedBox(height: 8),
          Text(data.error!, style: const TextStyle(color: StatusColors.bad)),
        ],
        const SizedBox(height: 12),
        if (data.loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (data.members.isEmpty)
          const EmptyState(
            icon: Icons.group_outlined,
            title: 'Nobody has signed in yet',
            message: 'Invite someone, or add people to a provider\'s list.',
          )
        else
          for (final m in data.members)
            Card(
              child: ListTile(
                key: ValueKey('member-${m.id}'),
                leading: CircleAvatar(
                  backgroundImage: m.avatarUrl == null
                      ? null
                      : NetworkImage(m.avatarUrl!),
                  child: m.avatarUrl == null
                      ? Text(m.label.characters.first.toUpperCase())
                      : null,
                ),
                title: Text('${m.label}${m.id == me ? ' (you)' : ''}'),
                subtitle: Text(
                  [
                    m.email ?? m.login,
                    scopeSummary(
                      m.serverIds,
                      m.portalIds,
                      options.servers,
                      options.portals,
                    ),
                    m.lastSeenAt == null
                        ? 'never seen'
                        : 'seen ${formatAgo(m.lastSeenAt!)}',
                  ].join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Chip(
                      key: ValueKey('role-${m.id}'),
                      label: Text(data.roleName(m.role)),
                    ),
                    if (canManage && m.id != me) ...[
                      IconButton(
                        key: ValueKey('edit-member-${m.id}'),
                        tooltip: 'Change role and access',
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => showMemberDialog(context, m),
                      ),
                      IconButton(
                        key: ValueKey('remove-member-${m.id}'),
                        tooltip: 'Remove',
                        icon: const Icon(
                          Icons.person_remove_outlined,
                          size: 20,
                        ),
                        onPressed: () => _confirmRemove(context, ref, m),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        const SizedBox(height: 16),
        Text('Invitations', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'An invitation lets someone in with a role even when no provider '
          'list names them. Made out to an email address, it works for whoever '
          'signs in with that verified address, with or without the link. The '
          'link is shown once, when you make it.',
          style: muted,
        ),
        const SizedBox(height: 8),
        if (pending.isEmpty)
          Text('No pending invitations.', style: muted)
        else
          for (final i in pending)
            Card(
              child: ListTile(
                key: ValueKey('invite-${i.id}'),
                leading: const Icon(Icons.mail_outline),
                title: Text(i.email ?? 'Anyone with the link'),
                subtitle: Text(
                  '${data.roleName(i.role)} · by ${i.createdBy} · '
                  'expires ${formatDateTime(i.expiresAt)}',
                ),
                trailing: canManage
                    ? TextButton(
                        key: ValueKey('revoke-${i.id}'),
                        onPressed: () => serverAction(
                          context,
                          () => ref
                              .read(accessControlProvider.notifier)
                              .revokeInvite(i.id),
                        ),
                        child: const Text('Revoke'),
                      )
                    : null,
              ),
            ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    WidgetRef ref,
    MemberInfo m,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${m.label}?'),
        content: const Text(
          'They are signed out now. They can come back only if a provider\'s '
          'list names them or they are invited again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-remove-member'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await serverAction(
        context,
        () => ref.read(accessControlProvider.notifier).removeMember(m.id),
      );
    }
  }
}

// ------------------------------------------------------------------ dialogs

Future<void> showMemberDialog(BuildContext context, MemberInfo member) =>
    showDialog<void>(
      context: context,
      builder: (_) => _AccessDialog(member: member),
    );

Future<void> showInviteDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _AccessDialog());

/// Edit a member's role and limits, or make an invitation (no [member]).
class _AccessDialog extends ConsumerStatefulWidget {
  const _AccessDialog({this.member});
  final MemberInfo? member;

  @override
  ConsumerState<_AccessDialog> createState() => _AccessDialogState();
}

class _AccessDialogState extends ConsumerState<_AccessDialog> {
  final _email = TextEditingController();
  String? _role;
  List<String>? _servers;
  List<String>? _portals;
  int _days = 7;
  bool _saving = false;
  String? _error;
  CreatedInvite? _created;

  @override
  void initState() {
    super.initState();
    final m = widget.member;
    _role = m?.role;
    _servers = m?.serverIds;
    _portals = m?.portalIds;
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final role = _role;
    if (role == null) {
      setState(() => _error = 'Choose a role.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final store = ref.read(accessControlProvider.notifier);
    try {
      final m = widget.member;
      if (m != null) {
        await store.updateMember(
          m.id,
          role: role,
          serverIds: _servers,
          portalIds: _portals,
        );
        if (mounted) Navigator.pop(context);
      } else {
        final created = await store.invite(
          role: role,
          email: _email.text,
          serverIds: _servers,
          portalIds: _portals,
          expiresInDays: _days,
          returnTo: ref.read(dashboardAddressProvider),
        );
        if (mounted) {
          setState(() {
            _saving = false;
            _created = created;
          });
        }
      }
    } on ServerException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final access = ref.watch(accessProvider);
    final data = ref.watch(accessControlProvider);
    final options = scopeOptions(ref);
    final m = widget.member;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final created = _created;
    if (created != null) {
      return AlertDialog(
        title: const Text('Invitation ready'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                created.invite.email == null
                    ? 'Send this link to the person. Anyone with it can join '
                          'once, as ${data.roleName(created.invite.role)}.'
                    : 'Send this link to ${created.invite.email}. It only '
                          'works for an account with that verified email, and '
                          'they can also just sign in with it.',
                style: muted,
              ),
              const SizedBox(height: 8),
              CodeBlock(created.url),
              const SizedBox(height: 8),
              Text(
                'This is the only time the link is shown.',
                key: const ValueKey('invite-once'),
                style: muted,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: created.url)),
            child: const Text('Copy link'),
          ),
          FilledButton(
            key: const ValueKey('invite-done'),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      );
    }

    final roles = grantableRoles(access, data.roles);
    // A member's current role stays selectable even if it is above ours.
    final current = _role == null ? null : data.role(_role!);
    final choices = [
      ...roles,
      if (current != null && roles.every((r) => r.id != current.id)) current,
    ];

    return AlertDialog(
      title: Text(m == null ? 'Invite someone' : 'Access for ${m.label}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (m == null) ...[
                TextField(
                  key: const ValueKey('invite-email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email address (optional)',
                    helperText:
                        'Leave empty for a link anyone can use once. With an '
                        'address, only that verified email can.',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              DropdownButtonFormField<String>(
                key: const ValueKey('access-role'),
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final r in choices)
                    DropdownMenuItem(
                      value: r.id,
                      enabled: roles.any((x) => x.id == r.id),
                      child: Text(r.name),
                    ),
                ],
                onChanged: (v) => setState(() => _role = v),
              ),
              if (_role != null && data.role(_role!) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(data.role(_role!)!.description, style: muted),
                ),
              const SizedBox(height: 12),
              ScopePicker(
                label: 'Limit to some servers',
                noun: 'servers',
                options: options.servers,
                value: _servers,
                limitedTo: access.serverIds,
                onChanged: (v) => setState(() => _servers = v),
              ),
              ScopePicker(
                label: 'Limit to some portals',
                noun: 'portals',
                options: options.portals,
                value: _portals,
                limitedTo: access.portalIds,
                onChanged: (v) => setState(() => _portals = v),
              ),
              if (m == null) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<int>(
                  key: const ValueKey('invite-days'),
                  initialValue: _days,
                  decoration: const InputDecoration(labelText: 'Expires after'),
                  items: const [
                    DropdownMenuItem(value: 1, child: Text('1 day')),
                    DropdownMenuItem(value: 7, child: Text('7 days')),
                    DropdownMenuItem(value: 30, child: Text('30 days')),
                  ],
                  onChanged: (v) => setState(() => _days = v ?? 7),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  key: const ValueKey('access-error'),
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
          key: const ValueKey('access-save'),
          onPressed: _saving ? null : _save,
          child: Text(m == null ? 'Create invitation' : 'Save'),
        ),
      ],
    );
  }
}
