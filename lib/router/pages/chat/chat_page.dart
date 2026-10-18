import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/agent/operator_agent.dart';
import '../../../engine/core/json.dart';
import '../../../engine/llm/llm_settings.dart';
import '../../../engine/llm/provider_config.dart';
import '../../../engine/mcp/mcp_hub.dart';
import '../../../ui/sign_in.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets.dart';
import 'history_panel.dart';

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
    // Sending always shows the newest message, wherever you had scrolled to.
    if (_scroll.hasClients) _scroll.jumpTo(0);
    ref.read(chatControllerProvider.notifier).send(text);
    _focus.requestFocus();
  }

  bool _historyOpen = true;
  bool _showThinking = true;

  Widget _conversation(ChatState chat, LlmSettings settings) => Column(
    children: [
      Expanded(
        child: chat.items.isEmpty
            ? _Welcome(
                onPick: (text) {
                  _input.text = text;
                  _send();
                },
              )
            // One selection area for the whole transcript: selectable text in
            // every message is far heavier, and this also selects across
            // messages. The list is reversed so it stays pinned to the newest
            // message while the reply streams in, with no jumping to a
            // re-estimated end of a long list.
            : SelectionArea(
                child: ListView.builder(
                  controller: _scroll,
                  reverse: true,
                  padding: const EdgeInsets.symmetric(
                    horizontal: kPagePadding,
                    vertical: 8,
                  ),
                  itemCount: chat.items.length,
                  findChildIndexCallback: (key) {
                    if (key is! ValueKey<String>) return null;
                    final index = chat.items.indexWhere(
                      (item) => item.id == key.value,
                    );
                    return index < 0 ? null : chat.items.length - 1 - index;
                  },
                  itemBuilder: (context, i) {
                    final index = chat.items.length - 1 - i;
                    final item = chat.items[index];
                    return Center(
                      key: ValueKey(item.id),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 820),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: SizedBox(
                            width: double.infinity,
                            child: _ItemView(
                              item,
                              isLast: index == chat.items.length - 1,
                              running: chat.running,
                              showThinking: _showThinking,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
      const _SignInBanner(),
      Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 4, kPagePadding, 0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Wrap(
              alignment: WrapAlignment.start,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 4,
              children: [
                const _ApprovalToggle(),
                if (chat.contextUsed != null && chat.contextLimit != null)
                  _ContextMeter(
                    used: chat.contextUsed!,
                    limit: chat.contextLimit!,
                  ),
                if (chat.items.whereType<AssistantItem>().any(
                  (item) => item.thinking.isNotEmpty,
                ))
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showThinking = !_showThinking),
                    icon: Icon(
                      _showThinking
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 17,
                    ),
                    label: Text(
                      _showThinking ? 'Hide thinking' : 'Show thinking',
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): _send,
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
  );

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatControllerProvider);
    final settings = ref.watch(llmSettingsProvider);
    final wide = MediaQuery.sizeOf(context).width >= 980;
    final active = chat.conversations
        .where((c) => c.id == chat.activeId)
        .firstOrNull;

    return PageScaffold(
      title: 'Chat',
      subtitle: settings.isReady
          ? '${active?.title ?? 'New conversation'} · ${settings.activeModel}'
          : 'No model configured',
      padded: false,
      actions: [
        const _ModelPicker(),
        const SizedBox(width: 4),
        IconButton(
          tooltip: wide
              ? (_historyOpen ? 'Hide history' : 'Show history')
              : 'Conversation history',
          icon: Icon(
            Icons.history,
            color: wide && _historyOpen
                ? Theme.of(context).colorScheme.primary
                : null,
          ),
          onPressed: wide
              ? () => setState(() => _historyOpen = !_historyOpen)
              : () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (sheet) => SizedBox(
                    height: MediaQuery.sizeOf(sheet).height * 0.75,
                    child: HistoryPanel(onPicked: () => Navigator.pop(sheet)),
                  ),
                ),
        ),
        IconButton(
          key: const ValueKey('compact-conversation'),
          tooltip: 'Compact conversation (summarize older messages)',
          icon: const Icon(Icons.compress),
          onPressed: chat.items.isEmpty || chat.running
              ? null
              : ref.read(chatControllerProvider.notifier).compactNow,
        ),
        IconButton(
          tooltip: 'New conversation',
          icon: const Icon(Icons.add_comment_outlined),
          onPressed: chat.items.isEmpty
              ? null
              : ref.read(chatControllerProvider.notifier).newConversation,
        ),
      ],
      child: wide && _historyOpen
          ? Row(
              children: [
                const SizedBox(width: 280, child: HistoryPanel()),
                const VerticalDivider(width: 1),
                Expanded(child: _conversation(chat, settings)),
              ],
            )
          : _conversation(chat, settings),
    );
  }
}

/// Chooses, for the open conversation, whether tool calls wait for your
/// approval or run automatically. New chats start with the last choice.
class _ApprovalToggle extends ConsumerWidget {
  const _ApprovalToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auto = ref.watch(chatControllerProvider.select((s) => s.autoApprove));
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.front_hand_outlined),
          label: Text('Ask first'),
          tooltip: 'Each tool call waits for your approval',
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.bolt),
          label: Text('Automatic'),
          tooltip: 'Tool calls run in this chat without asking',
        ),
      ],
      selected: {auto},
      onSelectionChanged: (s) =>
          ref.read(chatControllerProvider.notifier).setAutoApprove(s.first),
    );
  }
}

/// How full the model's window was on the latest call.
class _ContextMeter extends StatelessWidget {
  const _ContextMeter({required this.used, required this.limit});
  final int used;
  final int limit;

  static String _k(int n) =>
      n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final color = share > 0.85
        ? StatusColors.bad
        : share > 0.65
        ? StatusColors.warn
        : theme.colorScheme.primary;
    return Tooltip(
      message:
          'The last request used about ${_k(used)} of the model\'s '
          '${_k(limit)}-token window. Older messages are summarized '
          'automatically when it fills up.',
      child: Row(
        key: const ValueKey('context-meter'),
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 64,
            child: LinearProgressIndicator(
              value: share,
              minHeight: 5,
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${_k(used)} / ${_k(limit)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
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
    final hasModels = settings.providers.any((p) => p.models.isNotEmpty);
    if (!hasModels) {
      return TextButton.icon(
        onPressed: () => context.go('/settings'),
        icon: const Icon(Icons.tune, size: 18),
        label: const Text('Configure model'),
      );
    }
    return Tooltip(
      message: 'Choose model',
      child: ActionChip(
        key: const ValueKey('model-picker'),
        avatar: const Icon(Icons.memory, size: 16),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(
            settings.activeModel ?? 'Pick a model',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _ModelPickerDialog(),
        ),
      ),
    );
  }
}

/// Every enabled model of every provider, with a search box: the list grows
/// quickly once a cloud provider's catalogue is switched on.
class _ModelPickerDialog extends ConsumerStatefulWidget {
  const _ModelPickerDialog();

  @override
  ConsumerState<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends ConsumerState<_ModelPickerDialog> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(llmSettingsProvider);
    final theme = Theme.of(context);
    final words = _query.toLowerCase().split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    bool matches(ProviderConfig p, String model) {
      final haystack = '$model ${p.name}'.toLowerCase();
      return words.every(haystack.contains);
    }

    final groups = [
      for (final p in settings.providers)
        (
          provider: p,
          models: [
            for (final m in p.models)
              if (matches(p, m)) m,
          ],
        ),
    ].where((g) => g.models.isNotEmpty).toList();
    final total = settings.providers.fold<int>(
      0,
      (n, p) => n + p.models.length,
    );
    final showProviders =
        settings.providers.where((p) => p.models.isNotEmpty).length > 1;

    return AlertDialog(
      title: const Text('Choose model'),
      contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search $total models',
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: groups.isEmpty
                  ? const Center(child: Text('No matching models'))
                  : ListView(
                      children: [
                        for (final g in groups) ...[
                          if (showProviders)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
                              child: Text(
                                g.provider.name,
                                style: theme.textTheme.labelMedium?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          for (final m in g.models)
                            ListTile(
                              key: ValueKey('model-${g.provider.id}-$m'),
                              dense: true,
                              selected:
                                  g.provider.id == settings.activeProviderId &&
                                  m == settings.activeModel,
                              leading: Icon(
                                g.provider.id == settings.activeProviderId &&
                                        m == settings.activeModel
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 18,
                              ),
                              title: Text(m, overflow: TextOverflow.ellipsis),
                              onTap: () {
                                ref
                                    .read(llmSettingsProvider.notifier)
                                    .setActive(g.provider.id, m);
                                Navigator.pop(context);
                              },
                            ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            context.go('/settings');
          },
          child: const Text('Manage models'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
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
      icon: Icons.chat_bubble_outline,
      title: 'Chat with your tools',
      message:
          'Ask in plain language. The assistant can inspect servers and the '
          'audit log, and run tools — asking you first unless a tool is '
          'read-only.',
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

class _ItemView extends StatefulWidget {
  const _ItemView(
    this.item, {
    required this.isLast,
    required this.running,
    required this.showThinking,
  });
  final ChatItem item;
  final bool isLast;
  final bool running;
  final bool showThinking;

  @override
  State<_ItemView> createState() => _ItemViewState();
}

/// While a reply streams in, every token rebuilds the list. Handing back the
/// same widget instance for unchanged inputs makes Flutter skip finished
/// messages instead of re-parsing their Markdown (Widget cannot override ==).
class _ItemViewState extends State<_ItemView> {
  Widget? _built;
  ChatItem? _item;
  bool? _isLast;
  bool? _running;
  bool? _showThinking;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _built = null; // the theme may have changed
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (_built == null ||
        !identical(_item, w.item) ||
        _isLast != w.isLast ||
        _running != w.running ||
        _showThinking != w.showThinking) {
      _item = w.item;
      _isLast = w.isLast;
      _running = w.running;
      _showThinking = w.showThinking;
      _built = _buildItem(context, w);
    }
    return _built!;
  }

  Widget _buildItem(BuildContext context, _ItemView widget) {
    final item = widget.item;
    final isLast = widget.isLast;
    final running = widget.running;
    final showThinking = widget.showThinking;
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
          child: Text(text),
        ),
      ),
      final AssistantItem a => _AssistantView(
        a,
        streaming: isLast && running,
        showThinking: showThinking,
      ),
      final ToolItem t => _ToolCard(
        key: ValueKey('tool-card-${t.id}'),
        item: t,
      ),
      NoticeItem(:final text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.compress,
            size: 15,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
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
            Expanded(child: Text(message)),
          ],
        ),
      ),
    };
  }
}

class _AssistantView extends StatelessWidget {
  const _AssistantView(
    this.item, {
    required this.streaming,
    required this.showThinking,
  });
  final AssistantItem item;
  final bool streaming;
  final bool showThinking;

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
        if (showThinking && item.thinking.isNotEmpty)
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
                  child: Text(
                    item.thinking,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (item.text.isNotEmpty) ...[
          MarkdownBody(data: item.text, styleSheet: style),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Copy response',
              visualDensity: VisualDensity.compact,
              iconSize: 17,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: item.text));
                showSnack(context, 'Response copied');
              },
              icon: const Icon(Icons.copy_outlined),
            ),
          ),
        ] else if (streaming && (item.thinking.isEmpty || !showThinking))
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

/// Compact inspection card for an Operator MCP call. Arguments are collapsed
/// for completed calls so a conversation with many calls stays readable. For
/// calls awaiting permission they are expanded so the user can review exactly
/// what is about to be sent before approving.
class _ToolCard extends ConsumerWidget {
  const _ToolCard({super.key, required this.item});
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
    final argCount = item.args.length;
    final result = item.output;
    final resultJson = result == null ? null : tryDecodeJson(result);

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
                  child: Tooltip(
                    message: item.name,
                    child: Text(
                      item.label,
                      style: theme.textTheme.titleSmall,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StatusChip(label, color, icon: icon),
              ],
            ),
            if (item.summary != null) ...[
              const SizedBox(height: 8),
              Text(item.summary!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 4),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                key: ValueKey('tool-arguments-${item.id}'),
                initiallyExpanded: item.status == ToolStatus.awaitingApproval,
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                dense: true,
                title: Text('Arguments', style: theme.textTheme.bodySmall),
                subtitle: Text(
                  argCount == 0
                      ? 'No arguments'
                      : '$argCount ${argCount == 1 ? 'field' : 'fields'}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                children: [JsonBlock(item.args, maxHeight: 180)],
              ),
            ),
            if (item.status == ToolStatus.awaitingApproval) ...[
              const SizedBox(height: 6),
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
            if (result != null)
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: ValueKey('tool-result-${item.id}'),
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text('Result', style: theme.textTheme.bodySmall),
                  subtitle: Text(
                    '${resultJson == null ? 'Text' : 'JSON'} · ${result.length} characters',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  children: [
                    CodeBlock(
                      resultJson == null ? result : prettyJson(resultJson),
                      maxHeight: 280,
                      json: resultJson != null,
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
