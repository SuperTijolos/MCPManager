enum DiffKind { same, added, removed }

class DiffLine {
  const DiffLine(this.kind, this.text);
  final DiffKind kind;
  final String text;
}

/// A line-by-line diff of [before] and [after] (longest common subsequence),
/// small and dependency-free: it is used to compare a tool's original schema
/// with what the Operator sees.
List<DiffLine> lineDiff(String before, String after) {
  final a = before.isEmpty ? <String>[] : before.split('\n');
  final b = after.isEmpty ? <String>[] : after.split('\n');
  // lcs[i][j] = length of the LCS of a[i:] and b[j:].
  final lcs = List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
  for (var i = a.length - 1; i >= 0; i--) {
    for (var j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = <DiffLine>[];
  var i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      out.add(DiffLine(DiffKind.same, a[i]));
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.add(DiffLine(DiffKind.removed, a[i++]));
    } else {
      out.add(DiffLine(DiffKind.added, b[j++]));
    }
  }
  while (i < a.length) {
    out.add(DiffLine(DiffKind.removed, a[i++]));
  }
  while (j < b.length) {
    out.add(DiffLine(DiffKind.added, b[j++]));
  }
  return out;
}
