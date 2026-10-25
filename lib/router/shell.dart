import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../engine/core/prefs.dart';
import '../engine/server/access.dart';
import '../ui/theme.dart';
import 'routes.dart';

/// Persists an explicit choice while still defaulting to the screen-width layout.
const _railExpandedKey = 'mcpm.navigation.rail.expanded.v1';

/// Responsive frame: a collapsible rail on desktop, a drawer on phones.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.location, required this.child});

  final String location;
  final Widget child;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  bool? _expandedPreference;

  @override
  void initState() {
    super.initState();
    _expandedPreference = ref
        .read(sharedPreferencesProvider)
        .getBool(_railExpandedKey);
  }

  void _toggleRail(bool currentlyExpanded) {
    final expanded = !currentlyExpanded;
    setState(() => _expandedPreference = expanded);
    unawaited(
      ref.read(sharedPreferencesProvider).setBool(_railExpandedKey, expanded),
    );
  }

  /// The pages this person is offered.
  List<AppDestination> get _main {
    final access = ref.read(accessProvider);
    return [
      for (final d in mainDestinations)
        if (d.permission == null || access.can(d.permission!)) d,
    ];
  }

  int get _mainIndex {
    final main = _main;
    for (var i = 0; i < main.length; i++) {
      final path = main[i].path;
      if (path == '/'
          ? widget.location == '/'
          : widget.location.startsWith(path)) {
        return i;
      }
    }
    return -1;
  }

  int get _secondaryIndex => secondaryDestinations.indexWhere(
    (d) => widget.location.startsWith(d.path),
  );

  @override
  Widget build(BuildContext context) {
    ref.watch(identityRefresherProvider);
    ref.watch(accessProvider);
    final width = MediaQuery.sizeOf(context).width;
    if (width < kWideBreakpoint) {
      return _narrowLayout(context);
    }
    // Preserve tablet's icon-only rail as the default at intermediate widths.
    final expanded = _expandedPreference ?? width >= 1200;
    return _wideLayout(context, expanded: expanded);
  }

  Widget _wideLayout(BuildContext context, {required bool expanded}) {
    final main = _main;
    final all = [...main, ...secondaryDestinations];
    final selected = _mainIndex >= 0
        ? _mainIndex
        : _secondaryIndex >= 0
        ? main.length + _secondaryIndex
        : 0;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: expanded,
            selectedIndex: selected,
            onDestinationSelected: (i) => context.go(all[i].path),
            leading: _RailBrand(expanded: expanded),
            trailingAtBottom: true,
            trailing: _RailFooter(
              expanded: expanded,
              onToggle: () => _toggleRail(expanded),
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
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  Widget _narrowLayout(BuildContext context) {
    final all = [..._main, ...secondaryDestinations];
    final current = all.where(
      (d) => d.path == '/'
          ? widget.location == '/'
          : widget.location.startsWith(d.path),
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
      body: widget.child,
    );
  }
}

/// Shows the full app name when expanded and marks the start of navigation.
class _RailBrand extends StatelessWidget {
  const _RailBrand({required this.expanded});

  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expanded ? 256 : 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(expanded ? 20 : 0, 16, 0, 16),
            child: Align(
              alignment: expanded ? Alignment.centerLeft : Alignment.center,
              child: _Brand(extended: expanded),
            ),
          ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}

/// Keep the collapse action at the bottom, separate from navigation items.
/// The footer never affects the rail's standard 256/80px widths.
class _RailFooter extends StatelessWidget {
  const _RailFooter({required this.expanded, required this.onToggle});

  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: expanded ? 256 : 80,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Align(
              alignment: expanded ? Alignment.centerRight : Alignment.center,
              child: IconButton(
                tooltip: expanded ? 'Collapse sidebar' : 'Expand sidebar',
                onPressed: onToggle,
                icon: Icon(
                  expanded
                      ? Icons.chevron_left_rounded
                      : Icons.chevron_right_rounded,
                ),
                iconSize: 22,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
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
