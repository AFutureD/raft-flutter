import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

/// The one owner of what moves on the screen while the agent talks.
///
/// A visual that belongs to words (a spotlight, a mark, the typing of a
/// headline) waits until the speaker has played those words; the spotlight
/// travels along the stream: an item added while the agent speaks enters
/// straight into the spotlight, and settles into its reserved slot when the
/// agent moves on (the next item, a call to `spotlight`, or the end of the
/// speech). Items added without speech (a bulk fill) are not spotlit; they
/// just enter in place. When the surface ends the screen is calm: nothing
/// lifted, marks lighter and then gone.
///
/// Everything goes through this class so two animations never fight over an
/// item: it is the only code that moves the [AgentSpotlightController] or
/// the [AgentMarkController] on behalf of the voice.
class AgentChoreographer {
  AgentChoreographer({
    required this.spotlight,
    required this.marks,
    required this.reveal,
    required this.saying,
    required this.playbackLag,
    required this.isSpeaking,
    this.fallback = const Duration(milliseconds: 3500),
    this.typeDelay = const Duration(milliseconds: 220),
    this.marksLinger = const Duration(seconds: 4),
  }) {
    spotlight.addListener(_focusChanged);
    saying.addListener(sayingChanged);
  }

  final AgentSpotlightController spotlight;
  final AgentMarkController marks;
  final AgentRevealSync reveal;

  /// What the agent has said so far in this reply.
  final ValueListenable<String> saying;

  /// How long until the speech already received has been heard.
  final Future<Duration> Function() playbackLag;
  final bool Function() isSpeaking;

  /// Words that never come (a paraphrase, another language) still show, in
  /// order, this long after their turn.
  final Duration fallback;

  /// The headline of an item that entered the spotlight starts typing this
  /// long after it landed.
  final Duration typeDelay;
  final Duration marksLinger;

  bool _disposed = false;
  bool _calming = false;
  bool _ending = false;
  int _epoch = 0;
  int _heardFrom = 0;
  Timer? _fallbackTimer;
  Object? _fallbackFor;
  Timer? _fade;
  final _cues = <({Set<String> words, VoidCallback effect, int epoch})>[];
  final _typing = <Timer>[];

  /// Items waiting for their words, in order (a test seam and a guard
  /// against asking twice).
  final _pending = <String>[];

  /// Every visual so far, in the order it happened (`enter:a`, `settle:a`,
  /// `mark:a`, `calm`); for tests and debugging.
  final log = <String>[];

  int get epoch => _epoch;
  bool get hasCues => _cues.isNotEmpty;

  /// The front layer changed: what was timed to the old one never fires.
  void newScreen() {
    _epoch++;
    _ending = false;
    _cues.clear();
    _pending.clear();
    _cancelTyping();
    reveal.releaseAll();
    spotlight.release();
    marks.clear();
    _fade?.cancel();
  }

  void _cancelTyping() {
    for (final t in _typing) {
      t.cancel();
    }
    _typing.clear();
  }

  void dispose() {
    _disposed = true;
    spotlight.removeListener(_focusChanged);
    saying.removeListener(sayingChanged);
    _fallbackTimer?.cancel();
    _fade?.cancel();
    _cancelTyping();
  }

  void _focusChanged() {
    // Annotations belong to what is being explained; a new focus or putting
    // the item back wipes them, except while the screen settles at the end.
    if (!_calming) marks.clear();
    if (spotlight.focused == null) {
      // An item that came back may have been typing for nobody.
      reveal.releaseAll();
    }
  }

  // ---- speech-synced cues ------------------------------------------------

  /// Runs [effect] once the agent says [words] (fuzzy, from the live
  /// transcript) and the speaker has reached them. Models often send every
  /// tool call before speaking; this keeps each visual on its own phrase.
  void cue(String words, VoidCallback effect) {
    _cues.add((words: grams(words), effect: effect, epoch: _epoch));
    _check();
  }

  void sayingChanged() {
    if (saying.value.isEmpty) {
      // A new reply: leftovers from the last one no longer apply.
      _cues.clear();
      _heardFrom = 0;
      _fallbackTimer?.cancel();
      _fallbackFor = null;
      return;
    }
    _check();
  }

  void _check() {
    while (_cues.isNotEmpty) {
      final cue = _cues.first;
      if (cue.epoch != _epoch) {
        _cues.removeAt(0);
        continue;
      }
      final said = saying.value;
      final fresh = said.length >= _heardFrom ? said.substring(_heardFrom) : '';
      if (!heard(fresh, cue.words)) break;
      _cues.removeAt(0);
      _heardFrom = said.length;
      unawaited(_atSpeech(cue.effect));
    }
    if (_cues.isEmpty) {
      _fallbackTimer?.cancel();
      _fallbackFor = null;
      return;
    }
    if (identical(_fallbackFor, _cues.first)) return;
    _fallbackFor = _cues.first;
    _fallbackTimer?.cancel();
    _fallbackTimer = Timer(fallback, () {
      if (_disposed || _cues.isEmpty) return;
      final cue = _cues.removeAt(0);
      _fallbackFor = null;
      _heardFrom = saying.value.length;
      if (cue.epoch == _epoch) cue.effect();
      _check();
    });
  }

  /// Runs [effect] when the speaker has played what was received so far.
  Future<void> _atSpeech(VoidCallback effect) async {
    final epoch = _epoch;
    final wait = await playbackLag();
    if (wait > const Duration(milliseconds: 60)) {
      await Future<void>.delayed(wait - const Duration(milliseconds: 40));
    }
    if (!_disposed && epoch == _epoch) effect();
  }

  static Set<String> grams(String text) {
    final t = text.toLowerCase().replaceAll(
      RegExp(r'[\s\p{P}\p{S}]', unicode: true),
      '',
    );
    final words = RegExp(r'[a-z0-9]+');
    return {
      for (final m in words.allMatches(t))
        if (m[0]!.length >= 2) m[0]!,
      for (final part in t.split(words))
        for (var i = 0; i + 1 < part.length; i++) part.substring(i, i + 2),
    };
  }

  static bool heard(String said, Set<String> words) {
    if (words.isEmpty) return true;
    final heard = grams(said);
    final hits = words.where(heard.contains).length;
    return hits >= math.max(1, math.min(3, (words.length * .25).ceil()));
  }

  // ---- the spotlight along the stream -----------------------------------

  /// A component was added to a streamed surface and has the screen number
  /// [focusId] (its `AgentFocusable` id). While the agent speaks it enters
  /// the spotlight when its words are played; otherwise nothing happens and
  /// it enters in place.
  void added(String focusId, String words) {
    if (!isSpeaking()) return;
    if (_pending.contains(focusId) || spotlight.focused == focusId) return;
    _pending.add(focusId);
    // Its text is laid out but waits for its turn in the spotlight.
    reveal.hold(focusId);
    cue(words, () => _enter(focusId));
  }

  void _enter(String id) {
    _pending.remove(id);
    log.add('enter:$id');
    // The previous item flies back to its slot while this one comes in.
    spotlight.focus(id, enter: true);
    _typing.add(
      Timer(typeDelay, () {
        if (!_disposed) reveal.release(id);
      }),
    );
  }

  /// The model asked to spotlight [focusId] (`spotlight`): when its words are
  /// played. An item already entering or lifted is not asked twice.
  void spotlightItem(String focusId, String words) {
    if (_pending.contains(focusId) || spotlight.focused == focusId) return;
    _pending.add(focusId);
    cue(words, () {
      _pending.remove(focusId);
      log.add('focus:$focusId');
      spotlight.focus(focusId);
    });
  }

  /// A mark on an item, when its phrase is spoken.
  void mark(AgentMark mark) {
    cue(mark.phrase, () {
      if (spotlight.focused != mark.itemId) spotlight.focus(mark.itemId);
      log.add('mark:${mark.itemId}');
      marks.add(mark);
    });
  }

  /// The agent finished speaking: the lifted item goes back, and a surface
  /// that was ended meanwhile goes calm.
  void speechEnded() {
    if (_cues.isNotEmpty) return;
    if (_ending) return _calm();
    if (spotlight.focused != null) {
      log.add('settle:${spotlight.focused}');
      spotlight.release();
    }
  }

  /// `end_surface`: once the agent has nothing more to show for it, the
  /// screen goes calm.
  void end() {
    _ending = true;
    if (_cues.isEmpty && _pending.isEmpty && !isSpeaking()) speechEnded();
  }

  void _calm() {
    _ending = false;
    if (spotlight.focused != null) log.add('settle:${spotlight.focused}');
    log.add('calm');
    _calming = true;
    spotlight.release();
    _calming = false;
    reveal.releaseAll();
    marks.dim();
    _fade?.cancel();
    if (marks.marks.isNotEmpty) {
      _fade = Timer(marksLinger, () {
        if (!_disposed) marks.clear();
      });
    }
  }
}
