import 'audit_models.dart';

class HourBucket {
  const HourBucket(this.start, this.success, this.error, this.denied);
  final DateTime start;
  final int success;
  final int error;
  final int denied;
  int get total => success + error + denied;
}

class AuditStats {
  const AuditStats({
    required this.total,
    required this.success,
    required this.error,
    required this.denied,
    required this.avgLatencyMs,
    required this.p95LatencyMs,
    required this.hourly,
    required this.topTools,
  });

  final int total;
  final int success;
  final int error;
  final int denied;
  final int? avgLatencyMs;
  final int? p95LatencyMs;

  /// Oldest first, one bucket per hour, covering the requested window.
  final List<HourBucket> hourly;
  final List<MapEntry<String, int>> topTools;

  double get errorRate => total == 0 ? 0 : error / total;

  /// When the log is full and its oldest event is newer than the start of
  /// [window], older calls were dropped, so the window's statistics undercount.
  /// Returns that oldest retained timestamp, or null when the window is
  /// completely covered.
  static DateTime? truncatedSince(
    List<AuditEvent> events, {
    required int capacity,
    required Duration window,
    DateTime? now,
  }) {
    if (events.length < capacity) return null;
    final since = (now ?? DateTime.now()).subtract(window);
    final oldest = events
        .map((e) => e.timestamp)
        .reduce((a, b) => a.isBefore(b) ? a : b);
    return oldest.isAfter(since) ? oldest : null;
  }

  /// Tool-call statistics for the last [window]. Connection events are not
  /// tool calls and are excluded.
  factory AuditStats.compute(
    List<AuditEvent> events, {
    DateTime? now,
    Duration window = const Duration(hours: 24),
  }) {
    final end = now ?? DateTime.now();
    final since = end.subtract(window);
    final calls = events
        .where(
          (e) => e.kind == AuditKind.toolCall && e.timestamp.isAfter(since),
        )
        .toList();

    final hours = window.inHours;
    // Rolling one-hour buckets cover the exact requested interval; aligning to
    // clock hours would mislabel or omit events in the first partial hour.
    final firstHour = since;
    final success = List.filled(hours, 0);
    final error = List.filled(hours, 0);
    final denied = List.filled(hours, 0);
    for (final e in calls) {
      final index = e.timestamp.difference(firstHour).inHours;
      if (index < 0 || index >= hours) continue;
      switch (e.status) {
        case AuditStatus.success:
          success[index]++;
        case AuditStatus.error:
          error[index]++;
        case AuditStatus.denied:
          denied[index]++;
      }
    }

    final latencies = [
      for (final e in calls)
        if (e.durationMs != null && e.status != AuditStatus.denied)
          e.durationMs!,
    ]..sort();

    final perTool = <String, int>{};
    for (final e in calls) {
      final name = '${e.serverName ?? '?'} · ${e.toolName ?? '?'}';
      perTool[name] = (perTool[name] ?? 0) + 1;
    }
    final top = perTool.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return AuditStats(
      total: calls.length,
      success: calls.where((e) => e.status == AuditStatus.success).length,
      error: calls.where((e) => e.status == AuditStatus.error).length,
      denied: calls.where((e) => e.status == AuditStatus.denied).length,
      avgLatencyMs: latencies.isEmpty
          ? null
          : (latencies.reduce((a, b) => a + b) / latencies.length).round(),
      p95LatencyMs: latencies.isEmpty
          ? null
          : latencies[((latencies.length - 1) * 0.95).round()],
      hourly: [
        for (var i = 0; i < hours; i++)
          HourBucket(
            firstHour.add(Duration(hours: i)),
            success[i],
            error[i],
            denied[i],
          ),
      ],
      topTools: top.take(5).toList(),
    );
  }
}
