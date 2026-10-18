import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/audit/audit_text.dart';

void main() {
  group('parsePreview', () {
    test('reads ordinary JSON', () {
      expect(parsePreview('{"a":1,"b":[true,null]}'), {
        'a': 1,
        'b': [true, null],
      });
      expect(parsePreview('[1,2]'), [1, 2]);
    });

    test('is null for text that is not JSON', () {
      expect(parsePreview('plain words'), isNull);
      expect(parsePreview('{not json'), isNull);
      expect(parsePreview(''), isNull);
    });

    test('repairs a result an older version cut in the middle of a string', () {
      const cut =
          r'{"path":"/home/me/app.dart","content":"import \"a\";\nclass A {\n  int x;\n'
          '… [truncated 11345 chars]';
      final parsed = parsePreview(cut) as Map;

      expect(parsed['path'], '/home/me/app.dart');
      final content = parsed['content'] as String;
      expect(content, startsWith('import "a";\nclass A {'));
      expect(content, endsWith('… [truncated 11345 chars]'));
    });

    test('closes every bracket that was open at the cut', () {
      final parsed =
          parsePreview('{"a":{"b":[1,2,"x… [truncated 9 chars]') as Map;
      final list = (parsed['a'] as Map)['b'] as List;
      expect(list.take(2), [1, 2]);
      expect(list.last, 'x… [truncated 9 chars]');
    });

    test('copes with a cut right after an escape or inside \\u', () {
      expect(parsePreview(r'{"a":"line\'), {'a': 'line'});
      expect(parsePreview(r'{"a":"snow \u26'), {'a': 'snow '});
    });

    test('copes with a cut after a comma between complete values', () {
      expect(parsePreview('{"a":1,"b":2,'), {'a': 1, 'b': 2});
    });

    test('gives up when a key was left without its value', () {
      expect(parsePreview('{"a":1,"b":'), isNull);
    });
  });

  group('hasBulkText', () {
    test('flags long and multi-line strings anywhere inside', () {
      expect(hasBulkText({'a': 'short'}), isFalse);
      expect(hasBulkText({'a': 'two\nlines'}), isTrue);
      expect(hasBulkText({'a': 'x' * 300}), isTrue);
      expect(
        hasBulkText({
          'deep': [
            {'k': 'a\nb'},
          ],
        }),
        isTrue,
      );
    });
  });

  group('readableValue', () {
    test('puts multi-line strings on real lines', () {
      final text = readableValue({
        'path': '/app/main.dart',
        'size': 120,
        'content': "import 'dart:async';\n\nvoid main() {}",
      });
      expect(
        text,
        "path: /app/main.dart\n"
        "size: 120\n"
        "content:\n"
        "  import 'dart:async';\n"
        "\n"
        "  void main() {}",
      );
    });

    test('nests maps and lists', () {
      final text = readableValue({
        'server': {
          'name': 'Docs',
          'tags': ['a', 'b'],
        },
        'items': [
          {'id': 1},
          {'id': 2},
        ],
      });
      expect(
        text,
        'server:\n'
        '  name: Docs\n'
        '  tags:\n'
        '    - a\n'
        '    - b\n'
        'items:\n'
        '  -\n'
        '    id: 1\n'
        '  -\n'
        '    id: 2',
      );
    });

    test('says so when there is nothing', () {
      expect(readableValue(<String, dynamic>{}), '(none)');
      expect(readableValue({'a': <String, dynamic>{}}), 'a: (none)');
      expect(readableValue({'a': <dynamic>[]}), 'a: (none)');
    });

    test('keeps quotes and values of other types', () {
      expect(
        readableValue({'ok': true, 'n': null, 'text': 'say "hi"'}),
        'ok: true\nn: null\ntext: say "hi"',
      );
    });
  });

  group('summarizeResult', () {
    test('describes JSON by its keys, replacing bulk text with a size', () {
      const stored =
          '{"path":"/home/me/app.dart","relativePath":"lib/app.dart",'
          '"content":"import \'dart:async\';\\nclass A {}\\n… [truncated 11345 chars]';
      final line = summarizeResult(stored);
      expect(
        line,
        startsWith('path: /home/me/app.dart · relativePath: lib/app.dart'),
      );
      expect(line, contains('content: 11.4k chars'));
      expect(line, isNot(contains('import')));
    });

    test('keeps a long path readable, and sizes only real bulk text', () {
      final path =
          '/home/luis/Workspace/MCPManager/lib/engine/mcp/mcp_sse_client.dart';
      expect(path.length, greaterThan(60));
      expect(summarizeResult('{"path":"$path"}'), 'path: $path');
      expect(
        summarizeResult('{"text":"${'a sentence ' * 30}"}'),
        matches(RegExp(r'^text: \d+ chars$')),
      );
      expect(summarizeResult('{"text":"${'w' * 150}"}'), 'text: ${'w' * 90}…');
    });

    test('counts nested values and lists', () {
      expect(
        summarizeResult('{"tools":[1,2,3],"meta":{"a":1},"ok":true}'),
        'tools: [3] · meta: {1} · ok: true',
      );
      expect(summarizeResult('[1,2,3]'), '3 items');
      expect(summarizeResult('[1]'), '1 item');
    });

    test('flattens ordinary text and caps the length', () {
      expect(summarizeResult('  a   b\n\nc '), 'a b c');
      final long = summarizeResult('word ' * 100, max: 50);
      expect(long.length, 51);
      expect(long, endsWith('…'));
    });

    test('an empty object is "(empty)"', () {
      expect(summarizeResult('{}'), '(empty)');
    });
  });
}
