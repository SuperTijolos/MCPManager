import 'package:flutter/material.dart';

/// A lightweight JSON lexer shared by editable arguments and read-only schema
/// previews. It deliberately handles unfinished input as well as valid JSON,
/// so typing a quote or a partial number never interrupts editing.
abstract final class JsonSyntax {
  static const key = Color(0xFF79C0FF);
  static const string = Color(0xFFA5D6A7);
  static const number = Color(0xFFFFC078);
  static const literal = Color(0xFFD2A8FF);

  static final RegExp _number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );

  static List<TextSpan> spans(String source) {
    final result = <TextSpan>[];
    var cursor = 0;
    var plainStart = 0;

    void flushPlain() {
      if (plainStart < cursor) {
        result.add(TextSpan(text: source.substring(plainStart, cursor)));
      }
    }

    void colorize(int end, Color color) {
      flushPlain();
      result.add(
        TextSpan(
          text: source.substring(cursor, end),
          style: TextStyle(color: color),
        ),
      );
      cursor = end;
      plainStart = end;
    }

    while (cursor < source.length) {
      if (source.codeUnitAt(cursor) == 0x22) {
        // Strings may contain escaped quotes/backslashes; an unterminated
        // string is colored through the end of the document during editing.
        var end = cursor + 1;
        var escaped = false;
        var closed = false;
        while (end < source.length) {
          final char = source.codeUnitAt(end++);
          if (escaped) {
            escaped = false;
          } else if (char == 0x5c) {
            escaped = true;
          } else if (char == 0x22) {
            closed = true;
            break;
          }
        }
        var next = end;
        while (next < source.length &&
            (source.codeUnitAt(next) == 0x20 ||
                source.codeUnitAt(next) == 0x09 ||
                source.codeUnitAt(next) == 0x0a ||
                source.codeUnitAt(next) == 0x0d)) {
          next++;
        }
        colorize(
          end,
          closed && next < source.length && source.codeUnitAt(next) == 0x3a
              ? key
              : string,
        );
        continue;
      }

      final code = source.codeUnitAt(cursor);
      if ((code >= 0x30 && code <= 0x39) || code == 0x2d) {
        final match = _number.matchAsPrefix(source, cursor);
        if (match != null) {
          colorize(match.end, number);
          continue;
        }
      }

      var matchedLiteral = false;
      for (final word in const ['true', 'false', 'null']) {
        if (!source.startsWith(word, cursor)) continue;
        final end = cursor + word.length;
        if (end < source.length &&
            _identifierCharacter(source.codeUnitAt(end))) {
          continue;
        }
        // Avoid highlighting a word in the middle of malformed identifiers.
        if (cursor > 0 && _identifierCharacter(source.codeUnitAt(cursor - 1))) {
          continue;
        }
        colorize(end, literal);
        matchedLiteral = true;
        break;
      }
      if (matchedLiteral) continue;
      cursor++;
    }
    flushPlain();
    return result;
  }

  static bool _identifierCharacter(int char) =>
      (char >= 0x41 && char <= 0x5a) ||
      (char >= 0x61 && char <= 0x7a) ||
      (char >= 0x30 && char <= 0x39) ||
      char == 0x5f;

  static TextSpan highlight(String text) => TextSpan(children: spans(text));
}

/// Syntax-colored JSON without replacing the regular Flutter text editor.
/// Selection, clipboard, undo/redo, accessibility and keyboard shortcuts are
/// still handled by EditableText. Use the framework's composing underline
/// while an input method is actively composing text.
class JsonEditingController extends TextEditingController {
  JsonEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (withComposing &&
        value.composing.isValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(style: style, children: JsonSyntax.spans(text));
  }
}
