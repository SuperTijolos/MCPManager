import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/server/access.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'data_section.dart';
import 'members_section.dart';
import 'roles_section.dart';
import 'models_section.dart';
import 'operator_section.dart';
import 'sign_in_section.dart';

enum _Section {
  models(
    'Models',
    Icons.memory,
    'Providers and the model the Operator runs on',
  ),
  operator(
    'Operator',
    Icons.smart_toy_outlined,
    'Limits, approvals and your instructions',
  ),
  members(
    'Members',
    Icons.group_outlined,
    'Who can use this server, and invitations',
    permission: 'members.view',
  ),
  roles(
    'Roles',
    Icons.admin_panel_settings_outlined,
    'What each role may do',
    permission: 'members.view',
  ),
  signIn(
    'Sign-in',
    Icons.login,
    'How people sign in to this server, and who is let in',
    permission: 'providers.manage',
  ),
  data(
    'Account & data',
    Icons.shield_outlined,
    'Who is signed in, where data lives, clean-up',
  );

  const _Section(this.label, this.icon, this.subtitle, {this.permission});
  final String label;
  final String? permission;
  final IconData icon;
  final String subtitle;
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  _Section _section = _Section.models;

  Widget get _content => switch (_section) {
    _Section.models => const ModelsSection(),
    _Section.operator => const OperatorSection(),
    _Section.members => const MembersSection(),
    _Section.roles => const RolesSection(),
    _Section.signIn => const SignInSection(),
    _Section.data => const DataSection(),
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kWideBreakpoint + 100;
    final access = ref.watch(accessProvider);
    final sections = [
      for (final s in _Section.values)
        if (s.permission == null || access.can(s.permission!)) s,
    ];
    // A section that was open when the person lost the right to it.
    if (!sections.contains(_section)) _section = sections.first;

    return PageScaffold(
      title: 'Settings',
      subtitle: _section.subtitle,
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 210,
                  child: ListView(
                    children: [
                      for (final s in sections)
                        ListTile(
                          leading: Icon(s.icon, size: 20),
                          title: Text(s.label),
                          selected: s == _section,
                          selectedTileColor: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          onTap: () => setState(() => _section = s),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: _content),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final s in sections) ...[
                        ChoiceChip(
                          avatar: Icon(s.icon, size: 16),
                          label: Text(s.label),
                          selected: s == _section,
                          onSelected: (_) => setState(() => _section = s),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(child: _content),
              ],
            ),
    );
  }
}
