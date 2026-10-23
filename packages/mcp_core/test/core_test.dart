import 'package:mcp_core/mcp_core.dart';
import 'package:test/test.dart';

void main() {
  test('the barrel exports what the app and the gateway share', () {
    const config = McpServerConfig(
      id: 's',
      name: 'Docs',
      url: 'https://docs.test/mcp',
      headers: {'Authorization': 'Bearer x'},
    );
    final again = McpServerConfig.fromJson(config.toJson());
    expect(again.url, config.url);
    expect(again.hasStaticAuthorization, isTrue);
    expect(newId('srv'), startsWith('srv_'));
    expect(isValidHttpUrl(normalizeBaseUrl('docs.test/mcp')), isTrue);
  });

  test('previews are redacted JSON that stays valid when shortened', () {
    final preview = redactedPreview({
      'password': 'hunter2',
      'text': 'x' * 5000,
    }, max: 300);
    expect(preview, isNot(contains('hunter2')));
    expect(preview.length, lessThanOrEqualTo(300));
    expect(previewWasShortened(preview), isTrue);
  });

  test('rules reshape a tool without the server knowing', () {
    const server = McpServerConfig(
      id: 's',
      name: 'Docs',
      url: 'https://d.test',
    );
    final tool = McpTool.fromJson({
      'name': 'read',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      },
    });
    final effective = computeEffective(server, tool, [
      const ToolRule(
        id: 'r',
        name: 'Why',
        args: [RuleArg(name: 'reason', required: true)],
      ),
    ], null);
    expect(
      (effective.inputSchema['properties'] as Map).keys,
      contains('reason'),
    );

    final missing = prepareCall(effective, {'path': '/a'});
    expect(missing.error, contains('reason'));
    final ok = prepareCall(effective, {'path': '/a', 'reason': 'because'});
    expect(ok.forwarded, {'path': '/a'});
    expect(ok.context, {'reason': 'because'});
  });
}
