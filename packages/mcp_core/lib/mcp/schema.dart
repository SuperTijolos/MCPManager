import '../core/json.dart';

/// Builds a starting-point arguments object for a tool's JSON Schema so the
/// workbench can offer an editable template. Required properties and those
/// with defaults are filled; optional ones are left out.
Json skeletonFromSchema(Json schema) {
  final value = _valueFor(schema, 0);
  return value is Map<String, dynamic> ? value : <String, dynamic>{};
}

Object? _valueFor(Object? raw, int depth) {
  if (raw is! Map || depth > 4) return null;
  final schema = raw.cast<String, dynamic>();
  if (schema.containsKey('default')) return schema['default'];
  final enumValues = schema['enum'];
  if (enumValues is List && enumValues.isNotEmpty) return enumValues.first;
  if (schema.containsKey('const')) return schema['const'];

  var type = schema['type'];
  if (type is List) {
    type = type.firstWhere((t) => t != 'null', orElse: () => null);
  }
  if (type == null) {
    for (final key in ['anyOf', 'oneOf']) {
      final options = schema[key];
      if (options is List && options.isNotEmpty) {
        return _valueFor(options.first, depth + 1);
      }
    }
    if (schema.containsKey('properties')) type = 'object';
  }

  switch (type) {
    case 'object':
      final properties =
          (schema['properties'] as Map?)?.cast<String, dynamic>() ?? {};
      final required = ((schema['required'] as List?) ?? const [])
          .cast<String>()
          .toSet();
      final out = <String, dynamic>{};
      for (final entry in properties.entries) {
        final hasDefault =
            entry.value is Map && (entry.value as Map).containsKey('default');
        if (required.contains(entry.key) || hasDefault) {
          out[entry.key] = _valueFor(entry.value, depth + 1);
        }
      }
      return out;
    case 'string':
      return '';
    case 'integer':
    case 'number':
      return 0;
    case 'boolean':
      return false;
    case 'array':
      return <Object?>[];
    default:
      return null;
  }
}
