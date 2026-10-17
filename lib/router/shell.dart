import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../ui/theme.dart';
import 'routes.dart';

/// Responsive frame: a navigation rail on wide screens, a drawer on narrow ones.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  int get _mainIndex {
    for (var i = 0; i < mainDestinations.length; i++) {
      final path = mainDestinations[i].path;
      if (path == '/' ? location == '/' : location.startsWith(path)) return i;
    }
    return -1;
  }

  int get _secondaryIndex =>
      secondaryDestinations.indexWhere((d) => location.startsWith(d.path));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final wide = MediaQuery.sizeOf(context).width >= kWideBreakpoint;
    return wide ? _wideLayout(context) : _narrowLayout(context);
  }

  Widget _wideLayout(BuildContext context) {
    final all = [...mainDestinations, ...secondaryDestinations];
    final selected = _mainIndex >= 0
        ? _mainIndex
        : _secondaryIndex >= 0
        ? mainDestinations.length + _secondaryIndex
        : 0;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: MediaQuery.sizeOf(context).width >= 1200,
            selectedIndex: selected,
            onDestinationSelected: (i) => context.go(all[i].path),
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: _Brand(),
            ),
            destinations: [
              for (final d in all)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _narrowLayout(BuildContext context) {
    final all = [...mainDestinations, ...secondaryDestinations];
    final current = all.where(
      (d) => d.path == '/' ? location == '/' : location.startsWith(d.path),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(current.isEmpty ? 'MCP Manager' : current.first.label),
      ),
      drawer: Drawer(
        child: SafeArea(
          child: ListView(
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: _Brand(extended: true),
              ),
              for (final d in all)
                ListTile(
                  leading: Icon(
                    current.isNotEmpty && current.first == d
                        ? d.selectedIcon
                        : d.icon,
                  ),
                  title: Text(d.label),
                  selected: current.isNotEmpty && current.first == d,
                  onTap: () {
                    Navigator.of(context).pop();
                    context.go(d.path);
                  },
                ),
            ],
          ),
        ),
      ),
      body: child,
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand({this.extended = false});
  final bool extended;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.hub_rounded, color: color, size: 28),
        if (extended) ...[
          const SizedBox(width: 10),
          const Text(
            'MCP Manager',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
          ),
        ],
      ],
    );
  }
}
