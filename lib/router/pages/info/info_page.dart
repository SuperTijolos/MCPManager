import 'package:flutter/material.dart';

import '../../../ui/widgets.dart';

class InfoPage extends StatelessWidget {
  const InfoPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget section(String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(body, style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
        ],
      ),
    );

    return PageScaffold(
      title: 'About MCP Manager',
      subtitle: 'Built for the Hacktober Portimão festival',
      child: ListView(
        children: [
          section(
            'What it is',
            'A control panel for Model Context Protocol servers. Connect servers, '
                'inspect and test their tools, audit every call, and let an operator '
                'model (Gemma 4 through Ollama, or any OpenAI-compatible endpoint) '
                'diagnose and act — with your approval for anything that is not read-only.',
          ),
          section(
            'Servers vs. tools',
            'A server is a downstream MCP integration reached over Streamable HTTP. '
                'Its tools are discovered on connect and can be run from the Tools '
                'workbench or by the Operator.',
          ),
          section(
            'Safety model',
            'Tools are treated as potentially destructive unless the server marks '
                'them readOnly, so they ask for approval before the Operator runs them. '
                'Tool output is passed to the model as untrusted data. Every call is '
                'recorded in the audit log with secrets redacted.',
          ),
          section(
            'Browser limits',
            'This build runs in the browser: only HTTP(S) MCP servers are supported '
                '(no stdio), and servers and Ollama must allow CORS for this origin.',
          ),
        ],
      ),
    );
  }
}
