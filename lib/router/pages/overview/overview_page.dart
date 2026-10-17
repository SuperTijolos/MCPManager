import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/audit/audit_log.dart';
import '../../../engine/audit/audit_models.dart';
import '../../../engine/audit/audit_stats.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class OverviewPage extends ConsumerStatefulWidget {
  const OverviewPage({super.key});

  @override
  ConsumerState<OverviewPage> createState() => _OverviewPageState();
}

enum _Window {
  sixHours('6h', 6),
  day('24h', 24),
  week('7d', 168);

  const _Window(this.label, this.hours);
  final String label;
  final int hours;
}

class _OverviewPageState extends ConsumerState<OverviewPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  _Window _window = _Window.day;
  bool _reconnecting = false;

  Future<void> _reconnectAll() async {
    if (_reconnecting) return;
    setState(() => _reconnecting = true);
    try {
      final servers = ref
          .read(mcpHubProvider)
          .servers
          .where((s) => s.config.enabled);
      final notifier = ref.read(mcpHubProvider.notifier);
      await Future.wait(servers.map((s) => notifier.connect(s.config.id)));
    } finally {
      if (mounted) setState(() => _reconnecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hub = ref.watch(mcpHubProvider);
    final events = ref.watch(auditLogProvider);
    final settings = ref.watch(llmSettingsProvider);
    final stats = AuditStats.compute(
      events,
      window: Duration(hours: _window.hours),
    );
    final enabled = hub.servers.where((s) => s.config.enabled).toList();
    final attention = enabled
        .where(
          (s) =>
              s.status == ServerStatus.error ||
              s.status == ServerStatus.needsAuth,
        )
        .toList();
    final connected = enabled
        .where((s) => s.status == ServerStatus.connected)
        .length;
    final unavailable = enabled.length - connected;

    return PageScaffold(
      title: 'Overview',
      subtitle: 'MCP infrastructure, tool activity and operator readiness',
      actions: [
        IconButton(
          tooltip: 'Reconnect enabled servers',
          onPressed: enabled.isEmpty || _reconnecting ? null : _reconnectAll,
          icon: _reconnecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh_rounded),
        ),
      ],
      // Keep the scroll track in the page gutter, not over the rightmost card.
      padded: false,
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        thickness: 6,
        radius: const Radius.circular(6),
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(
            kPagePadding,
            8,
            kPagePadding + 18,
            kPagePadding,
          ),
          children: [
            if (hub.servers.isEmpty) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      const Text('Start by connecting your first MCP server.'),
                      FilledButton.icon(
                        onPressed: () => context.go('/servers'),
                        icon: const Icon(Icons.add),
                        label: const Text('Add server'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
            if (attention.isNotEmpty) ...[
              _AttentionCard(attention),
              const SizedBox(height: 16),
            ],
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 1040
                    ? 4
                    : constraints.maxWidth >= 430
                    ? 2
                    : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 12) / columns;
                Widget tile(Widget widget) =>
                    SizedBox(width: width, child: widget);
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    tile(
                      _StatCard(
                        label: 'Servers online',
                        value: '$connected/${enabled.length}',
                        detail: enabled.isEmpty
                            ? 'No enabled servers'
                            : unavailable == 0
                            ? 'All servers connected'
                            : '$unavailable unavailable',
                        icon: Icons.dns_outlined,
                        color: enabled.isEmpty
                            ? StatusColors.muted
                            : unavailable == 0
                            ? StatusColors.ok
                            : StatusColors.warn,
                        onTap: () => context.go('/servers'),
                      ),
                    ),
                    tile(
                      _StatCard(
                        label: 'Available tools',
                        value: '${hub.availableTools.length}',
                        detail: 'From connected servers',
                        icon: Icons.build_outlined,
                        color: StatusColors.info,
                        onTap: () => context.go('/tools'),
                      ),
                    ),
                    tile(
                      _StatCard(
                        label: 'Tool calls · ${_window.label}',
                        value: '${stats.total}',
                        detail: stats.avgLatencyMs == null
                            ? 'No response-time data'
                            : 'Avg ${stats.avgLatencyMs}ms · p95 ${stats.p95LatencyMs}ms',
                        icon: Icons.bolt_outlined,
                        color: StatusColors.info,
                        onTap: () => context.go('/audit'),
                      ),
                    ),
                    tile(
                      _StatCard(
                        label: 'Failure rate · ${_window.label}',
                        value: stats.total == 0
                            ? '—'
                            : '${(stats.errorRate * 100).toStringAsFixed(1)}%',
                        detail:
                            '${stats.error} errors · ${stats.denied} denied',
                        icon: Icons.error_outline,
                        color: stats.total == 0
                            ? StatusColors.muted
                            : stats.error == 0
                            ? StatusColors.ok
                            : StatusColors.bad,
                        onTap: () => context.go('/audit'),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final chart = _ActivityPanel(
                  stats: stats,
                  window: _window,
                  onChange: (value) => setState(() => _window = value),
                );
                final outcome = _OutcomesPanel(stats);
                return constraints.maxWidth >= 850
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 7, child: chart),
                          const SizedBox(width: 16),
                          Expanded(flex: 3, child: outcome),
                        ],
                      )
                    : Column(
                        children: [chart, const SizedBox(height: 16), outcome],
                      );
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final servers = _ServerHealthPanel(hub.servers);
                final model = _ModelCard(settings: settings);
                return constraints.maxWidth >= 850
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 7, child: servers),
                          const SizedBox(width: 16),
                          Expanded(flex: 3, child: model),
                        ],
                      )
                    : Column(
                        children: [servers, const SizedBox(height: 16), model],
                      );
              },
            ),
            const SizedBox(height: 16),
            LayoutBuilder(
              builder: (context, constraints) {
                final recent = _RecentEvents(events.take(6).toList());
                final tools = _TopTools(stats.topTools, window: _window.label);
                return constraints.maxWidth >= 850
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 7, child: recent),
                          const SizedBox(width: 16),
                          Expanded(flex: 3, child: tools),
                        ],
                      )
                    : Column(
                        children: [recent, const SizedBox(height: 16), tools],
                      );
              },
            ),
            const SizedBox(height: 12),
            Text(
              'Statistics are based on locally retained audit records '
              '(up to $auditCapacity events). Older history may be incomplete.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttentionCard extends StatelessWidget {
  const _AttentionCard(this.servers);
  final List<ServerRuntime> servers;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: StatusColors.warn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${servers.length} server${servers.length == 1 ? '' : 's'} need attention',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextButton(
                onPressed: () => context.go('/servers'),
                child: const Text('Manage'),
              ),
            ],
          ),
          for (final server in servers.take(3))
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Row(
                children: [
                  Icon(
                    server.status == ServerStatus.needsAuth
                        ? Icons.lock_outline
                        : Icons.error_outline,
                    size: 17,
                    color: server.status == ServerStatus.needsAuth
                        ? StatusColors.warn
                        : StatusColors.bad,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${server.config.name} · ${server.status == ServerStatus.needsAuth ? 'Sign-in required' : server.error ?? 'Connection failed'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          if (servers.length > 3)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('And ${servers.length - 3} more…'),
            ),
        ],
      ),
    ),
  );
}

class _ActivityPanel extends StatelessWidget {
  const _ActivityPanel({
    required this.stats,
    required this.window,
    required this.onChange,
  });
  final AuditStats stats;
  final _Window window;
  final ValueChanged<_Window> onChange;

  @override
  Widget build(BuildContext context) {
    final buckets = _compactBuckets(
      stats.hourly,
      window == _Window.week ? 6 : 1,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Tool activity',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SegmentedButton<_Window>(
                  showSelectedIcon: false,
                  segments: [
                    for (final w in _Window.values)
                      ButtonSegment(value: w, label: Text(w.label)),
                  ],
                  selected: {window},
                  onSelectionChanged: (selection) => onChange(selection.first),
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const _Legend(),
            const SizedBox(height: 18),
            SizedBox(
              height: 222,
              child: stats.total == 0
                  ? const Center(
                      child: Text(
                        'No tool calls in this period.\nRun a tool or ask the Operator.',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : _HourlyChart(buckets),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reduces one week to 28 six-hour buckets without losing individual outcomes.
List<HourBucket> _compactBuckets(List<HourBucket> source, int step) {
  if (step == 1) return source;
  final results = <HourBucket>[];
  for (var i = 0; i < source.length; i += step) {
    final group = source.skip(i).take(step);
    results.add(
      HourBucket(
        source[i].start,
        group.fold(0, (int n, e) => n + e.success),
        group.fold(0, (int n, e) => n + e.error),
        group.fold(0, (int n, e) => n + e.denied),
      ),
    );
  }
  return results;
}

class _OutcomesPanel extends StatelessWidget {
  const _OutcomesPanel(this.stats);
  final AuditStats stats;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Call outcomes', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          SizedBox(
            height: 182,
            child: stats.total == 0
                ? const Center(child: Text('No calls yet'))
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sectionsSpace: 2,
                          centerSpaceRadius: 48,
                          startDegreeOffset: -90,
                          sections: [
                            if (stats.success > 0)
                              PieChartSectionData(
                                color: StatusColors.ok,
                                value: stats.success.toDouble(),
                                radius: 19,
                                showTitle: false,
                              ),
                            if (stats.error > 0)
                              PieChartSectionData(
                                color: StatusColors.bad,
                                value: stats.error.toDouble(),
                                radius: 19,
                                showTitle: false,
                              ),
                            if (stats.denied > 0)
                              PieChartSectionData(
                                color: StatusColors.warn,
                                value: stats.denied.toDouble(),
                                radius: 19,
                                showTitle: false,
                              ),
                          ],
                        ),
                      ),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${stats.total}',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          Text(
                            'calls',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          _OutcomeRow('Success', stats.success, StatusColors.ok),
          _OutcomeRow('Error', stats.error, StatusColors.bad),
          _OutcomeRow('Denied', stats.denied, StatusColors.warn),
        ],
      ),
    ),
  );
}

class _OutcomeRow extends StatelessWidget {
  const _OutcomeRow(this.name, this.count, this.color);
  final String name;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(name, style: Theme.of(context).textTheme.bodySmall),
        ),
        Text(
          '$count',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    ),
  );
}

class _ServerHealthPanel extends StatelessWidget {
  const _ServerHealthPanel(this.servers);
  final List<ServerRuntime> servers;

  @override
  Widget build(BuildContext context) {
    int priority(ServerRuntime server) => switch (server.status) {
      ServerStatus.error => 0,
      ServerStatus.needsAuth => 1,
      ServerStatus.connecting => 2,
      ServerStatus.idle => 3,
      ServerStatus.connected => 4,
      ServerStatus.disabled => 5,
    };
    final ordered = [...servers]
      ..sort((a, b) => priority(a).compareTo(priority(b)));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Connection status',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/servers'),
                  child: const Text('View all'),
                ),
              ],
            ),
            if (ordered.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Text('No servers configured.'),
              )
            else
              for (final server in ordered.take(5))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    children: [
                      Icon(
                        switch (server.status) {
                          ServerStatus.connected => Icons.check_circle_outline,
                          ServerStatus.error => Icons.error_outline,
                          ServerStatus.needsAuth => Icons.lock_outline,
                          ServerStatus.connecting => Icons.sync,
                          _ => Icons.circle_outlined,
                        },
                        size: 18,
                        color: switch (server.status) {
                          ServerStatus.connected => StatusColors.ok,
                          ServerStatus.error => StatusColors.bad,
                          ServerStatus.needsAuth => StatusColors.warn,
                          ServerStatus.connecting => StatusColors.info,
                          _ => StatusColors.muted,
                        },
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          server.config.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        server.status == ServerStatus.connected
                            ? '${server.tools.length} tools'
                            : switch (server.status) {
                                ServerStatus.needsAuth => 'Sign-in required',
                                ServerStatus.error => 'Error',
                                ServerStatus.disabled => 'Disabled',
                                ServerStatus.connecting => 'Connecting',
                                _ => 'Idle',
                              },
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (server.status == ServerStatus.connected &&
                          server.latencyMs != null) ...[
                        const SizedBox(width: 12),
                        Text(
                          '${server.latencyMs} ms',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
            if (ordered.length > 5)
              Text(
                '${ordered.length - 5} more servers',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    this.detail,
    this.onTap,
  });

  final String label;
  final String value;
  final String? detail;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(value, style: theme.textTheme.headlineMedium),
              SizedBox(
                height: 18,
                child: detail == null
                    ? null
                    : Text(
                        detail!,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    Widget item(String label, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
    return Wrap(
      spacing: 12,
      children: [
        item('success', StatusColors.ok),
        item('error', StatusColors.bad),
        item('denied', StatusColors.warn),
      ],
    );
  }
}

class _HourlyChart extends StatelessWidget {
  const _HourlyChart(this.buckets);
  final List<HourBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final maxY = buckets
        .map((b) => b.total)
        .fold<int>(0, (a, b) => a > b ? a : b);
    final top = (maxY < 4 ? 4 : maxY + 1).toDouble();
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final labelStyle = TextStyle(fontSize: 11, color: muted);

    return BarChart(
      BarChartData(
        maxY: top,
        alignment: BarChartAlignment.spaceBetween,
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: top <= 8 ? 1 : null,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: muted.withValues(alpha: 0.15), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 28,
              interval: top <= 8 ? 1 : null,
              getTitlesWidget: (value, meta) => value == meta.max
                  ? const SizedBox.shrink()
                  : SideTitleWidget(
                      meta: meta,
                      child: Text(value.toInt().toString(), style: labelStyle),
                    ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: buckets.length <= 6 ? 1 : 4,
              reservedSize: 28,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    buckets.length > 24
                        ? '${buckets[i].start.day}/${buckets[i].start.month}'
                        : '${buckets[i].start.hour.toString().padLeft(2, '0')}h',
                    style: labelStyle,
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final b = buckets[group.x];
              return BarTooltipItem(
                '${formatDateTime(b.start)}\n'
                '${b.success} ok · ${b.error} error · ${b.denied} denied',
                const TextStyle(fontSize: 12, color: Colors.white),
              );
            },
          ),
        ),
        barGroups: [
          for (var i = 0; i < buckets.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: buckets[i].total.toDouble(),
                  width: 8,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(2),
                  ),
                  rodStackItems: [
                    BarChartRodStackItem(
                      0,
                      buckets[i].success.toDouble(),
                      StatusColors.ok,
                    ),
                    BarChartRodStackItem(
                      buckets[i].success.toDouble(),
                      (buckets[i].success + buckets[i].error).toDouble(),
                      StatusColors.bad,
                    ),
                    BarChartRodStackItem(
                      (buckets[i].success + buckets[i].error).toDouble(),
                      buckets[i].total.toDouble(),
                      StatusColors.warn,
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _RecentEvents extends StatelessWidget {
  const _RecentEvents(this.events);
  final List<AuditEvent> events;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent activity',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton(
                  onPressed: () => context.go('/audit'),
                  child: const Text('View all'),
                ),
              ],
            ),
            if (events.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: Text('Nothing yet.')),
              )
            else
              for (final e in events)
                ListTile(
                  onTap: () => context.go('/audit'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    statusIcon(e.status),
                    size: 18,
                    color: statusColor(e.status),
                  ),
                  title: Text(e.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${e.actor} · ${formatDateTime(e.timestamp)}'),
                  trailing: e.durationMs == null
                      ? null
                      : Text('${e.durationMs} ms'),
                ),
          ],
        ),
      ),
    );
  }
}

Color statusColor(AuditStatus s) => switch (s) {
  AuditStatus.success => StatusColors.ok,
  AuditStatus.error => StatusColors.bad,
  AuditStatus.denied => StatusColors.warn,
};

IconData statusIcon(AuditStatus s) => switch (s) {
  AuditStatus.success => Icons.check_circle_outline,
  AuditStatus.error => Icons.error_outline,
  AuditStatus.denied => Icons.block,
};

class _TopTools extends StatelessWidget {
  const _TopTools(this.tools, {required this.window});
  final List<MapEntry<String, int>> tools;
  final String window;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Busiest tools · $window',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (tools.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No calls yet.'),
              )
            else
              for (final t in tools)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(t.key, overflow: TextOverflow.ellipsis),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${t.value}',
                            style: const TextStyle(
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: t.value / tools.first.value,
                          minHeight: 5,
                          backgroundColor: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _ModelCard extends ConsumerStatefulWidget {
  const _ModelCard({required this.settings});
  final LlmSettings settings;

  @override
  ConsumerState<_ModelCard> createState() => _ModelCardState();
}

class _ModelCardState extends ConsumerState<_ModelCard> {
  @override
  void didUpdateWidget(covariant _ModelCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.activeModel != widget.settings.activeModel ||
        oldWidget.settings.activeProvider?.id !=
            widget.settings.activeProvider?.id) {
      _result = null;
      _ok = false;
    }
  }

  String? _result;
  bool _ok = false;
  bool _checking = false;

  Future<void> _check() async {
    final config = widget.settings.activeProvider;
    if (config == null) return;
    setState(() => _checking = true);
    final provider = ref.read(llmProviderFactoryProvider)(config);
    try {
      final models = await provider.listModels();
      final wanted = widget.settings.activeModel;
      final found = models.any(
        (m) => m.name == wanted || m.name.split(':').first == wanted,
      );
      if (!mounted) return;
      setState(() {
        _ok = found;
        _result = found
            ? 'Reachable · ${models.length} models'
            : 'Reachable, but "$wanted" is not installed (${models.length} models)';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = '$e';
      });
    } finally {
      provider.close();
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Operator model',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              s.isReady ? '${s.activeModel}' : 'Not configured',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            if (s.activeProvider != null)
              Text(
                '${s.activeProvider!.name} · ${s.activeProvider!.baseUrl}',
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 8),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _ok ? Icons.check_circle_outline : Icons.error_outline,
                      size: 16,
                      color: _ok ? StatusColors.ok : StatusColors.bad,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _result!,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: _ok ? StatusColors.ok : StatusColors.bad,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: s.activeProvider == null || _checking
                      ? null
                      : _check,
                  icon: _checking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.network_check, size: 18),
                  label: const Text('Test'),
                ),
                TextButton(
                  onPressed: () => context.go('/settings'),
                  child: const Text('Settings'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
