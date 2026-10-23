import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/audit/audit_text.dart';
import '../../../engine/portal/portal_api.dart';
import '../../../engine/portal/portal_controller.dart';
import '../../../engine/portal/portal_models.dart';
import '../../../ui/preview_section.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

/// Calls clients made through portals, as the gateway recorded them.
class ActivityTab extends ConsumerStatefulWidget {
  const ActivityTab({super.key});

  @override
  ConsumerState<ActivityTab> createState() => _ActivityTabState();
}

class _ActivityTabState extends ConsumerState<ActivityTab> {
  List<GatewayEvent>? _events;
  String? _error;
  String? _portalId;
  String? _status;
  String _query = '';
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final events = await ref
          .read(portalControllerProvider.notifier)
          .audit(portalId: _portalId, status: _status, query: _query);
      if (mounted) setState(() => _events = events);
    } on PortalApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final data = ref.watch(portalControllerProvider);
    final events = _events;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 240,
              child: TextField(
                key: const ValueKey('activity-search'),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Search',
                ),
                onChanged: (v) {
                  _query = v.trim();
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), _load);
                },
              ),
            ),
            for (final s in const ['success', 'error', 'denied'])
              FilterChip(
                key: ValueKey('activity-$s'),
                label: Text(s),
                selected: _status == s,
                onSelected: (on) {
                  setState(() => _status = on ? s : null);
                  _load();
                },
              ),
            if (data.portals.length > 1)
              DropdownButton<String?>(
                key: const ValueKey('activity-portal'),
                value: data.portals.any((p) => p.id == _portalId)
                    ? _portalId
                    : null,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: null,
                    child: Text('All portals'),
                  ),
                  for (final p in data.portals)
                    DropdownMenuItem(value: p.id, child: Text(p.name)),
                ],
                onChanged: (v) {
                  setState(() => _portalId = v);
                  _load();
                },
              ),
            IconButton(
              key: const ValueKey('activity-refresh'),
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _load,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: _error != null
              ? Center(child: Text(_error!))
              : events == null
              ? const Center(child: CircularProgressIndicator())
              : events.isEmpty
              ? const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No calls yet',
                  message: 'Calls that clients make through your portals appear here, newest first.',
                )
              : ListView.separated(
                  itemCount: events.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _EventTile(events[i]),
                ),
        ),
        if (events != null && events.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Showing the latest ${events.length}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}

Color _statusColor(String status) => switch (status) {
  'success' => StatusColors.ok,
  'denied' => StatusColors.warn,
  _ => StatusColors.bad,
};

IconData _statusIcon(String status) => switch (status) {
  'success' => Icons.check_circle_outline,
  'denied' => Icons.block,
  _ => Icons.error_outline,
};

class _EventTile extends StatelessWidget {
  const _EventTile(this.event);
  final GatewayEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final outcome = event.error ?? event.result;
    return Card(
      key: ValueKey('event-${event.id}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _EventDialog(event),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                _statusIcon(event.status),
                color: _statusColor(event.status),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      '${formatDateTime(event.timestamp)} · ${event.callerName} · ${event.portalSlug}'
                      '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                    if (outcome != null && outcome.trim().isNotEmpty)
                      Text(
                        summarizeResult(outcome),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: muted?.copyWith(
                          color: event.error != null ? StatusColors.bad : null,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusChip(event.status, _statusColor(event.status)),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _EventDialog extends StatelessWidget {
  const _EventDialog(this.event);
  final GatewayEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    _statusIcon(event.status),
                    color: _statusColor(event.status),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      event.title,
                      style: theme.textTheme.titleLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Text(
                '${formatDateTime(event.timestamp)} · ${event.callerName}'
                '${event.durationMs == null ? '' : ' · ${event.durationMs} ms'}',
                style: muted,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  StatusChip(event.status, _statusColor(event.status)),
                  StatusChip('portal: ${event.portalSlug}', StatusColors.muted),
                  StatusChip(
                    event.callerKind == 'oauth'
                        ? 'signed in with OAuth'
                        : 'access token',
                    StatusColors.info,
                  ),
                  if (event.forwarded != null)
                    const StatusChip(
                      'reshaped by rules',
                      StatusColors.warn,
                      icon: Icons.tune,
                    ),
                ],
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 4, bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (event.args != null)
                        PreviewSection(
                          event.forwarded != null
                              ? 'Arguments from the client'
                              : 'Arguments',
                          event.args!,
                          200,
                        ),
                      if (event.forwarded != null)
                        PreviewSection(
                          'Forwarded to the server',
                          event.forwarded!,
                          200,
                        ),
                      if (event.context != null)
                        PreviewSection(
                          'Audit-only context (not sent to the server)',
                          event.context!,
                          140,
                        ),
                      if (event.result != null)
                        PreviewSection('Result', event.result!, 260),
                      if (event.error != null)
                        PreviewSection('Error', event.error!, 180),
                    ],
                  ),
                ),
              ),
              const Divider(),
              SelectableText('Event ${event.id}', style: muted),
            ],
          ),
        ),
      ),
    );
  }
}
