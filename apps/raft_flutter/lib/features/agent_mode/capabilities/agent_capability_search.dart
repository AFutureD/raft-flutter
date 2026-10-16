import 'dart:math' as math;

import 'agent_capability.dart';

/// `find`: the capabilities most relevant to what the person said.
///
/// BM25 over the id, title and keywords of every capability. Chinese has no
/// spaces, so text is cut into overlapping character pairs (and single
/// characters, which weigh less), Latin text into words. No model is called:
/// the same words always find the same capabilities in the same order.
class AgentCapabilityIndex {
  AgentCapabilityIndex(Iterable<AgentCapability> capabilities) {
    for (final c in capabilities) {
      final tf = <String, double>{};
      void add(String text, double weight) {
        for (final t in _terms(text, doc: true)) {
          tf[t.term] = (tf[t.term] ?? 0) + weight;
        }
      }

      add(c.id.replaceAll('.', ' ').replaceAll('_', ' '), 1);
      add(c.title, 2);
      for (final k in c.keywords) {
        add(k, 3);
      }
      _docs.add(_Doc(c, tf, tf.values.fold(0, (a, b) => a + b)));
    }
    _avg = _docs.isEmpty
        ? 1
        : _docs.fold<double>(0, (a, d) => a + d.length) / _docs.length;
    for (final d in _docs) {
      for (final term in d.tf.keys) {
        _df[term] = (_df[term] ?? 0) + 1;
      }
    }
  }

  static const k1 = 1.2, b = 0.75;

  final _docs = <_Doc>[];
  final _df = <String, int>{};
  late final double _avg;

  /// The best [limit] capabilities for [intent], best first; empty when
  /// nothing shares a word with it. [kind] narrows to queries or actions.
  List<AgentCapability> find(
    String intent, {
    int limit = 5,
    AgentCapabilityKind? kind,
  }) {
    final query = <String, double>{};
    for (final t in _terms(_expand(intent), doc: false)) {
      query[t.term] = math.max(query[t.term] ?? 0, t.weight);
    }
    final n = _docs.length;
    final scored = <(double, int)>[];
    for (final (i, d) in _docs.indexed) {
      if (kind != null && d.capability.kind != kind) continue;
      var score = 0.0;
      for (final q in query.entries) {
        final f = d.tf[q.key];
        if (f == null) continue;
        final df = _df[q.key] ?? 0;
        final idf = math.log(1 + (n - df + .5) / (df + .5));
        score +=
            q.value *
            idf *
            (f * (k1 + 1)) /
            (f + k1 * (1 - b + b * d.length / _avg));
      }
      if (score > 0) scored.add((score, i));
    }
    scored.sort((a, c) {
      final by = c.$1.compareTo(a.$1);
      return by != 0 ? by : a.$2.compareTo(c.$2);
    });
    return [for (final s in scored.take(limit)) _docs[s.$2].capability];
  }

  /// A task number ("#129") means "this task": say so in the words the task
  /// capabilities use.
  static String _expand(String intent) =>
      RegExp(r'#\d+').hasMatch(intent) ? '$intent 任务 编号 详情' : intent;

  static const _stopChars = '的了吗呢啊吧在是有我你他她它把给帮请要想看下上这那个些么什怎样都也就还和与及或';
  static const _stopPairs = {
    '什么',
    '怎么',
    '那个',
    '这个',
    '一下',
    '可以',
    '帮我',
    '给我',
    '告诉',
    '一个',
  };

  static List<({String term, double weight})> _terms(
    String text, {
    required bool doc,
  }) {
    final out = <({String term, double weight})>[];
    for (final m in RegExp(
      r'[a-zA-Z][a-zA-Z0-9]*|[0-9]+|[一-鿿]+',
    ).allMatches(text.toLowerCase())) {
      final s = m[0]!;
      if (RegExp(r'^[一-鿿]').hasMatch(s)) {
        for (var i = 0; i < s.length; i++) {
          final ch = s[i];
          if (!_stopChars.contains(ch)) out.add((term: ch, weight: .35));
          if (i + 1 < s.length) {
            final pair = s.substring(i, i + 2);
            if (!_stopPairs.contains(pair)) out.add((term: pair, weight: 1));
          }
        }
      } else if (s.length > 1 || RegExp(r'\d').hasMatch(s)) {
        out.add((term: s, weight: 1));
      }
    }
    return out;
  }
}

class _Doc {
  _Doc(this.capability, this.tf, this.length);
  final AgentCapability capability;
  final Map<String, double> tf;
  final double length;
}
