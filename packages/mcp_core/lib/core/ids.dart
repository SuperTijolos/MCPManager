import 'dart:math';

final _random = Random();
int _counter = 0;

String newId([String prefix = 'id']) {
  final time = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  final rand = _random.nextInt(1 << 20).toRadixString(36);
  return '${prefix}_$time$rand${(_counter++).toRadixString(36)}';
}
