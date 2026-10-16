import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'agent_theme.dart';
import 'marks.dart' show AgentItemScope;

/// The entrance of things that appear while the agent talks: a piece drops in
/// and settles, then its text types, then its small parts (chips, stickers,
/// buttons) pop in with an overshoot. Pieces come one after another, like
/// someone assembling a puzzle.
///
/// Nothing here changes layout: a piece is laid out at its final size from the
/// first frame, only paint (opacity, scale, tilt, the characters shown)
/// changes. With reduced motion everything is simply there.

/// One piece's turn: when its entrance starts and how long its main motion
/// takes.
class AgentEnterPlan {
  const AgentEnterPlan(this.delay, this.duration);
  final Duration delay, duration;

  /// How much shorter than the full motion this turn is (1 = not shortened).
  double scaleOf(Duration base) =>
      duration.inMicroseconds / base.inMicroseconds;

  @override
  String toString() => 'AgentEnterPlan($delay, $duration)';
}

/// Hands out turns so that streamed pieces do not arrive in one lump.
///
/// The next piece starts when the previous one's main motion is [overlap]
/// done. Arrival is never delayed by more than [maxLag]: when pieces pile up
/// the gap between them and the length of their motion shrink instead.
class AgentEnterPacer {
  AgentEnterPacer({
    this.base = const Duration(milliseconds: 360),
    this.maxLag = const Duration(milliseconds: 400),
    this.overlap = .6,
    Duration Function()? clock,
  }) : _clock = clock ?? _frameClock;

  final Duration base, maxLag;
  final double overlap;
  final Duration Function() _clock;

  static Duration _frameClock() =>
      SchedulerBinding.instance.currentFrameTimeStamp;

  Duration get step => base * overlap;

  /// When the last piece handed out starts.
  Duration? _tail;

  /// Turns for [count] pieces that arrived together, in order.
  List<AgentEnterPlan> plan(int count) {
    if (count <= 0) return const [];
    final now = _clock();
    var gap = step;
    var first = _tail == null ? now : _max(now, _tail! + gap);
    final deadline = now + maxLag;
    if (first > deadline) first = deadline;
    final span = deadline - first;
    if (count > 1 && gap * (count - 1) > span) {
      gap = span ~/ (count - 1);
    }
    // Pieces squeezed together also move faster.
    final scale = (gap.inMicroseconds / step.inMicroseconds).clamp(.4, 1.0);
    final duration = base * scale;
    final plans = [
      for (var i = 0; i < count; i++)
        AgentEnterPlan(first - now + gap * i, duration),
    ];
    _tail = first + gap * (count - 1);
    return plans;
  }

  static Duration _max(Duration a, Duration b) => a > b ? a : b;

  final _waiting = <void Function(AgentEnterPlan)>[];
  bool _scheduled = false;

  /// Asks for a turn; [start] is called after the frame with the plan, in
  /// request order.
  void request(void Function(AgentEnterPlan) start) {
    _waiting.add(start);
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      final batch = List.of(_waiting);
      _waiting.clear();
      final plans = plan(batch.length);
      for (var i = 0; i < batch.length; i++) {
        batch[i](plans[i]);
      }
    });
  }

  /// A requester that went away before its turn.
  void cancel(void Function(AgentEnterPlan) start) => _waiting.remove(start);
}

/// Provides the [AgentEnterPacer] pieces below take their turn from.
class AgentEnterPacing extends InheritedWidget {
  const AgentEnterPacing({
    super.key,
    required this.pacer,
    required super.child,
  });
  final AgentEnterPacer pacer;

  static AgentEnterPacer? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentEnterPacing>()?.pacer;

  @override
  bool updateShouldNotify(AgentEnterPacing old) => old.pacer != pacer;
}

/// How far a piece's entrance has come, for the parts inside it.
class AgentEnterScope extends InheritedWidget {
  const AgentEnterScope({
    super.key,
    required this.progress,
    required this.speed,
    required super.child,
  });

  /// 0 to 1 over the piece's main motion (linear).
  final Animation<double> progress;

  /// 1 normally; below 1 when the piece was squeezed by a burst, so its
  /// parts move faster too.
  final double speed;

  static AgentEnterScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentEnterScope>();

  @override
  bool updateShouldNotify(AgentEnterScope old) =>
      old.progress != progress || old.speed != speed;
}

/// Items whose text waits for the speaker: it stays unrevealed (but laid
/// out) while held, and types out when released.
class AgentRevealSync extends ChangeNotifier {
  final _held = <String>{};

  bool isHeld(String? id) => id != null && _held.contains(id);

  void hold(String id) {
    if (_held.add(id)) notifyListeners();
  }

  void release(String id) {
    if (_held.remove(id)) notifyListeners();
  }

  void releaseAll() {
    if (_held.isEmpty) return;
    _held.clear();
    notifyListeners();
  }
}

class AgentRevealSyncScope extends InheritedNotifier<AgentRevealSync> {
  const AgentRevealSyncScope({
    super.key,
    required AgentRevealSync sync,
    required super.child,
  }) : super(notifier: sync);

  static AgentRevealSync? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AgentRevealSyncScope>()
      ?.notifier;
}

bool _reduced(BuildContext context) =>
    MediaQuery.maybeDisableAnimationsOf(context) ?? false;

class _Window extends Animation<double> with AnimationWithParentMixin<double> {
  _Window(this.parent);
  @override
  final Animation<double> parent;
  double start = 0;

  @override
  double get value =>
      start >= 1 ? 1 : ((parent.value - start) / (1 - start)).clamp(0.0, 1.0);
}

/// Wraps a piece of a surface so it enters: a drop with a small settle
/// (scale .96 to 1, a slight tilt in sticker style, a short slide), fading
/// in. The piece keeps its final place and size the whole time.
///
/// With [animate] false, or with reduced motion, the child is just there.
class AgentAppear extends StatefulWidget {
  const AgentAppear({super.key, required this.child, this.animate = true});
  final Widget child;
  final bool animate;

  @override
  State<AgentAppear> createState() => _AgentAppearState();
}

class _AgentAppearState extends State<AgentAppear>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  late final _Window _window;
  AgentEnterPacer? _pacer;
  bool _decided = false;
  double _speed = 1;
  bool _built = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!widget.animate || _reduced(context)) return;
    final pacer = AgentEnterPacing.maybeOf(context);
    final t = RaftAgentTheme.of(context);
    _controller = AnimationController(vsync: this, duration: t.duration);
    _window = _Window(_controller!);
    if (pacer == null) {
      _begin(AgentEnterPlan(Duration.zero, t.duration * .6));
    } else {
      _pacer = pacer;
      pacer.request(_begin);
    }
  }

  void _begin(AgentEnterPlan plan) {
    final c = _controller;
    if (c == null || !mounted) return;
    final total = plan.delay + plan.duration;
    c.duration = total;
    _window.start = plan.delay.inMicroseconds / total.inMicroseconds;
    _speed = plan.scaleOf(_pacer?.base ?? plan.duration);
    c.forward(from: 0);
    if (_built) setState(() {});
  }

  @override
  void dispose() {
    _pacer?.cancel(_begin);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _built = true;
    final c = _controller;
    if (c == null) return widget.child;
    final t = RaftAgentTheme.of(context);
    final tilt = t.stickerLabels ? .018 : 0.0;
    return AgentEnterScope(
      progress: _window,
      speed: _speed.clamp(.4, 1.0),
      child: AnimatedBuilder(
        animation: _window,
        child: widget.child,
        builder: (context, child) {
          final p = _window.value;
          final settle = Curves.easeOutCubic.transform(p);
          final fade = Curves.easeOut.transform((p * 2.5).clamp(0.0, 1.0));
          return Opacity(
            opacity: fade,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..translateByDouble(0, 10 * (1 - settle), 0, 1)
                ..rotateZ(tilt * (1 - settle))
                ..scaleByDouble(.96 + .04 * settle, .96 + .04 * settle, 1, 1),
              child: child,
            ),
          );
        },
      ),
    );
  }
}

/// A part of an [AgentAppear]ing piece that starts once the piece has come
/// [at] of the way (0 to 1) and runs for [duration] on its own. [builder]
/// gets 0 to 1 (more or less, depending on [curve]). Outside a piece, or
/// with reduced motion, it gets 1 at once.
class AgentStage extends StatefulWidget {
  const AgentStage({
    super.key,
    required this.at,
    required this.builder,
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeOutCubic,
    this.holdable = false,
  });

  final double at;
  final Duration duration;
  final Curve curve;

  /// Waits while the speaker has not reached the item ([AgentRevealSync]).
  final bool holdable;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<AgentStage> createState() => _AgentStageState();
}

class _AgentStageState extends State<AgentStage>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  AgentEnterScope? _scope;
  bool _live = false;
  bool _started = false;
  AgentRevealSync? _sync;
  String? _item;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started && !_live) return;
    final scope = AgentEnterScope.maybeOf(context);
    if (scope == null || _reduced(context)) {
      _live = false;
      _started = true;
      return;
    }
    if (_scope?.progress != scope.progress) {
      _scope?.progress.removeListener(_check);
      scope.progress.addListener(_check);
    }
    _scope = scope;
    _live = true;
    if (widget.holdable) {
      // Depending on the notifier is what re-runs this when it changes.
      _sync = AgentRevealSyncScope.maybeOf(context);
      _item = AgentItemScope.of(context);
    }
    _check();
  }

  bool get _held => widget.holdable && (_sync?.isHeld(_item) ?? false);

  void _check() {
    if (_started || !mounted || _scope == null) return;
    if (_scope!.progress.value < widget.at || _held) return;
    _started = true;
    _scope!.progress.removeListener(_check);
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration * _scope!.speed,
    );
    _controller!.forward();
    setState(() {});
  }

  @override
  void dispose() {
    _scope?.progress.removeListener(_check);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_live) return widget.builder(context, 1);
    final c = _controller;
    if (c == null) return widget.builder(context, 0);
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) =>
          widget.builder(context, widget.curve.transform(c.value)),
    );
  }
}

/// Text that types out inside an [AgentAppear]ing piece. The whole text is
/// laid out from the first frame (the part not yet typed is transparent), so
/// nothing moves while it appears.
class AgentTypeText extends StatelessWidget {
  const AgentTypeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.textKey,
    this.at = .35,
  });
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final Key? textKey;

  /// When, as a share of the piece's entrance, the typing starts.
  final double at;

  @override
  Widget build(BuildContext context) {
    final chars = text.characters;
    final length = chars.length;
    return AgentStage(
      at: at,
      holdable: true,
      curve: Curves.linear,
      duration: Duration(milliseconds: (length * 24).clamp(250, 400)),
      builder: (context, v) {
        if (v >= 1) {
          return Text(
            text,
            key: textKey,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
            style: style,
          );
        }
        final shown = chars.take((length * v).floor()).toString();
        return Text.rich(
          TextSpan(
            text: shown,
            children: [
              TextSpan(
                text: text.substring(shown.length),
                style: const TextStyle(color: Color(0x00000000)),
              ),
            ],
          ),
          key: textKey,
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

/// A number that counts up to [value] (digits only; anything else is shown
/// as is). The width of the final number is reserved from the start.
class AgentCountUp extends StatelessWidget {
  const AgentCountUp(this.value, {super.key, this.style, this.at = .4});
  final String value;
  final TextStyle? style;
  final double at;

  @override
  Widget build(BuildContext context) {
    final target = int.tryParse(value);
    final digits = value.length < 10 && RegExp(r'^\d+$').hasMatch(value);
    final tabular = (style ?? const TextStyle()).copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    if (target == null || !digits) return Text(value, style: style);
    return AgentStage(
      at: at,
      duration: Duration(milliseconds: 280 + math.min(target, 20) * 10),
      builder: (context, v) {
        if (v >= 1) return Text(value, style: tabular);
        final shown = (target * v).round().toString();
        final pad = '0' * math.max(0, value.length - shown.length);
        return Text.rich(
          TextSpan(
            text: shown,
            children: [
              TextSpan(
                text: pad,
                style: const TextStyle(color: Color(0x00000000)),
              ),
            ],
          ),
          style: tabular,
        );
      },
    );
  }
}

/// Pops [child] in with a small overshoot, after the text of its piece
/// (chips, stickers, buttons). [order] staggers siblings by ~70 ms.
class AgentPop extends StatelessWidget {
  const AgentPop({
    super.key,
    required this.child,
    this.order = 0,
    this.at = .8,
  });
  final Widget child;
  final int order;
  final double at;

  @override
  Widget build(BuildContext context) => AgentStage(
    at: at,
    duration: Duration(milliseconds: 260 + 70 * order),
    curve: Interval(
      (70 * order) / (260 + 70 * order),
      1,
      curve: Curves.easeOutBack,
    ),
    builder: (context, v) => Opacity(
      opacity: (v * 2).clamp(0.0, 1.0),
      child: Transform.scale(scale: .6 + .4 * v, child: child),
    ),
  );
}
