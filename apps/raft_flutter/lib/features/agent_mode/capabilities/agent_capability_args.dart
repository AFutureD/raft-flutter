/// The arguments of a call, checked against the capability's JSON Schema.
///
/// A deliberate subset (type, enum, required, minimum/maximum, maxLength,
/// items, default): what the schemas in the registry use. A model that sends
/// `"5"` for an integer or `"true"` for a boolean is understood; an argument
/// the schema does not know is refused, never ignored, so a misspelt filter
/// cannot quietly widen a query.
class AgentArgsCheck {
  const AgentArgsCheck(this.args, this.problems);

  /// The arguments with defaults filled in and values coerced.
  final Map<String, Object?> args;

  /// What is wrong, one sentence each, naming the argument.
  final List<String> problems;

  bool get ok => problems.isEmpty;
}

AgentArgsCheck checkAgentArgs(Map<String, Object?> schema, Object? given) {
  final problems = <String>[];
  final raw = given is Map
      ? Map<String, Object?>.from(given)
      : <String, Object?>{};
  if (given != null && given is! Map) problems.add('args 必须是对象');
  final props = (schema['properties'] as Map?)?.cast<String, Object?>() ?? {};
  final out = <String, Object?>{};

  for (final key in raw.keys) {
    if (!props.containsKey(key)) {
      problems.add('未知参数 $key（可用：${props.keys.join('、')}）');
    }
  }
  for (final entry in props.entries) {
    final spec = (entry.value as Map).cast<String, Object?>();
    final value = raw[entry.key];
    if (value == null || (value is String && value.trim().isEmpty)) {
      if (spec.containsKey('default')) out[entry.key] = spec['default'];
      continue;
    }
    final checked = _value(entry.key, spec, value, problems);
    if (checked != null) out[entry.key] = checked;
  }
  for (final name in (schema['required'] as List?) ?? const []) {
    final v = out[name];
    if (v == null || (v is String && v.trim().isEmpty)) {
      problems.add('缺少参数 $name');
    }
  }
  return AgentArgsCheck(out, problems);
}

Object? _value(
  String name,
  Map<String, Object?> spec,
  Object? value,
  List<String> problems,
) {
  switch (spec['type']) {
    case 'string':
      final s = value is String
          ? value.trim()
          : (value is num || value is bool ? '$value' : null);
      if (s == null) {
        problems.add('$name 必须是文字');
        return null;
      }
      final max = spec['maxLength'];
      if (max is int && s.length > max) {
        problems.add('$name 最长 $max 个字');
        return null;
      }
      final choices = spec['enum'];
      if (choices is List && !choices.contains(s)) {
        problems.add('$name 必须是 ${choices.join(' / ')} 之一，不是“$s”');
        return null;
      }
      return s;
    case 'integer' || 'number':
      final n = value is num
          ? value
          : value is String
          ? num.tryParse(value.replaceAll(RegExp(r'^#'), '').trim())
          : null;
      if (n == null || !n.isFinite) {
        problems.add('$name 必须是数字');
        return null;
      }
      if (spec['type'] == 'integer' && n != n.truncate()) {
        problems.add('$name 必须是整数');
        return null;
      }
      final min = spec['minimum'], max = spec['maximum'];
      if (min is num && n < min) {
        problems.add('$name 不能小于 $min');
        return null;
      }
      if (max is num && n > max) {
        problems.add('$name 不能大于 $max');
        return null;
      }
      return spec['type'] == 'integer' ? n.toInt() : n;
    case 'boolean':
      if (value is bool) return value;
      if (value == 'true') return true;
      if (value == 'false') return false;
      problems.add('$name 必须是 true 或 false');
      return null;
    case 'array':
      if (value is! List) {
        problems.add('$name 必须是列表');
        return null;
      }
      final item = (spec['items'] as Map?)?.cast<String, Object?>();
      return [
        for (final (i, v) in value.indexed)
          if (item == null) v else _value('$name[$i]', item, v, problems),
      ];
    default:
      return value;
  }
}
