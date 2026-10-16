import 'dart:async';

import 'package:flutter/foundation.dart';

/// What the agent is doing, for the mood badge: the app derives it from the
/// voice session and the tools that run, so waiting is never blank.
enum AgentMoodPhase { listening, thinking, reading, composing, speaking, idle }

/// The emoji of each phase.
const agentMoodByPhase = {
  AgentMoodPhase.listening: '👂',
  AgentMoodPhase.thinking: '🤔',
  AgentMoodPhase.reading: '🔎',
  AgentMoodPhase.composing: '✍️',
  AgentMoodPhase.speaking: '🗣️',
  AgentMoodPhase.idle: '🙂',
};

/// What the badge says to a screen reader.
const agentMoodLabels = {
  AgentMoodPhase.listening: '在听',
  AgentMoodPhase.thinking: '在想',
  AgentMoodPhase.reading: '在查数据',
  AgentMoodPhase.composing: '在整理屏幕',
  AgentMoodPhase.speaking: '在说',
  AgentMoodPhase.idle: '待命',
};

/// The moods the model may set with `set_mood`: friendly, one grapheme each.
const agentMoodAllowlist = [
  '😄', '😊', '🙂', '😌', '😎', '🤔', '🧐', '😮', '😅', '😬', //
  '😟', '😕', '😴', '🥳', '🤩', '🎉', '👀', '💪', '🙌', '👍',
  '🤝', '🙏', '☕', '🔥', '✅', '⚠️', '💡', '🚀', '🎯', '🧩',
];

/// [agentMoodAllowlist] as the model reads it (a test keeps them equal).
const agentMoodAllowlistText =
    '😄 😊 🙂 😌 😎 🤔 🧐 😮 😅 😬 😟 😕 😴 🥳 🤩 🎉 👀 💪 🙌 👍 🤝 🙏 ☕ 🔥 ✅ ⚠️ 💡 🚀 🎯 🧩';

String _bare(String s) => s.replaceAll('️', '');

/// The allowlist entry [input] means (a model may drop the variation
/// selector of ⚠️), or null.
String? agentMoodMatch(String input) {
  final wanted = _bare(input.trim());
  if (wanted.isEmpty) return null;
  for (final e in agentMoodAllowlist) {
    if (_bare(e) == wanted) return e;
  }
  return null;
}

/// The emoji the badge shows, and why.
///
/// The phase decides it by default. The model may override it with
/// [setMood] (sparingly: once per turn), which holds for [overrideFor] or
/// until the phase changes. Whatever is wanted, the visible emoji changes at
/// most once per [throttle]; a change asked for meanwhile waits and then the
/// latest wanted one is shown.
class AgentMoodController extends ChangeNotifier {
  AgentMoodController({
    this.overrideFor = const Duration(seconds: 6),
    this.throttle = const Duration(milliseconds: 600),
  });

  final Duration overrideFor, throttle;

  AgentMoodPhase _phase = AgentMoodPhase.idle;
  String? _override;
  String? _reason;
  bool _moodThisTurn = false;
  String _shown = agentMoodByPhase[AgentMoodPhase.idle]!;
  bool _cooling = false;
  Timer? _cool, _expire;
  bool _disposed = false;

  /// What the badge shows now.
  String get emoji => _shown;
  AgentMoodPhase get phase => _phase;

  /// The mood the model set, while it holds.
  String? get moodOverride => _override;
  String? get reason => _reason;

  /// What the badge says to a screen reader.
  String get label => _override == null ? agentMoodLabels[_phase]! : '心情';

  String get _target => _override ?? agentMoodByPhase[_phase]!;

  /// The agent is in [next]. A different phase ends a mood the model set.
  void setPhase(AgentMoodPhase next) {
    if (next == _phase) return;
    _phase = next;
    _clearOverride();
    _publish();
  }

  /// A new turn (the person spoke or typed): the model may set a mood again.
  void newTurn() => _moodThisTurn = false;

  /// `set_mood`: validates and applies. Returns the tool result.
  Map<String, Object?> setMood(Object? emoji, Object? reason) {
    final text = emoji is String ? emoji.trim() : '';
    final matched = agentMoodMatch(text);
    if (matched == null) {
      return {'error': 'emoji 必须是列表里的一个（只能一个）', 'allowed': agentMoodAllowlist};
    }
    if (_moodThisTurn) {
      return {'error': '这一轮已经设过心情了，不要连着用'};
    }
    _moodThisTurn = true;
    _override = matched;
    _reason = reason is String && reason.trim().isNotEmpty
        ? reason.trim()
        : null;
    _expire?.cancel();
    _expire = Timer(overrideFor, () {
      if (_disposed) return;
      _clearOverride();
      _publish();
    });
    _publish();
    return {'ok': true, 'emoji': matched};
  }

  void _clearOverride() {
    _override = null;
    _reason = null;
    _expire?.cancel();
    _expire = null;
  }

  void _publish() {
    if (_target == _shown) return;
    if (_cooling) return; // The latest wanted one is shown when it ends.
    _show();
  }

  void _show() {
    _shown = _target;
    _cooling = true;
    _cool?.cancel();
    _cool = Timer(throttle, () {
      _cooling = false;
      if (!_disposed && _target != _shown) _show();
    });
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cool?.cancel();
    _expire?.cancel();
    super.dispose();
  }
}
