import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/server/access.dart';
import '../../../engine/server/access_control.dart';
import '../../../engine/server/server_client.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'access_widgets.dart';

/// Roles: named sets of permissions. The built-in ones are fixed; make your
/// own for anything in between.
class RolesSection extends ConsumerWidget {
  const RolesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final data = ref.watch(accessControlProvider);
    final access = ref.watch(accessProvider);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final canEdit = access.can('roles.manage');

    return ListView(
      children: [
        Row(
          children: [
            Expanded(child: Text('Roles', style: theme.textTheme.titleMedium)),
            if (canEdit)
              FilledButton.icon(
                key: const ValueKey('new-role'),
                onPressed: () => showRoleDialog(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New role'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'A role is a set of permissions. Give a role to a member, and '
          'optionally limit them to some servers or portals. Changing a role '
          'applies to everyone who has it, at once. You can only give '
          'permissions you have yourself.',
          style: muted,
        ),
        const SizedBox(height: 12),
        if (data.loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else
          for (final r in data.roles)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(r.name, style: theme.textTheme.titleSmall),
                          if (r.builtin) ...[
                            const SizedBox(width: 8),
                            const Tag('Built in'),
                          ],
                          const Spacer(),
                          if (canEdit && !r.builtin) ...[
                            OutlinedButton(
                              key: ValueKey('edit-role-${r.id}'),
                              onPressed: () =>
                                  showRoleDialog(context, existing: r),
                              child: const Text('Edit'),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              key: ValueKey('delete-role-${r.id}'),
                              onPressed: () => serverAction(
                                context,
                                () => ref
                                    .read(accessControlProvider.notifier)
                                    .deleteRole(r.id),
                              ),
                              child: const Text('Delete'),
                            ),
                          ],
                        ],
                      ),
                      if (r.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(r.description, style: muted),
                        ),
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '${r.members} ${r.members == 1 ? 'member' : 'members'}'
                          '${r.invites > 0 ? ' · ${r.invites} pending ${r.invites == 1 ? 'invitation' : 'invitations'}' : ''}',
                          style: muted,
                        ),
                      ),
                      const SizedBox(height: 8),
                      PermissionSummary(
                        permissions: data.permissions,
                        have: r.permissions,
                      ),
                    ],
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

Future<void> showRoleDialog(BuildContext context, {RoleInfo? existing}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _RoleDialog(existing: existing),
    );

class _RoleDialog extends ConsumerStatefulWidget {
  const _RoleDialog({this.existing});
  final RoleInfo? existing;

  @override
  ConsumerState<_RoleDialog> createState() => _RoleDialogState();
}

class _RoleDialogState extends ConsumerState<_RoleDialog> {
  late final _name = TextEditingController(text: widget.existing?.name ?? '');
  late final _description = TextEditingController(
    text: widget.existing?.description ?? '',
  );
  late final Set<String> _selected = {...?widget.existing?.permissions};
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Give the role a name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(accessControlProvider.notifier)
          .saveRole(
            id: widget.existing?.id,
            name: _name.text.trim(),
            description: _description.text.trim(),
            permissions: _selected,
          );
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final access = ref.watch(accessProvider);
    final defs = ref.watch(accessControlProvider).permissions;
    final groups = <String, List<PermissionInfo>>{};
    for (final p in defs) {
      (groups[p.group] ??= []).add(p);
    }

    return AlertDialog(
      title: Text(widget.existing == null ? 'New role' : 'Edit role'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                key: const ValueKey('role-name'),
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('role-description'),
                controller: _description,
                decoration: const InputDecoration(labelText: 'Description'),
              ),
              const SizedBox(height: 24),
              Text('Permissions', style: theme.textTheme.titleSmall),
              Text(
                'You can only give permissions you have yourself.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              for (final g in groups.entries) ...[
                const Divider(height: 24),
                Text(g.key, style: theme.textTheme.labelLarge),
                for (final p in g.value)
                  CheckboxListTile(
                    key: ValueKey('perm-${p.id}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(p.label),
                    subtitle: Text(p.id, style: theme.textTheme.bodySmall),
                    value: _selected.contains(p.id),
                    // Only what you have yourself can be given.
                    onChanged: access.can(p.id)
                        ? (on) => setState(
                            () => on == true
                                ? _selected.add(p.id)
                                : _selected.remove(p.id),
                          )
                        : null,
                  ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  key: const ValueKey('role-error'),
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
          key: const ValueKey('role-save'),
          onPressed: _saving ? null : _save,
          child: Text(widget.existing == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
