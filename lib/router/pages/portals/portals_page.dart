import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../engine/portal/portal_controller.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'access_tab.dart';
import 'activity_tab.dart';
import 'connect_card.dart';
import 'portals_tab.dart';
import 'servers_tab.dart';

/// Portals: publish chosen servers as authenticated MCP endpoints through the
/// gateway server.
class PortalsPage extends ConsumerStatefulWidget {
  const PortalsPage({super.key});

  @override
  ConsumerState<PortalsPage> createState() => _PortalsPageState();
}

class _PortalsPageState extends ConsumerState<PortalsPage> {
  bool _editConnection = false;

  @override
  void initState() {
    super.initState();
    // Read the gateway when the page opens, if one is saved.
    Future.microtask(() {
      if (!mounted) return;
      final data = ref.read(portalControllerProvider);
      if (data.settings.configured &&
          data.connection == PortalConnection.connecting) {
        ref.read(portalControllerProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(portalControllerProvider);
    final controller = ref.read(portalControllerProvider.notifier);
    final configured = data.settings.configured;

    Widget body;
    if (!configured || _editConnection) {
      body = GatewayConnectCard(
        initialUrl: data.settings.url,
        error: data.error,
      );
    } else if (data.connection == PortalConnection.connecting &&
        !data.connected &&
        data.refreshedAt == null) {
      body = const Center(child: CircularProgressIndicator());
    } else if (data.connection == PortalConnection.failed &&
        data.refreshedAt == null) {
      body = _Unreachable(
        error: data.error,
        onRetry: controller.refresh,
        onEdit: () => setState(() => _editConnection = true),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (data.connection == PortalConnection.failed)
            _Banner(
              message:
                  '${data.error ?? 'The gateway did not answer.'} Showing what was loaded before.',
            ),
          const Expanded(child: _Tabs()),
        ],
      );
    }

    return PageScaffold(
      title: 'Portals',
      subtitle: configured
          ? 'Gateway ${data.settings.url}${data.status == null ? '' : ' · v${data.status!.version}'}'
          : 'Publish your servers as MCP endpoints for Claude, ChatGPT and other clients',
      actions: [
        if (configured && !_editConnection) ...[
          IconButton(
            key: const ValueKey('portals-refresh'),
            tooltip: 'Refresh from the gateway',
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
          PopupMenuButton<String>(
            key: const ValueKey('portals-menu'),
            tooltip: 'Gateway connection',
            onSelected: (v) {
              if (v == 'edit') setState(() => _editConnection = true);
              if (v == 'disconnect') _confirmDisconnect();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'edit',
                child: Text('Change address or token'),
              ),
              PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
            ],
          ),
        ] else if (configured)
          TextButton(
            onPressed: () => setState(() => _editConnection = false),
            child: const Text('Back'),
          ),
      ],
      child: body,
    );
  }

  Future<void> _confirmDisconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect from the gateway?'),
        content: const Text(
          'This app forgets the address and admin token. The gateway, its '
          'portals and tokens keep running.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-disconnect'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(portalControllerProvider.notifier).disconnect();
      if (mounted) setState(() => _editConnection = false);
    }
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Portals'),
              Tab(text: 'Servers'),
              Tab(text: 'Access'),
              Tab(text: 'Activity'),
            ],
          ),
          SizedBox(height: 12),
          Expanded(
            child: TabBarView(
              children: [
                PortalsTab(),
                ServersTab(),
                AccessTab(),
                ActivityTab(),
              ],
            ),
          ),
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
  const _Unreachable({
    required this.error,
    required this.onRetry,
    required this.onEdit,
  });
  final String? error;
  final VoidCallback onRetry;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => EmptyState(
    icon: Icons.cloud_off_outlined,
    title: 'Gateway not reachable',
    message: error ?? 'The gateway did not answer.',
    action: Wrap(
      spacing: 8,
      children: [
        FilledButton(
          key: const ValueKey('gateway-retry'),
          onPressed: onRetry,
          child: const Text('Try again'),
        ),
        OutlinedButton(
          key: const ValueKey('gateway-edit'),
          onPressed: onEdit,
          child: const Text('Change address or token'),
        ),
      ],
    ),
  );
}
