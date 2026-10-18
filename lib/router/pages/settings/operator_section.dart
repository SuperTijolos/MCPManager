import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../engine/agent/chat_controller.dart';
import '../../../engine/agent/operator_agent.dart';
import '../../../engine/rules/tool_rules_store.dart';
import '../../../engine/settings/app_settings.dart';
import '../../../ui/widgets.dart';

/// How the Operator behaves: loop limit, approvals, and your own instructions.
class OperatorSection extends ConsumerStatefulWidget {
  const OperatorSection({super.key});

  @override
  ConsumerState<OperatorSection> createState() => _OperatorSectionState();
}

class _OperatorSectionState extends ConsumerState<OperatorSection> {
  late final TextEditingController _instructions = TextEditingController(
    text: ref.read(appSettingsProvider).extraInstructions,
  );
  late int _steps = ref.read(appSettingsProvider).maxSteps;

  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _instructions.text.trim() !=
      ref.read(appSettingsProvider).extraInstructions.trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = ref.watch(appSettingsProvider);
    final store = ref.read(appSettingsProvider.notifier);
    final rules = ref.watch(toolRulesProvider);
    final chats = ref.watch(chatControllerProvider).conversations.length;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return ListView(
      children: [
        Text('Behaviour', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Tool steps per request',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    Text('$_steps', style: theme.textTheme.titleSmall),
                  ],
                ),
                Slider(
                  value: _steps.toDouble(),
                  min: 2,
                  max: 30,
                  divisions: 28,
                  label: '$_steps',
                  onChanged: (v) => setState(() => _steps = v.round()),
                  onChangeEnd: (v) =>
                      store.update((s) => s.copyWith(maxSteps: v.round())),
                ),
                Text(
                  'How many times the Operator may call the model and tools to answer one message. '
                  'Higher lets it work through longer tasks; lower stops runaway loops sooner.',
                  style: muted,
                ),
                const Divider(height: 28),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Ask before running read-only tools too'),
                  subtitle: const Text(
                    'By default tools a server marks read-only run without asking. '
                    'Turn this on to approve every call.',
                  ),
                  value: settings.confirmReadOnly,
                  onChanged: (v) =>
                      store.update((s) => s.copyWith(confirmReadOnly: v)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Your instructions', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _instructions,
                  minLines: 4,
                  maxLines: 10,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    hintText: 'e.g. "Our project lives in /Users/me/project. Prefer pnpm. Answer in Portuguese."',
                    alignLabelWithHint: true,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Text(
                  'Added to the Operator\'s system prompt on every message. They cannot override its safety rules.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    FilledButton(
                      onPressed: !_dirty
                          ? null
                          : () {
                              store.update(
                                (s) => s.copyWith(
                                  extraInstructions: _instructions.text.trim(),
                                ),
                              );
                              setState(() {});
                              showSnack(context, 'Instructions saved');
                            },
                      child: const Text('Save'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: _instructions.text.isEmpty
                          ? null
                          : () {
                              _instructions.clear();
                              setState(() {});
                            },
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text('Related', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.rule),
                title: const Text('Tool rules'),
                subtitle: Text(
                  '${rules.rules.length} rule${rules.rules.length == 1 ? '' : 's'} · '
                  '${rules.overrides.length} per-tool override${rules.overrides.length == 1 ? '' : 's'}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/mcp-tools'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Conversation history'),
                subtitle: Text('$chats saved'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.go('/chat'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Theme(
            data: theme.copyWith(dividerColor: Colors.transparent),
            child: const ExpansionTile(
              leading: Icon(Icons.article_outlined),
              title: Text('The built-in system prompt'),
              subtitle: Text(
                'Read-only: the rules the Operator always follows',
              ),
              childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [CodeBlock(operatorSystemPrompt, maxHeight: 420)],
            ),
          ),
        ),
      ],
    );
  }
}
