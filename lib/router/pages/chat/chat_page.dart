import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/agent/operator_agent.dart';
import '../../../engine/core/json.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../ui/sign_in.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';

class ChatPage extends ConsumerStatefulWidget {
  const ChatPage({super.key});

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    ref.read(chatControllerProvider.notifier).send(text);
    _focus.requestFocus();
  }

  void _followTail() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final position = _scroll.position;
      // Only follow when the user is already near the bottom.
      if (position.maxScrollExtent - position.pixels < 160) {
        _scroll.jumpTo(position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final settings = ref.watch(llmSettingsProvider);
    ref.listen(chatControllerProvider, (previous, next) => _followTail());

    return PageScaffold(
      title: 'Operator',
      subtitle: settings.isReady
          ? '${settings.activeModel} · ${settings.activeProvider!.name}'
          : 'No model configured',
      padded: false,
      actions: [
        const _ModelPicker(),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'New conversation',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: chat.items.isEmpty
              ? null
              : ref.read(chatControllerProvider.notifier).clear,
        ),
      ],
      child: Column(
        children: [
          Expanded(
            child: chat.items.isEmpty
                ? _Welcome(
                    onPick: (text) {
                      _input.text = text;
                      _send();
                    },
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                      horizontal: kPagePadding,
                      vertical: 8,
                    ),
                    itemCount: chat.items.length,
                    itemBuilder: (context, i) => Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 820),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: SizedBox(
                            width: double.infinity,
                            child: _ItemView(
                              chat.items[i],
                              isLast: i == chat.items.length - 1,
                              running: chat.running,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          const _SignInBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              4,
              kPagePadding,
              16,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: CallbackShortcuts(
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter):
                              _send,
                        },
                        child: TextField(
                          controller: _input,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: 6,
                          textInputAction: TextInputAction.newline,
                          decoration: const InputDecoration(
                            hintText: 'Ask about servers, tools or failures… (Shift+Enter for a new line)',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    chat.running
                        ? IconButton.filledTonal(
                            tooltip: 'Stop',
                            icon: const Icon(Icons.stop_rounded),
                            onPressed: ref
                                .read(chatControllerProvider.notifier)
                                .stop,
                          )
                        : IconButton.filled(
                            tooltip: 'Send',
                            icon: const Icon(Icons.arrow_upward_rounded),
                            onPressed: settings.isReady
                                ? _send
                                : () => context.go('/settings'),
                          ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelPicker extends ConsumerWidget {
  const _ModelPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(llmSettingsProvider);
    final entries = [
      for (final p in settings.providers)
        for (final m in p.models) (provider: p, model: m),
    ];
    if (entries.isEmpty) {
      return TextButton.icon(
        onPressed: () => context.go('/settings'),
        icon: const Icon(Icons.tune, size: 18),
        label: const Text('Configure model'),
      );
    }
    return PopupMenuButton<({String providerId, String model})>(
      tooltip: 'Choose model',
      onSelected: (v) => ref
          .read(llmSettingsProvider.notifier)
          .setActive(v.providerId, v.model),
      itemBuilder: (context) => [
        for (final e in entries)
          PopupMenuItem(
            value: (providerId: e.provider.id, model: e.model),
            child: Row(
              children: [
                Icon(
                  e.provider.id == settings.activeProviderId &&
                          e.model == settings.activeModel
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text('${e.model}  '),
                Text(
                  e.provider.name,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.memory, size: 16),
        label: Text(settings.activeModel ?? 'Pick a model'),
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    const prompts = [
      'Which servers are connected?',
      'Summarise the last 24 hours.',
      'Were there any errors recently?',
    ];
    return EmptyState(
      icon: Icons.smart_toy_outlined,
      title: 'Operator',
      message: 'Ask in plain language. The Operator can inspect servers and the audit log, and run tools — asking you first unless a tool is read-only.',
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (final p in prompts)
            ActionChip(label: Text(p), onPressed: () => onPick(p)),
        ],
      ),
    );
  }
}

class _ItemView extends StatelessWidget {
  const _ItemView(this.item, {required this.isLast, required this.running});
  final ChatItem item;
  final bool isLast;
  final bool running;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      UserItem(:final text) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 620),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary
                .withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(14),
          ),
          child: SelectableText(text),
        ),
      ),
      final AssistantItem a => _AssistantView(a, streaming: isLast && running),
      final ToolItem t => _ToolCard(t),
      ErrorItem(:final message) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: StatusColors.bad.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: StatusColors.bad.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, color: StatusColors.bad, size: 18),
            const SizedBox(width: 8),
            Expanded(child: SelectableText(message)),
          ],
        ),
      ),
    };
  }
}

class _AssistantView extends StatelessWidget {
  const _AssistantView(this.item, {required this.streaming});
  final AssistantItem item;
  final bool streaming;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = MarkdownStyleSheet.fromTheme(theme).copyWith(
      code: const TextStyle(
        fontFamilyFallback: monoFonts,
        fontSize: 13,
        backgroundColor: Color(0xFF0B0F14),
      ),
      codeblockDecoration: BoxDecoration(
        color: const Color(0xFF0B0F14),
        borderRadius: BorderRadius.circular(8),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.thinking.isNotEmpty)
          Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                'Thinking',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(
                    item.thinking,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (item.text.isNotEmpty)
          MarkdownBody(data: item.text, selectable: true, styleSheet: style)
        else if (streaming && item.thinking.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}

class _ToolCard extends ConsumerWidget {
  const _ToolCard(this.item);
  final ToolItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(chatControllerProvider.notifier);
    final (label, color, icon) = switch (item.status) {
      ToolStatus.awaitingApproval => (
        'Needs approval',
        StatusColors.warn,
        Icons.shield_outlined,
      ),
      ToolStatus.running => ('Running', StatusColors.info, Icons.sync),
      ToolStatus.done => ('Done', StatusColors.ok, Icons.check_circle_outline),
      ToolStatus.error => ('Failed', StatusColors.bad, Icons.error_outline),
      ToolStatus.denied => ('Denied', StatusColors.warn, Icons.block),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.build_circle_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(item.label, style: theme.textTheme.titleSmall),
                ),
                StatusChip(label, color, icon: icon),
              ],
            ),
            if (item.summary != null) ...[
              const SizedBox(height: 8),
              Text(item.summary!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 8),
            Text('Arguments', style: theme.textTheme.bodySmall),
            const SizedBox(height: 4),
            JsonBlock(item.args, maxHeight: 140),
            if (item.status == ToolStatus.awaitingApproval) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => controller.decide(
                      item.callId,
                      ApprovalDecision.approveOnce,
                    ),
                    child: const Text('Approve'),
                  ),
                  if (item.canAlwaysAllow)
                    OutlinedButton(
                      onPressed: () => controller.decide(
                        item.callId,
                        ApprovalDecision.approveSession,
                      ),
                      child: const Text('Always allow this tool'),
                    ),
                  TextButton(
                    onPressed: () =>
                        controller.decide(item.callId, ApprovalDecision.deny),
                    child: const Text('Deny'),
                  ),
                ],
              ),
            ],
            if (item.output != null) ...[
              const SizedBox(height: 10),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                dense: true,
                title: const Text('Result'),
                children: [CodeBlock(_pretty(item.output!), maxHeight: 280)],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _pretty(String text) {
    final decoded = tryDecodeJson(text);
    return decoded == null ? text : prettyJson(decoded);
  }
}

/// Offers a Sign in button for servers that need OAuth. The Operator can add
/// such a server but cannot sign in for the user: the sign-in window has to
/// open from a real click.
class _SignInBanner extends ConsumerWidget {
  const _SignInBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final waiting = [
      for (final s in ref.watch(mcpHubProvider).servers)
        if (s.status == ServerStatus.needsAuth) s,
    ];
    if (waiting.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 4),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: StatusColors.warn.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: StatusColors.warn.withValues(alpha: 0.4),
              ),
            ),
            child: Column(
              children: [
                for (final s in waiting)
                  Row(
                    children: [
                      const Icon(
                        Icons.lock_outline,
                        size: 18,
                        color: StatusColors.warn,
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${s.config.name} needs sign-in')),
                      FilledButton.tonal(
                        onPressed: () =>
                            signInToServer(context, ref, s.config.id),
                        child: const Text('Sign in'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
