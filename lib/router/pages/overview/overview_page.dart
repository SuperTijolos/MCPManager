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

class OverviewPage extends ConsumerWidget {
  const OverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hub = ref.watch(mcpHubProvider);
    final events = ref.watch(auditLogProvider);
    final settings = ref.watch(llmSettingsProvider);
    final stats = AuditStats.compute(events);
    final toolCount = hub.availableTools.length;

    return PageScaffold(
      title: 'Overview',
      subtitle: 'Servers, tools and activity at a glance',
      child: ListView(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 900 ? 4 : 2;
              final width =
                  (constraints.maxWidth - 12 * (columns - 1)) / columns;
              Widget tile(Widget w) => SizedBox(width: width, child: w);
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  tile(
                    _StatCard(
                      label: 'Servers online',
                      value: '${hub.connectedCount}/${hub.servers.length}',
                      icon: Icons.dns_outlined,
                      color:
                          hub.servers.isNotEmpty &&
                              hub.connectedCount == hub.servers.length
                          ? StatusColors.ok
                          : StatusColors.warn,
                      onTap: () => context.go('/servers'),
                    ),
                  ),
                  tile(
                    _StatCard(
                      label: 'Tools available',
                      value: '$toolCount',
                      icon: Icons.build_outlined,
                      color: StatusColors.info,
                      onTap: () => context.go('/tools'),
                    ),
                  ),
                  tile(
                    _StatCard(
                      label: 'Tool calls · 24h',
                      value: '${stats.total}',
                      detail: stats.avgLatencyMs == null
                          ? null
                          : 'avg ${stats.avgLatencyMs} ms · p95 ${stats.p95LatencyMs} ms',
                      icon: Icons.bolt_outlined,
                      color: StatusColors.info,
                      onTap: () => context.go('/audit'),
                    ),
                  ),
                  tile(
                    _StatCard(
                      label: 'Error rate · 24h',
                      value: stats.total == 0
                          ? '—'
                          : '${(stats.errorRate * 100).round()}%',
                      detail: stats.total == 0
                          ? null
                          : '${stats.error} failed · ${stats.denied} denied',
                      icon: Icons.error_outline,
                      color: stats.error == 0
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'Tool calls per hour',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const _Legend(),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 200,
                    child: stats.total == 0
                        ? const Center(
                            child: Text(
                              'No tool calls in the last 24 hours.\nRun a tool or ask the Operator.',
                              textAlign: TextAlign.center,
                            ),
                          )
                        : _HourlyChart(stats.hourly),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 800;
              final recent = _RecentEvents(events.take(6).toList());
              final side = Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ModelCard(settings: settings),
                  const SizedBox(height: 16),
                  _TopTools(stats.topTools),
                ],
              );
              return wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: recent),
                        const SizedBox(width: 16),
                        Expanded(flex: 2, child: side),
                      ],
                    )
                  : Column(
                      children: [recent, const SizedBox(height: 16), side],
                    );
            },
          ),
        ],
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
              interval: 4,
              reservedSize: 24,
              getTitlesWidget: (value, meta) {
                final i = value.toInt();
                if (i < 0 || i >= buckets.length) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    '${buckets[i].start.hour.toString().padLeft(2, '0')}h',
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
                '${b.start.hour.toString().padLeft(2, '0')}:00\n'
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
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    statusIcon(e.status),
                    size: 18,
                    color: statusColor(e.status),
                  ),
                  title: Text(e.title, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${e.actor} · ${formatTime(e.timestamp)}'),
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
  const _TopTools(this.tools);
  final List<MapEntry<String, int>> tools;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Busiest tools · 24h',
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
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(t.key, overflow: TextOverflow.ellipsis),
                      ),
                      Text(
                        '${t.value}',
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
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
            Row(
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
                const SizedBox(width: 8),
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
