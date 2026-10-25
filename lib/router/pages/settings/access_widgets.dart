import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_controller.dart';
import '../../../engine/server/access.dart';
import '../../../engine/server/access_control.dart';

/// The roles [access] may hand out: nobody can give more than they have.
List<RoleInfo> grantableRoles(Access access, List<RoleInfo> roles) => [
  for (final r in roles)
    if (r.permissions.every(access.can)) r,
];

/// "All servers" or a chosen few. [value] null means all.
class ScopePicker extends StatelessWidget {
  const ScopePicker({
    super.key,
    required this.label,
    required this.noun,
    required this.options,
    required this.value,
    required this.onChanged,
    this.limitedTo,
  });

  final String label;

  /// Plural noun for the "All …" text, e.g. `servers`.
  final String noun;

  /// id → name.
  final Map<String, String> options;
  final List<String>? value;
  final ValueChanged<List<String>?> onChanged;

  /// The person choosing is themselves limited to these (null = no limit).
  final List<String>? limitedTo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final limited = value != null;
    final shown = {
      for (final e in options.entries)
        if (limitedTo == null || limitedTo!.contains(e.key)) e.key: e.value,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          key: ValueKey('scope-$noun'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(label),
          subtitle: Text(
            limited
                ? 'Only the $noun ticked below'
                : 'All $noun, including new ones',
            style: theme.textTheme.bodySmall,
          ),
          // On means "limited to a few".
          value: limited,
          // Someone who is limited themselves cannot lift the limit.
          onChanged: limited && limitedTo != null
              ? null
              : (v) => onChanged(v ? <String>[] : null),
        ),
        if (limited)
          if (shown.isEmpty)
            Text('There are no $noun yet.', style: theme.textTheme.bodySmall)
          else
            for (final e in shown.entries)
              CheckboxListTile(
                key: ValueKey('scope-$noun-${e.key}'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(e.value),
                value: value!.contains(e.key),
                onChanged: (on) => onChanged([
                  for (final id in value!)
                    if (id != e.key) id,
                  if (on == true) e.key,
                ]),
              ),
      ],
    );
  }
}

/// The servers and portals a scope can name, by id.
({Map<String, String> servers, Map<String, String> portals}) scopeOptions(
  WidgetRef ref,
) {
  final data = ref.watch(portalControllerProvider);
  return (
    servers: {for (final s in data.servers) s.id: s.name},
    portals: {for (final p in data.portals) p.id: p.name},
  );
}

/// A short description of what someone is limited to.
String scopeSummary(
  List<String>? servers,
  List<String>? portals,
  Map<String, String> serverNames,
  Map<String, String> portalNames,
) {
  String part(List<String>? ids, Map<String, String> names, String noun) =>
      ids == null
      ? 'All $noun'
      : ids.isEmpty
      ? 'No $noun'
      : ids.map((i) => names[i] ?? i).join(', ');
  if (servers == null && portals == null) return 'Everything';
  return '${part(servers, serverNames, 'servers')} · '
      '${part(portals, portalNames, 'portals')}';
}

/// A small label, for things like "Built in".
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// What a role allows, one line per area: `MCP servers   view  manage`.
class PermissionSummary extends StatelessWidget {
  const PermissionSummary({
    super.key,
    required this.permissions,
    required this.have,
  });

  final List<PermissionInfo> permissions;
  final Set<String> have;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = <String, List<PermissionInfo>>{};
    for (final p in permissions) {
      if (have.contains(p.id)) (groups[p.group] ??= []).add(p);
    }
    if (groups.isEmpty) {
      return Text(
        'No permissions',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in groups.entries)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 110,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      g.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final p in g.value)
                        Tooltip(
                          message: p.label,
                          child: Tag(p.id.substring(p.id.indexOf('.') + 1)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
