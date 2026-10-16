import 'dart:async';
import 'dart:convert';

import 'gemini_text.dart';

/// What the summarizer is told about one card.
class AgentHeadlineRequest {
  const AgentHeadlineRequest({
    required this.id,
    required this.version,
    required this.kind,
    required this.text,
    required this.ask,
    required this.wait,
    this.doer,
    this.quote,
  });

  final String id;

  /// Changes when the thing behind the card changes (its `updatedAt`), so a
  /// cached sentence is reused only while it is still true.
  final String version;

  /// `decision`, `blocked` or `mention`.
  final String kind;

  /// Title and description, or the message that mentions the person.
  final String text;
  final String ask, wait;
  final String? doer, quote;

  String get cacheKey => '$id@$version';

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'doer': doer,
    'text': text,
    'ask': ask,
    'wait': wait,
    if (quote != null) 'latest': quote,
  };
}

/// Writes the sentence on each attention card: who did what, what is asked.
///
/// A batch in, the sentences it could write out by request id. Cards it
/// returns nothing for keep the rule writer's sentence ([RuleHeadlineWriter]),
/// so a missing key, no network or a bad reply never leaves a card blank.
abstract interface class AgentHeadlineSummarizer {
  Future<Map<String, String>> summarize(List<AgentHeadlineRequest> requests);
}

/// Sends text to a model: the system instruction and the prompt in, the reply
/// out; null when no model can be reached (no key).
typedef AgentTextGenerator = Future<String?> Function(
  String system,
  String prompt,
);

/// One model request per batch, an answer remembered per task id + updatedAt.
class ModelHeadlineSummarizer implements AgentHeadlineSummarizer {
  ModelHeadlineSummarizer({
    required this.generate,
    DateTime Function()? now,
    this.cacheLimit = 300,
    this.retryAfter = const Duration(seconds: 30),
  }) : _now = now ?? DateTime.now;

  /// The summarizer used by the app: Gemini over REST with the stored key.
  factory ModelHeadlineSummarizer.gemini() =>
      ModelHeadlineSummarizer(generate: GeminiText.instance.generate);

  final AgentTextGenerator generate;
  final DateTime Function() _now;
  final int cacheLimit;

  /// After a failed request, the next one waits this long.
  final Duration retryAfter;

  final _cache = <String, String>{};
  DateTime? _failedAt;
  Future<void>? _inFlight;

  /// Number of model requests made, for tests and diagnostics.
  int requests = 0;

  static const system =
      '你是 Raft 里替用户先读一遍的助手。下面是一批需要用户关注的事项。'
      '为每一项写一句中文标题，格式是“谁做了什么，要你做什么”：\n'
      '- 主语是做事的人或 agent（doer），没有就写“有人”；动词要具体（完成了、提交了、问了、卡住了），不要写“任务”这种空话。\n'
      '- 结尾写出用户要做的事（ask），如“等你验收”“请你确认”“需要你解除阻塞”“请你回答”。\n'
      '- 卡住的事写清楚卡了多久（wait）。\n'
      '- 只用给出的信息，不要编造；一句话，不超过 40 个字；不要 Markdown、引号、@。\n'
      '只返回 JSON 数组：[{"id":"…","headline":"…"}]，id 与输入一一对应。';

  @override
  Future<Map<String, String>> summarize(
    List<AgentHeadlineRequest> requests,
  ) async {
    // An earlier batch still running may be about the same cards.
    final running = _inFlight;
    if (running != null) await running;
    final missing = [
      for (final r in requests)
        if (!_cache.containsKey(r.cacheKey)) r,
    ];
    if (missing.isNotEmpty && !_cooling) {
      final batch = _fill(missing);
      _inFlight = batch;
      try {
        await batch;
      } finally {
        if (identical(_inFlight, batch)) _inFlight = null;
      }
    }
    return {
      for (final r in requests)
        if (_cache[r.cacheKey] != null) r.id: _cache[r.cacheKey]!,
    };
  }

  bool get _cooling {
    final failed = _failedAt;
    return failed != null && _now().difference(failed) < retryAfter;
  }

  Future<void> _fill(List<AgentHeadlineRequest> batch) async {
    try {
      requests++;
      final reply = await generate(
        system,
        jsonEncode([for (final r in batch) r.toJson()]),
      );
      if (reply == null) {
        _failedAt = _now();
        return;
      }
      final got = parseHeadlines(reply, {for (final r in batch) r.id: r});
      if (got.isEmpty) {
        _failedAt = _now();
        return;
      }
      _failedAt = null;
      for (final e in got.entries) {
        _cache[e.key.cacheKey] = e.value;
      }
      while (_cache.length > cacheLimit) {
        _cache.remove(_cache.keys.first);
      }
    } on Object {
      // Offline, refused, malformed: the rule sentences stay.
      _failedAt = _now();
    }
  }

  /// The replies that name a requested id and read like a headline.
  static Map<AgentHeadlineRequest, String> parseHeadlines(
    String reply,
    Map<String, AgentHeadlineRequest> asked,
  ) {
    var text = reply.trim();
    final fence = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$').firstMatch(text);
    if (fence != null) text = fence[1]!;
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException {
      return const {};
    }
    final rows = json is Map ? json['headlines'] : json;
    if (rows is! List) return const {};
    final out = <AgentHeadlineRequest, String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final request = asked['${row['id']}'];
      final line = row['headline'];
      if (request == null || line is! String) continue;
      final clean = line.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (clean.isEmpty || clean.length > 90) continue;
      out[request] = clean;
    }
    return out;
  }
}
