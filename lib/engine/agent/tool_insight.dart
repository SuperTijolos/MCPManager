import '../core/json.dart';
import '../mcp/mcp_models.dart';

/// What a tool is *for*, worked out from its name, parameters and annotations
/// rather than from any particular server. This lets the Operator reason about
/// an arbitrary set of MCP servers: "I need a file's real location → use an
/// exploring tool or a command tool", whatever those happen to be called.
enum Capability {
  explore('Explore & find'),
  execute('Run commands'),
  read('Read'),
  write('Create / change'),
  delete('Delete / stop'),
  navigate('Open / navigate'),
  diagnose('Diagnostics & code intelligence'),
  vcs('Version control'),
  web('Web & network'),
  data('Data & databases'),
  terminal('Terminals');

  const Capability(this.label);
  final String label;
}

const _keywords = <Capability, Set<String>>{
  Capability.explore: {
    'list',
    'ls',
    'search',
    'find',
    'glob',
    'grep',
    'tree',
    'dir',
    'directory',
    'directories',
    'workspace',
    'workspaces',
    'symbols',
    'outline',
    'explore',
    'browse',
    'locate',
    'lookup',
    'info',
    'status',
    'overview',
    'projects',
    'folders',
    'tabs',
    'discover',
    'inventory',
    'describe',
    'where',
  },
  Capability.execute: {
    'exec',
    'execute',
    'run',
    'shell',
    'bash',
    'sh',
    'command',
    'cmd',
    'spawn',
    'eval',
    'script',
    'invoke',
  },
  Capability.read: {
    'read',
    'get',
    'show',
    'view',
    'cat',
    'fetch',
    'load',
    'open',
    'print',
    'contents',
    'content',
  },
  Capability.write: {
    'write',
    'create',
    'edit',
    'update',
    'set',
    'save',
    'put',
    'apply',
    'replace',
    'insert',
    'append',
    'patch',
    'rename',
    'move',
    'copy',
    'add',
    'modify',
    'format',
    'refactor',
  },
  Capability.delete: {
    'delete',
    'remove',
    'rm',
    'kill',
    'drop',
    'clear',
    'destroy',
    'trash',
    'stop',
    'close',
    'terminate',
    'purge',
  },
  Capability.navigate: {
    'open',
    'goto',
    'reveal',
    'focus',
    'select',
    'scroll',
    'navigate',
    'jump',
  },
  Capability.diagnose: {
    'diagnostics',
    'diagnostic',
    'lint',
    'problems',
    'errors',
    'warnings',
    'hover',
    'references',
    'definition',
    'definitions',
    'typecheck',
    'implementations',
    'callers',
    'actions',
  },
  Capability.vcs: {
    'git',
    'commit',
    'branch',
    'diff',
    'stage',
    'push',
    'pull',
    'merge',
    'checkout',
    'blame',
    'stash',
  },
  Capability.web: {
    'http',
    'https',
    'url',
    'web',
    'request',
    'scrape',
    'download',
    'crawl',
    'browser',
    'page',
    'click',
    'screenshot',
  },
  Capability.data: {
    'sql',
    'database',
    'db',
    'table',
    'tables',
    'row',
    'rows',
    'record',
    'records',
    'schema',
    'collection',
    'index',
  },
  Capability.terminal: {'terminal', 'terminals', 'pty', 'tty', 'console'},
};

/// Parameter names that suggest the tool runs something.
const _commandParams = {
  'command',
  'cmd',
  'script',
  'code',
  'shell',
  'commandline',
};

/// Words that make a parameter hold a location (a file, folder or URL).
const _pathWords = {
  'url',
  'path',
  'filepath',
  'file',
  'filename',
  'dir',
  'directory',
  'folder',
  'cwd',
  'root',
  'uri',
  'location',
  'target',
  'source',
  'destination',
};

List<String> tokens(String text) {
  // Split camelCase and snake/kebab/dotted words into lowercase tokens.
  final spaced = text
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[^A-Za-z0-9]+'), ' ');
  return [
    for (final t in spaced.toLowerCase().split(' '))
      if (t.isNotEmpty) t,
  ];
}

/// Whether two words are the same stem ("search"/"searches"), without letting
/// short words like "git" match "github".
bool _related(String a, String b) {
  final (short, long) = a.length <= b.length ? (a, b) : (b, a);
  return short.length >= 4 && long.startsWith(short);
}

/// The classification of one tool, with the name the model calls it by.
class ToolInsight {
  ToolInsight({
    required this.exposedName,
    required this.serverName,
    required this.tool,
    required this.capabilities,
    required this.pathArgs,
    required this._words,
  });

  final String exposedName;
  final String serverName;
  final McpTool tool;
  final Set<Capability> capabilities;

  /// Parameters that look like a file/folder/URL location.
  final List<String> pathArgs;
  final Set<String> _words;

  bool get readOnly => tool.isReadOnly;
  List<String> get requiredArgs => [
    for (final r in (tool.inputSchema['required'] as List?) ?? const []) '$r',
  ];

  /// One line about the tool: its own title/description, shortened.
  String get summary {
    final text = (tool.description ?? tool.title ?? '').trim();
    if (text.isEmpty) return tool.displayName;
    final firstSentence = text.split(RegExp(r'(?<=[.!?])\s|\n')).first;
    return firstSentence.length > 140
        ? '${firstSentence.substring(0, 140).trimRight()}…'
        : firstSentence;
  }

  factory ToolInsight.of({
    required String exposedName,
    required String serverName,
    required McpTool tool,
  }) {
    final nameTokens = tokens(tool.name).toSet();
    final titleTokens = tokens(tool.title ?? '').toSet();
    final descriptionTokens = tokens(
      (tool.description ?? '').length > 240
          ? tool.description!.substring(0, 240)
          : tool.description ?? '',
    ).toSet();
    final props = ((tool.inputSchema['properties'] as Map?) ?? const {}).keys
        .map((k) => '$k')
        .toList();
    final paramTokens = {for (final p in props) ...tokens(p)};

    final caps = <Capability>{};
    for (final entry in _keywords.entries) {
      final strong =
          nameTokens.any(entry.value.contains) ||
          titleTokens.any(entry.value.contains);
      if (strong) caps.add(entry.key);
    }
    // A command-like parameter means the tool runs something, whatever it is
    // called.
    if (props.any((p) => _commandParams.contains(p.toLowerCase())) ||
        paramTokens.any(_commandParams.contains)) {
      caps.add(Capability.execute);
    }
    // A description saying it runs shell commands is also a strong signal.
    final desc = (tool.description ?? '').toLowerCase();
    if (RegExp(r'\b(shell|bash|terminal|command line|run (a |the )?command)')
            .hasMatch(desc) &&
        !nameTokens.contains('output')) {
      caps.add(Capability.execute);
    }
    // Read-only tools that take nothing are typically "tell me about X".
    if (tool.isReadOnly &&
        ((tool.inputSchema['required'] as List?) ?? const []).isEmpty &&
        props.length <= 1 &&
        caps.isEmpty) {
      caps.add(Capability.explore);
    }
    // "open"/"get" alone is navigation/reading; destructive names win over
    // a generic read verb so we do not call `delete_file` a reader.
    if (caps.contains(Capability.delete) || caps.contains(Capability.write)) {
      if (!nameTokens.contains('get') && !nameTokens.contains('read')) {
        caps.remove(Capability.read);
      }
    }
    if (caps.isEmpty) {
      caps.add(tool.isReadOnly ? Capability.read : Capability.write);
    }

    final pathArgs = <String>[
      for (final p in props)
        if (tokens(p).any(_pathWords.contains)) p,
    ];

    return ToolInsight(
      exposedName: exposedName,
      serverName: serverName,
      tool: tool,
      capabilities: caps,
      pathArgs: pathArgs,
      words: {
        ...nameTokens,
        ...titleTokens,
        ...descriptionTokens,
        ...paramTokens,
      },
    );
  }
}

const _stopwords = {
  'a',
  'an',
  'the',
  'to',
  'of',
  'for',
  'in',
  'on',
  'my',
  'me',
  'i',
  'it',
  'is',
  'and',
  'or',
  'with',
  'by',
  'this',
  'that',
  'do',
  'can',
  'you',
  'please',
  'want',
  'need',
  'how',
};

/// All tools the Operator can use, with search and the "by purpose" map.
class ToolIndex {
  ToolIndex(this.entries);

  final List<ToolInsight> entries;

  bool get isEmpty => entries.isEmpty;

  List<ToolInsight> withCapability(Capability c, {String? except}) => [
    for (final e in entries)
      if (e.capabilities.contains(c) && e.exposedName != except) e,
  ];

  ToolInsight? byName(String exposedName) {
    for (final e in entries) {
      if (e.exposedName == exposedName) return e;
    }
    return null;
  }

  /// Ranks tools against a free-text purpose such as "open a file" or
  /// "list the tables". Uses the same signals as the classifier, so it works
  /// for servers it has never seen.
  List<ToolInsight> find(String purpose, {int limit = 8}) {
    final wanted = [
      for (final t in tokens(purpose))
        if (!_stopwords.contains(t)) t,
    ];
    if (wanted.isEmpty) return const [];
    final scored = <(ToolInsight, double)>[];
    for (final e in entries) {
      var score = 0.0;
      final nameTokens = tokens(e.tool.name).toSet();
      final serverCompact = e.serverName.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      for (final w in wanted) {
        if (nameTokens.contains(w)) {
          score += 3;
        } else if (nameTokens.any((n) => _related(n, w))) {
          score += 1.5;
        } else if (e._words.contains(w)) {
          score += 1;
        }
        // The word names a capability this tool has ("run", "search", …).
        for (final cap in e.capabilities) {
          if (_keywords[cap]!.contains(w)) score += 1.5;
        }
        // "github" must match a server called "GitHub", which tokenises to
        // "git" + "hub", so compare the compacted name as well.
        if (w.length >= 3 && serverCompact.contains(w)) score += 1;
      }
      if (score > 0) scored.add((e, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final s in scored.take(limit)) s.$1];
  }
}

/// The "tools by purpose" section appended to the system prompt. Only tool
/// *names* (sanitised by the toolbox) and labels we compute are included, never
/// free text from servers, so a server cannot smuggle instructions into the
/// system prompt through its descriptions.
String buildCapabilityMap(ToolIndex index, {int perLine = 6}) {
  if (index.isEmpty) return '';
  String names(List<ToolInsight> list) {
    final shown = list.take(perLine).map((e) => e.exposedName).join(', ');
    return list.length > perLine
        ? '$shown (+${list.length - perLine} more)'
        : shown;
  }

  final lines = <String>[];
  void line(String label, Capability c, {String? note}) {
    final list = index.withCapability(c);
    if (list.isEmpty) return;
    lines.add('- $label${note == null ? '' : ' ($note)'}: ${names(list)}');
  }

  line(
    'Explore & find',
    Capability.explore,
    note: 'use these when you are missing a path, id or name',
  );
  line(
    'Run commands',
    Capability.execute,
    note: 'ls, pwd, find, grep and similar',
  );
  line('Terminals', Capability.terminal);
  line('Read', Capability.read);
  line('Create / change', Capability.write);
  line('Open / navigate', Capability.navigate);
  line('Diagnostics & code intelligence', Capability.diagnose);
  line('Version control', Capability.vcs);
  line('Web & network', Capability.web);
  line('Data & databases', Capability.data);
  line('Delete / stop', Capability.delete);

  final terminals = index.withCapability(Capability.terminal);
  return [
    'Your tools by purpose (call them by these exact names; use '
        'mcpm_find_tools if you are unsure which one fits):',
    ...lines,
    if (terminals.length >= 2)
      'Terminal tools usually work in steps: start a terminal, send the '
          'command, read its output, then close it.',
  ].join('\n');
}

/// What to tell the model after a tool call failed, so it fixes the problem
/// itself instead of giving up. Generic: it looks at the error text and at
/// which arguments were used, and points at the tools that can help.
class ToolAdvisor {
  ToolAdvisor(this.index);

  final ToolIndex index;
  final _failures = <String, int>{};

  /// Forget earlier failures (a new user request starts fresh).
  void reset() => _failures.clear();

  void recordSuccess(String toolName) => _failures.remove(toolName);

  static final _notFound = RegExp(
    r"(not found|no such|does not exist|doesn't exist|enoent|cannot find|can't find|unable to find|couldn't find|could not find|invalid (file )?path|unknown (file|path)|\b404\b|is not a (file|directory)|outside (of )?(the )?workspace)",
    caseSensitive: false,
  );
  static final _denied = RegExp(
    r'(permission denied|eacces|forbidden|unauthori[sz]ed|access denied|not allowed|\b40[13]\b)',
    caseSensitive: false,
  );
  static final _badArgs = RegExp(
    r'(invalid (argument|param|input|value)|missing (required )?(argument|param|field)|required|validation|expected .{0,30}(string|number|object|array|boolean)|-32602|must be)',
    caseSensitive: false,
  );
  static final _transient = RegExp(
    r'(timed out|timeout|econnrefused|connection (refused|closed|reset)|could not reach|not connected|network)',
    caseSensitive: false,
  );

  /// Returns guidance for a failed call, or null if there is nothing useful to
  /// add. [args] are the arguments the model used.
  String? hintFor(String toolName, Json args, String error) {
    final failures = (_failures[toolName] ?? 0) + 1;
    _failures[toolName] = failures;

    final insight = index.byName(toolName);
    final lines = <String>[
      'MCP Manager hint (not part of the tool output): the call to '
          '$toolName failed (failure $failures for this tool in this request).',
    ];

    if (failures >= 3) {
      lines.add(
        'Stop retrying this. Tell the user what you tried, what failed, and '
        'what you need from them.',
      );
      return lines.join('\n');
    }

    if (_denied.hasMatch(error)) {
      lines.add(
        'This is an access problem, not a mistake in the arguments. Do not '
        'retry the same call; explain it to the user.',
      );
      return lines.join('\n');
    }
    if (_transient.hasMatch(error)) {
      lines.add(
        'This looks temporary. You may retry once; if it fails again, report '
        'it to the user.',
      );
      return lines.join('\n');
    }

    lines.add(
      'Do not give up or ask the user yet. Work out what you are missing and '
      'find it yourself, then retry.',
    );

    final explore = [
      for (final e in index.withCapability(
        Capability.explore,
        except: toolName,
      ))
        if (e.readOnly) e,
    ];
    final run = index.withCapability(Capability.execute, except: toolName);
    String names(List<ToolInsight> list) =>
        list.take(4).map((e) => e.exposedName).join(', ');

    if (_notFound.hasMatch(error) &&
        insight != null &&
        insight.pathArgs.isNotEmpty) {
      final used = [
        for (final p in insight.pathArgs)
          if (args[p] != null) '"$p" = ${_show(args[p])}',
      ];
      lines.add(
        'The location you gave (${used.isEmpty ? insight.pathArgs.join(', ') : used.join(', ')}) '
        'was probably wrong: relative or guessed paths often fail, and a bare '
        'file name does not say which folder it is in.',
      );
      final steps = <String>[];
      if (explore.isNotEmpty) {
        steps.add(
          'ask what the workspace/root is and search or list for the name using '
          '${names(explore)}',
        );
      }
      if (run.isNotEmpty) {
        steps.add(
          'or run `pwd`, `ls` or `find . -name "<name>"` with ${names(run)}',
        );
      }
      if (steps.isNotEmpty) {
        lines.add('Find the real location: ${steps.join('; ')}.');
      } else {
        lines.add(
          'Try other forms of the path (absolute, from the workspace root) or '
          'check the exact name with the user only if nothing else works.',
        );
      }
      lines.add('Then retry with the full path you found.');
    } else if (_badArgs.hasMatch(error)) {
      lines.add(
        'The arguments were probably wrong or incomplete. Call '
        'mcpm_get_tool_schema for this tool to see exactly what it needs, fix '
        'the arguments, and retry.',
      );
    } else {
      lines.add(
        'Read the error, decide what is missing or wrong, and try a different '
        'approach'
        '${explore.isEmpty ? '' : ' (for example look things up with ${names(explore)})'}'
        '. Use mcpm_find_tools if another tool would do this better.',
      );
    }
    lines.add('Only ask the user once you have tried and cannot find it.');
    return lines.join('\n');
  }

  String _show(Object? v) {
    final s = '$v';
    return s.length > 60 ? '"${s.substring(0, 60)}…"' : '"$s"';
  }
}
