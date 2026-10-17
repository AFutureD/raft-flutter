import 'dart:convert';

/// The most a tool result may weigh once it is JSON (UTF-8 bytes). A voice
/// model reads every byte again on each turn, and a realtime socket is not the
/// place for a page dump, so a larger result is cut down (and says so).
const agentToolOutputLimit = 16 * 1024;

/// A tool result that is safe to put on a realtime socket: only JSON types
/// (maps with string keys, lists, strings, finite numbers, bools, null), no
/// lone UTF-16 surrogates, and at most [limit] bytes of JSON.
class AgentToolOutput {
  const AgentToolOutput({
    required this.result,
    required this.json,
    required this.bytes,
    required this.truncated,
    required this.originalBytes,
  });

  final Map<String, Object?> result;

  /// [result] as JSON text.
  final String json;

  /// Size of [json] in UTF-8 bytes.
  final int bytes;
  final bool truncated;

  /// The size before it was cut down (equals [bytes] when whole).
  final int originalBytes;
}

/// Makes [result] safe for the wire: values that JSON cannot hold (DateTime,
/// BigInt, enums, URIs, objects with `toJson`, NaN) are converted, strings are
/// made valid Unicode, and a result over [limit] bytes is shrunk (long text
/// clipped, long lists shortened, deeper stages as needed) with
/// `truncated: true` and a `truncatedNote` saying what happened. Never throws.
AgentToolOutput guardToolOutput(
  Map<String, Object?> result, {
  int limit = agentToolOutputLimit,
}) {
  Map<String, Object?> safe;
  try {
    safe = _plain(result, 0) as Map<String, Object?>;
  } on Object {
    safe = {'error': '工具的结果无法编码'};
  }
  var json = jsonEncode(safe);
  var bytes = utf8.encode(json).length;
  if (bytes <= limit) {
    return AgentToolOutput(
      result: safe,
      json: json,
      bytes: bytes,
      truncated: false,
      originalBytes: bytes,
    );
  }
  final original = bytes;
  final note =
      '结果太长（约 ${(original / 1024).ceil()} KB），已截短：长文本被截断、长列表只留了前面几项。'
      '要更多请缩小范围再读（比如 read_conversation 指定频道和条数），不要说这就是全部。';
  for (final (strings, items) in const [
    (2000, 40),
    (800, 20),
    (300, 10),
    (120, 5),
    (60, 3),
  ]) {
    final shrunk = _shrink(safe, strings, items) as Map<String, Object?>;
    shrunk['truncated'] = true;
    shrunk['truncatedNote'] = note;
    json = jsonEncode(shrunk);
    bytes = utf8.encode(json).length;
    if (bytes <= limit) {
      return AgentToolOutput(
        result: shrunk,
        json: json,
        bytes: bytes,
        truncated: true,
        originalBytes: original,
      );
    }
  }
  final bare = <String, Object?>{
    'truncated': true,
    'truncatedNote': note,
    'keys': [for (final k in safe.keys.take(20)) _clipText(k, 40)],
  };
  json = jsonEncode(bare);
  return AgentToolOutput(
    result: bare,
    json: json,
    bytes: utf8.encode(json).length,
    truncated: true,
    originalBytes: original,
  );
}

const _maxDepth = 12;

/// [value] as plain JSON data.
Object? _plain(Object? value, int depth) {
  if (value == null || value is bool) return value;
  if (depth > _maxDepth) return '…';
  if (value is String) return _wellFormed(value);
  if (value is num) {
    return value is double && !value.isFinite ? null : value;
  }
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries)
        _wellFormed('${e.key}'): _plain(e.value, depth + 1),
    };
  }
  if (value is Iterable) {
    return [for (final e in value) _plain(e, depth + 1)];
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Duration) return value.inMilliseconds;
  if (value is Enum) return value.name;
  if (value is BigInt || value is Uri) return '$value';
  try {
    // An object that knows its JSON (a model class).
    final json = (value as dynamic).toJson();
    return _plain(json, depth + 1);
  } on Object {
    return _wellFormed('$value');
  }
}

/// [text] with every lone surrogate replaced by U+FFFD (a half of an emoji is
/// not Unicode; some servers drop the connection over it).
String _wellFormed(String text) {
  var i = 0;
  StringBuffer? out;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    final high = unit >= 0xD800 && unit <= 0xDBFF;
    final low = unit >= 0xDC00 && unit <= 0xDFFF;
    final paired =
        high &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xDC00 &&
        text.codeUnitAt(i + 1) <= 0xDFFF;
    if (paired) {
      out?.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (high || low) {
      out ??= StringBuffer(text.substring(0, i));
      out.writeCharCode(0xFFFD);
    } else {
      out?.writeCharCode(unit);
    }
    i++;
  }
  return out?.toString() ?? text;
}

/// [text] cut to [max] UTF-16 units without splitting a surrogate pair.
String _clipText(String text, int max) {
  if (text.length <= max) return text;
  var end = max;
  if (end > 0) {
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xD800 && last <= 0xDBFF) end--;
  }
  return '${text.substring(0, end)}…';
}

Object? _shrink(Object? value, int strings, int items) {
  if (value is String) return _clipText(value, strings);
  if (value is Map) {
    return <String, Object?>{
      for (final e in value.entries) e.key: _shrink(e.value, strings, items),
    };
  }
  if (value is List) {
    return [for (final e in value.take(items)) _shrink(e, strings, items)];
  }
  return value;
}
