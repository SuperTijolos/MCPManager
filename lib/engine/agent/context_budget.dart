import 'dart:convert';

import '../llm/llm_types.dart';

/// First words of the message that stands in for summarized history.
const compactionMarker = '[Summary of the earlier conversation';

/// A rough count: about 3.5 characters per token for English and JSON. The
/// provider's real prompt token counts calibrate it (see
/// [ContextCompactor.calibrate]).
int estimateTokens(String text) => (text.length / 3.5).ceil();

int estimateMessageTokens(LlmMessage m) {
  var n = 6 + estimateTokens(m.content);
  final thinking = m.thinking;
  if (thinking != null) n += estimateTokens(thinking);
  for (final c in m.toolCalls) {
    n += estimateTokens(c.name) + estimateTokens(jsonEncode(c.arguments)) + 4;
  }
  return n;
}

int estimateHistoryTokens(Iterable<LlmMessage> history) =>
    history.fold(0, (n, m) => n + estimateMessageTokens(m));

int estimateSpecTokens(Iterable<LlmToolSpec> specs) => specs.fold(
  0,
  (n, s) =>
      n +
      estimateTokens(s.name) +
      estimateTokens(s.description) +
      estimateTokens(jsonEncode(s.parameters)) +
      8,
);

bool isCompactionSummary(LlmMessage m) =>
    m.role == LlmRole.user && m.content.startsWith(compactionMarker);

enum CompactionKind {
  /// Old tool results and reasoning were cut down.
  shortened,

  /// Older messages were replaced by a summary.
  summarized,

  /// Older messages were dropped (the summary could not be written).
  trimmed,
}

class CompactionResult {
  const CompactionResult({
    required this.kind,
    required this.tokensBefore,
    required this.tokensAfter,
  });

  final CompactionKind kind;
  final int tokensBefore;
  final int tokensAfter;

  String get message {
    final what = switch (kind) {
      CompactionKind.shortened => 'Shortened older tool results',
      CompactionKind.summarized => 'Summarized earlier messages',
      CompactionKind.trimmed =>
        'Dropped earlier messages (a summary could not be written)',
    };
    return '$what to stay within the model\'s context window '
        '(~${_k(tokensBefore)} → ~${_k(tokensAfter)} tokens).';
  }
}

String _k(int tokens) => tokens >= 1000
    ? '${(tokens / 1000).toStringAsFixed(tokens >= 10000 ? 0 : 1)}k'
    : '$tokens';

const _summaryPrompt = '''
You compress a conversation so an AI assistant can keep working with less context.
The assistant manages MCP servers and runs their tools for the user.

Write a compact summary (at most about 300 words) of the conversation below. Keep:
- what the user wants and what is still unfinished;
- what was done and what was found (server names, URLs, tool names, ids, file paths, error messages);
- decisions and preferences the user stated.

Leave out pleasantries and long outputs. Never include passwords, tokens or API keys.
Reply with the summary only, in the language the conversation uses.
''';

/// Keeps a conversation inside the model's context window.
///
/// First it cuts down what is cheap to lose (old tool results, old
/// reasoning). If that is not enough it has the model summarize the older
/// messages, and as a last resort drops them. The most recent turns always
/// stay verbatim. It edits the list it is given, which is the stored history.
class ContextCompactor {
  ContextCompactor({
    required this.provider,
    required this.model,
    required this.contextTokens,
    this.keepTurns = 2,
  });

  final LlmProvider provider;
  final String model;
  final int contextTokens;

  /// How many of the latest user turns are never touched.
  final int keepTurns;

  /// Compaction starts when the prompt would pass this share of the room...
  static const triggerAt = 0.8;

  /// ...and the cheap pass is enough once it is back under this one.
  static const settleAt = 0.6;

  double _scale = 1;

  /// Room for the prompt: the window minus space for the reply.
  int get _limit =>
      contextTokens - (contextTokens ~/ 10 < 1024 ? 1024 : contextTokens ~/ 10);

  /// Adjusts the estimate to what the provider really counted.
  void calibrate({required int actual, required int estimated}) {
    if (actual <= 0 || estimated <= 0) return;
    final ratio = (actual / estimated).clamp(0.6, 2.5);
    _scale = _scale * 0.5 + ratio * 0.5;
  }

  /// Whether a prompt of [fixedTokens] plus [history] is over the trigger.
  bool needsCompaction(List<LlmMessage> history, int fixedTokens) =>
      _total(history, fixedTokens) > _limit * triggerAt;

  int _total(List<LlmMessage> history, int fixedTokens) =>
      ((fixedTokens + estimateHistoryTokens(history)) * _scale).ceil();

  /// Compacts [history] when it is needed (or [force]d). Returns what
  /// happened, or null when nothing was done.
  Future<CompactionResult?> ensureFits(
    List<LlmMessage> history, {
    required int fixedTokens,
    bool force = false,
  }) async {
    if (!force && !needsCompaction(history, fixedTokens)) return null;
    final before = _total(history, fixedTokens);
    final keepFrom = _keepFrom(history);
    var kind = CompactionKind.shortened;
    var changed = _shorten(history, keepFrom, maxChars: 500);

    final settled = _total(history, fixedTokens) <= _limit * settleAt;
    if ((!settled || force) && keepFrom > 0) {
      final region = history.sublist(0, keepFrom);
      String? summary;
      try {
        summary = await _summarize(region);
      } catch (_) {
        summary = null;
      }
      if (summary != null && summary.trim().isNotEmpty) {
        history.replaceRange(0, keepFrom, [
          LlmMessage.user(
            '$compactionMarker, for your context only]\n${summary.trim()}',
          ),
          const LlmMessage.assistant(
            'Understood. I will continue from that summary.',
          ),
        ]);
        kind = CompactionKind.summarized;
      } else {
        history.removeRange(0, keepFrom);
        kind = CompactionKind.trimmed;
      }
      changed = true;
    }

    // The latest turns may carry huge results of their own.
    if (_total(history, fixedTokens) > _limit) {
      changed = _shorten(history, history.length, maxChars: 1500) || changed;
    }
    if (!changed) return null;
    return CompactionResult(
      kind: kind,
      tokensBefore: before,
      tokensAfter: _total(history, fixedTokens),
    );
  }

  /// Index of the first message kept verbatim: the start of the
  /// [keepTurns]-th latest user turn, or 0 when there is nothing older.
  int _keepFrom(List<LlmMessage> history) {
    var seen = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      if (m.role != LlmRole.user || isCompactionSummary(m)) continue;
      seen++;
      if (seen == keepTurns) return i;
    }
    return 0;
  }

  /// Cuts reasoning and long results among `history[0..upTo)`.
  bool _shorten(List<LlmMessage> history, int upTo, {required int maxChars}) {
    var changed = false;
    for (var i = 0; i < upTo && i < history.length; i++) {
      final m = history[i];
      var next = m;
      if (m.thinking != null) next = next.copyWith(dropThinking: true);
      if (m.role == LlmRole.tool && m.content.length > maxChars + 200) {
        next = next.copyWith(content: _cut(m.content, maxChars));
      } else if (m.role == LlmRole.assistant &&
          m.content.length > maxChars * 6) {
        next = next.copyWith(content: _cut(m.content, maxChars * 3));
      }
      if (!identical(next, m)) {
        history[i] = next;
        changed = true;
      }
    }
    return changed;
  }

  String _cut(String text, int keep) {
    final removed = text.length - keep;
    final closing = text.contains('</tool_output>') ? '\n</tool_output>' : '';
    return '${text.substring(0, keep)}\n'
        '…[$removed characters removed to save context]$closing';
  }

  Future<String> _summarize(List<LlmMessage> region) async {
    final text = StringBuffer();
    await for (final event in provider.chat(
      model: model,
      messages: [
        const LlmMessage.system(_summaryPrompt),
        LlmMessage.user(_transcript(region)),
      ],
    )) {
      if (event is LlmTextDelta) text.write(event.text);
    }
    return text.toString();
  }

  /// The region as plain text, kept small enough to fit the window itself.
  String _transcript(List<LlmMessage> region) {
    String clip(String s, int max) =>
        s.length <= max ? s : '${s.substring(0, max)}…';
    final lines = <String>[];
    for (final m in region) {
      switch (m.role) {
        case LlmRole.user:
          lines.add('User: ${clip(m.content, 2000)}');
        case LlmRole.assistant:
          if (m.content.trim().isNotEmpty) {
            lines.add('Assistant: ${clip(m.content, 1500)}');
          }
          for (final c in m.toolCalls) {
            lines.add(
              'Assistant called ${c.name}(${clip(jsonEncode(c.arguments), 300)})',
            );
          }
        case LlmRole.tool:
          lines.add('Result of ${m.toolName}: ${clip(m.content, 600)}');
        case LlmRole.system:
          break;
      }
    }
    final budget = (_limit * 0.6 * 3.5).floor();
    var total = 0;
    final kept = <String>[];
    for (final line in lines.reversed) {
      total += line.length + 1;
      if (total > budget) {
        kept.add('(earlier part omitted)');
        break;
      }
      kept.add(line);
    }
    return kept.reversed.join('\n');
  }
}
