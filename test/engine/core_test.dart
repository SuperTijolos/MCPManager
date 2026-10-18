import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/core/redact.dart';
import 'package:mcp_manager/engine/core/url.dart';
import 'package:mcp_manager/engine/mcp/headers.dart';
import 'package:mcp_manager/engine/mcp/schema.dart';

void main() {
  group('normalizeBaseUrl', () {
    test('adds a scheme and strips inline comments and trailing slashes', () {
      expect(
        normalizeBaseUrl('100.76.81.95:11434 # endereço'),
        'http://100.76.81.95:11434',
      );
      expect(normalizeBaseUrl('  https://host/v1/  '), 'https://host/v1');
      expect(normalizeBaseUrl('localhost:11434'), 'http://localhost:11434');
      expect(normalizeBaseUrl('   '), '');
    });

    test('isValidHttpUrl', () {
      expect(isValidHttpUrl('http://a.b:1'), isTrue);
      expect(isValidHttpUrl('ftp://a.b'), isFalse);
      expect(isValidHttpUrl('http://'), isFalse);
      expect(isValidHttpUrl(''), isFalse);
    });

    test('isValidHttpUrl rejects junk hosts that Uri.parse tolerates', () {
      expect(isValidHttpUrl('http://not a url!!'), isFalse);
      expect(isValidHttpUrl('http://a b.test/mcp'), isFalse);
      expect(isValidHttpUrl('http://exa!mple.test'), isFalse);
      expect(isValidHttpUrl('http://-bad.test'), isFalse);
      expect(isValidHttpUrl('https://mcp.example.com/mcp?x=1'), isTrue);
      expect(isValidHttpUrl('http://localhost:8765/mcp'), isTrue);
      expect(isValidHttpUrl('http://100.100.1.9:8080'), isTrue);
      expect(isValidHttpUrl('http://[::1]:11434'), isTrue);
      expect(isValidHttpUrl('http://my_docker_host:3000'), isTrue);
    });
  });

  group('redact', () {
    test('masks secret-looking keys at any depth', () {
      final out = redact({
        'query': 'hello',
        'apiKey': 'abc',
        'nested': {
          'Authorization': 'Bearer abcdefghijkl',
          'items': [
            {'password': 'x', 'ok': 1},
          ],
        },
      });
      expect(out, {
        'query': 'hello',
        'apiKey': redacted,
        'nested': {
          'Authorization': redacted,
          'items': [
            {'password': redacted, 'ok': 1},
          ],
        },
      });
    });

    test('masks token-shaped strings in free text', () {
      expect(
        redactText('use Bearer abcdefghijklmnop now'),
        'use $redacted now',
      );
      expect(redactText('key sk-abcdefghijklmnopqrstuv'), 'key $redacted');
      expect(redactText('plain text'), 'plain text');
    });

    test('redactedPreview keeps plain strings readable (no JSON quoting)', () {
      expect(redactedPreview('Team registered'), 'Team registered');
      expect(
        redactedPreview('token is Bearer abcdefghijklmnop'),
        'token is $redacted',
      );
    });

    test('redactedPreview truncates', () {
      final preview = redactedPreview({'a': 'x' * 5000}, max: 100);
      expect(preview.length, lessThan(160));
      expect(preview, contains('truncated'));
    });

    test('a long JSON result is shortened inside, so it still parses', () {
      final result = jsonEncode({
        'path': '/home/me/app.dart',
        'content': "import 'dart:async';\n${'line of code\n' * 3000}",
      });
      final preview = redactedPreview(result);

      expect(preview.length, lessThanOrEqualTo(2000));
      final parsed = jsonDecode(preview) as Map;
      expect(parsed['path'], '/home/me/app.dart');
      expect(
        parsed['content'],
        startsWith("import 'dart:async';\nline of code"),
      );
      expect(parsed['content'], contains('[truncated'));
      expect(previewWasShortened(preview), isTrue);
    });

    test('secrets are masked by key in JSON that arrives as text', () {
      final preview = redactedPreview(
        '{"user":"ana","password":"hunter2","nested":{"api_key":"abc"},'
        '"note":"Bearer abcdefghijklmnop"}',
      );
      expect(preview, isNot(contains('hunter2')));
      expect(preview, isNot(contains('abcdefghijklmnop')));
      final parsed = jsonDecode(preview) as Map;
      expect(parsed['user'], 'ana');
      expect(parsed['password'], redacted);
      expect((parsed['nested'] as Map)['api_key'], redacted);
    });

    test('long lists are cut with a count', () {
      final preview = redactedPreview(
        jsonEncode([for (var i = 0; i < 500; i++) 'item number $i']),
        max: 600,
      );
      final parsed = jsonDecode(preview) as List;
      expect(parsed.length, 21);
      expect(parsed.last, contains('480 more items'));
    });

    test('text that only looks like JSON is treated as text', () {
      expect(redactedPreview('{not json'), '{not json');
      expect(previewWasShortened('plain'), isFalse);
      expect(previewWasShortened(redactedPreview('x' * 3000)), isTrue);
    });
  });

  group('headers', () {
    test('parse and format round-trip', () {
      final parsed = parseHeaderLines('X-Api-Key: abc\n\nAccept: text/plain');
      expect(parsed, {'X-Api-Key': 'abc', 'Accept': 'text/plain'});
      expect(formatHeaderLines(parsed!), 'X-Api-Key: abc\nAccept: text/plain');
    });

    test('rejects malformed lines', () {
      String? bad;
      expect(parseHeaderLines('nonsense', onError: (l) => bad = l), isNull);
      expect(bad, 'nonsense');
    });

    test('keeps colons inside values', () {
      expect(parseHeaderLines('Referer: http://x.y:80/'), {
        'Referer': 'http://x.y:80/',
      });
    });
  });

  group('skeletonFromSchema', () {
    test('fills required and defaulted properties only', () {
      final skeleton = skeletonFromSchema({
        'type': 'object',
        'required': ['city', 'days'],
        'properties': {
          'city': {'type': 'string'},
          'days': {'type': 'integer'},
          'units': {
            'type': 'string',
            'enum': ['c', 'f'],
            'default': 'c',
          },
          'verbose': {'type': 'boolean'},
          'tags': {'type': 'array'},
        },
      });
      expect(skeleton, {'city': '', 'days': 0, 'units': 'c'});
    });

    test('handles nested objects and anyOf', () {
      final skeleton = skeletonFromSchema({
        'type': 'object',
        'required': ['filter'],
        'properties': {
          'filter': {
            'type': 'object',
            'required': ['q'],
            'properties': {
              'q': {
                'anyOf': [
                  {'type': 'string'},
                  {'type': 'null'},
                ],
              },
            },
          },
        },
      });
      expect(skeleton, {
        'filter': {'q': ''},
      });
    });

    test('empty for non-object schemas', () {
      expect(skeletonFromSchema({'type': 'string'}), isEmpty);
    });
  });
}
