import 'package:flutter/material.dart';

import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'data_section.dart';
import 'models_section.dart';
import 'operator_section.dart';

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
  data(
    'Account & data',
    Icons.shield_outlined,
    'Who is signed in, where data lives, clean-up',
  );

  const _Section(this.label, this.icon, this.subtitle);
  final String label;
  final IconData icon;
  final String subtitle;
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _Section _section = _Section.models;

  Widget get _content => switch (_section) {
    _Section.models => const ModelsSection(),
    _Section.operator => const OperatorSection(),
    _Section.data => const DataSection(),
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kWideBreakpoint + 100;

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
                      for (final s in _Section.values)
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
                      for (final s in _Section.values) ...[
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
