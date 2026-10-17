import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_manager/engine/core/line_diff.dart';

String show(List<DiffLine> d) => d
    .map(
      (l) =>
          switch (l.kind) {
            DiffKind.same => '  ',
            DiffKind.added => '+ ',
            DiffKind.removed => '- ',
          } +
          l.text,
    )
    .join('\n');

void main() {
  test('identical text is all "same"', () {
    final d = lineDiff('a\nb\nc', 'a\nb\nc');
    expect(d.every((l) => l.kind == DiffKind.same), isTrue);
    expect(d, hasLength(3));
  });

  test('added lines', () {
    expect(show(lineDiff('a\nc', 'a\nb\nc')), '  a\n+ b\n  c');
  });

  test('removed lines', () {
    expect(show(lineDiff('a\nb\nc', 'a\nc')), '  a\n- b\n  c');
  });

  test('a changed line is a removal and an addition', () {
    expect(show(lineDiff('a\nold\nc', 'a\nnew\nc')), '  a\n- old\n+ new\n  c');
  });

  test('empty sides', () {
    expect(show(lineDiff('', 'x\ny')), '+ x\n+ y');
    expect(show(lineDiff('x\ny', '')), '- x\n- y');
    expect(lineDiff('', ''), isEmpty);
  });

  test('a schema gaining a property', () {
    const before = '{\n  "properties": {\n    "q": {}\n  }\n}';
    const after =
        '{\n  "properties": {\n    "q": {},\n    "reason": {}\n  }\n}';
    final added = lineDiff(
      before,
      after,
    ).where((l) => l.kind == DiffKind.added).map((l) => l.text.trim());
    expect(added, contains('"reason": {}'));
  });

  test('coping with a few hundred lines', () {
    final a = List.generate(400, (i) => 'line $i').join('\n');
    final b = List.generate(
      400,
      (i) => i == 200 ? 'changed' : 'line $i',
    ).join('\n');
    final d = lineDiff(a, b);
    expect(d.where((l) => l.kind != DiffKind.same), hasLength(2));
  });
}
