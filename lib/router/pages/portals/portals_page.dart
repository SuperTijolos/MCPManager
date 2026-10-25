import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_controller.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'access_tab.dart';
import 'portals_tab.dart';

/// MCP Portals: publish chosen servers as authenticated MCP endpoints through the
/// server, and manage who may use them.
class PortalsPage extends ConsumerWidget {
  const PortalsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(portalControllerProvider);
    final controller = ref.read(portalControllerProvider.notifier);

    Widget body;
    if (data.connection == PortalConnection.connecting &&
        data.refreshedAt == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (data.connection != PortalConnection.connected &&
        data.refreshedAt == null) {
      body = _Unreachable(error: data.error, onRetry: controller.refresh);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.connection == PortalConnection.failed)
            _Banner(
              message:
                  '${data.error ?? 'The server did not answer.'} Showing what was loaded before.',
            ),
          const Expanded(child: _Tabs()),
        ],
      );
    }

    return PageScaffold(
      title: 'MCP Portals',
      subtitle:
          'Server ${data.serverUrl}${data.status == null ? '' : ' · v${data.status!.version}'}',
      actions: [
        IconButton(
          key: const ValueKey('portals-refresh'),
          tooltip: 'Refresh from the server',
          icon: data.connection == PortalConnection.connecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          onPressed: data.connection == PortalConnection.connecting
              ? null
              : controller.refresh,
        ),
      ],
      child: body,
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Portals'),
              Tab(text: 'Access'),
            ],
          ),
          SizedBox(height: 12),
          Expanded(child: TabBarView(children: [PortalsTab(), AccessTab()])),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: 8),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: StatusColors.warn.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: StatusColors.warn.withValues(alpha: 0.4)),
    ),
    child: Row(
      children: [
        const Icon(
          Icons.warning_amber_rounded,
          size: 18,
          color: StatusColors.warn,
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

class _Unreachable extends StatelessWidget {
  const _Unreachable({required this.error, required this.onRetry});
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off_outlined,
    title: 'Server not reachable',
    message: error ?? 'The server did not answer.',
    action: FilledButton(
      key: const ValueKey('gateway-retry'),
      onPressed: onRetry,
      child: const Text('Try again'),
    ),
  );
}
