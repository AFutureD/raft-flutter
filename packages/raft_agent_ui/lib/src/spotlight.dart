import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'handsfree/hf_scope.dart';
import 'handsfree/hf_split.dart';
import 'handsfree/hf_stage.dart';
import 'marks.dart';

/// The current item of a screen: the one thing on it that the person and the
/// agent are both looking at ("第二个", "这个", a tap). Voice (`spotlight`,
/// `expand_item`) and taps all set the same one, and what 通过 / 打开讨论 /
/// 稍后 do is done to it.
///
/// Nothing is lifted or copied: the row of the current item stays where it is
/// and is highlighted ([AgentSpotlight.isCurrent]), and the screen shows the
/// item in its detail (beside the list, or under the row on a phone), in the
/// same page.
/// It stays current until another one is, the layer changes, or it is
/// released.
class AgentSpotlightController extends ChangeNotifier {
  String? _focused;
  bool _enter = false;

  /// The current item, `layer#n`.
  String? get focused => _focused;

  /// The current item was just added to a screen that is being composed.
  bool get entering => _enter && _focused != null;

  void focus(String id, {bool enter = false}) {
    if (_focused == id) return;
    _focused = id;
    _enter = enter;
    notifyListeners();
  }

  void release() {
    if (_focused == null) return;
    _focused = null;
    _enter = false;
    notifyListeners();
  }

  /// Mirrors a current item received from elsewhere (e.g. the phone, on a
  /// TV).
  void sync(String? id, {bool enter = false}) =>
      id == null ? release() : focus(id, enter: enter);
}

/// Tells everything below it which item is current, from [controller].
class AgentSpotlight extends StatelessWidget {
  const AgentSpotlight({
    super.key,
    required this.controller,
    required this.child,
  });

  final AgentSpotlightController controller;
  final Widget child;

  /// The current item's id (`layer#n`) as seen from [context], or null.
  static String? currentOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_CurrentScope>()?.focused;

  /// Whether the [AgentFocusable] [context] sits in is the current item.
  static bool isCurrent(BuildContext context) {
    final id = AgentItemScope.of(context);
    return id != null && id == currentOf(context);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, child) =>
        _CurrentScope(focused: controller.focused, child: child!),
    child: child,
  );
}

class _CurrentScope extends InheritedWidget {
  const _CurrentScope({required this.focused, required super.child});
  final String? focused;

  @override
  bool updateShouldNotify(_CurrentScope old) => old.focused != focused;
}

/// A component the agent can point at, with the id the agent names it by
/// (`layer#n`). While it is the current item the widgets in it can draw the
/// highlight ([AgentSpotlight.isCurrent]).
///
/// Focus is scroll: when it becomes the current item the layer's page scrolls
/// (animated) to show it whole, and with it its stage when it has one. The
/// stage ([HfStageScope]) goes under it on a phone and beside it on a wide
/// window; either way it is part of the same page.
class AgentFocusable extends StatefulWidget {
  const AgentFocusable({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  State<AgentFocusable> createState() => _AgentFocusableState();
}

/// Where an item is in the page it scrolls with.
enum AgentItemView {
  /// All of it can be seen.
  whole,

  /// Part of it can be seen.
  partly,

  /// It is above the part of the page in view (scrolled past).
  above,

  /// It is below the part of the page in view.
  below,
}

/// Where the numbered items of the layer [layerId] are in the page right now,
/// by number: what is in view, what was scrolled past, what is still below.
/// Null when the layer is not drawn (nothing can be said yet).
Map<int, AgentItemView>? agentItemViews(String layerId) {
  final out = <int, AgentItemView>{};
  for (final state in _focusables) {
    final id = state.widget.id;
    final at = id.lastIndexOf('#');
    if (at < 0 || id.substring(0, at) != layerId) continue;
    final n = int.tryParse(id.substring(at + 1));
    final view = state.view();
    if (n != null && view != null) out[n] = view;
  }
  return out.isEmpty ? null : out;
}

final _focusables = <_AgentFocusableState>{};

class _AgentFocusableState extends State<AgentFocusable> {
  @override
  void initState() {
    super.initState();
    _focusables.add(this);
  }

  @override
  void dispose() {
    _focusables.remove(this);
    super.dispose();
  }

  /// Where this item sits in the page it scrolls with; null when it cannot
  /// be told (not laid out, no page around it).
  AgentItemView? view() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final found = RenderAbstractViewport.maybeOf(box);
    if (found is! RenderBox) return null;
    final RenderBox viewport = found as RenderBox;
    if (!viewport.hasSize) return null;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottom = top + box.size.height;
    final height = viewport.size.height;
    if (bottom <= 0) return AgentItemView.above;
    if (top >= height) return AgentItemView.below;
    return top >= -1 && bottom <= height + 1
        ? AgentItemView.whole
        : AgentItemView.partly;
  }

  /// Keeps the item's own state when its stage comes and goes around it.
  final _childKey = GlobalKey();
  final _stageKey = GlobalKey();
  bool _was = false, _wasStaged = false, _scheduled = false;

  void _reveal() {
    _scheduled = false;
    if (!mounted) return;
    revealInPage(context, stage: _stageRect());
  }

  /// Where the stage is, in the item's coordinates: under it on a phone, in
  /// the split beside the list on a wide window; null when there is none.
  Rect? _stageRect() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final under = _stageKey.currentContext?.findRenderObject();
    if (under is RenderBox && under.attached && under.hasSize) {
      return box.globalToLocal(under.localToGlobal(Offset.zero)) & under.size;
    }
    final split = context.findAncestorRenderObjectOfType<RenderHfSplit>();
    final beside = split?.stageRect;
    if (split == null || beside == null || !split.attached) return null;
    return box.globalToLocal(split.localToGlobal(beside.topLeft)) & beside.size;
  }

  void _scheduleReveal() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final now = AgentSpotlight.currentOf(context) == widget.id;
    if (now && !_was) _scheduleReveal();
    _was = now;
  }

  @override
  Widget build(BuildContext context) {
    final item = KeyedSubtree(
      key: _childKey,
      child: AgentItemScope(id: widget.id, child: widget.child),
    );
    final scope = HfStageScope.maybeOf(context);
    final stage = scope != null && scope.id == widget.id ? scope.stage : null;
    final staged = stage != null;
    // The stage appeared for the item that is already current: show it too.
    if (staged && !_wasStaged && _was) _scheduleReveal();
    _wasStaged = staged;
    if (!staged) return item;
    final hf = HandsFree.of(context);
    if (hf.split) return HfStageAnchor(child: item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        item,
        SizedBox(height: hf.sp(12)),
        KeyedSubtree(
          key: _stageKey,
          child: KeyedSubtree(key: const ValueKey('hf-stage'), child: stage),
        ),
      ],
    );
  }
}

/// Scrolls the page that [context] sits in so that the box of [context] is
/// whole in view, and the stage of the item with it.
///
/// An item that is already whole in view stays where it is. Else the page
/// moves so that the item is at the top of it (with the label of its section
/// above it), or, when the item and its stage together are taller than the
/// page and the stage alone is not (it carries the actions), so that the
/// stage is at the top; near the top of the page, the page goes to its top.
/// Something taller than the page gets its top at the top.
///
/// [stage] is the rect of the item's stage in the coordinates of [context]'s
/// box, when it is not inside the box.
void revealInPage(BuildContext context, {Rect? stage}) {
  final scrollable = Scrollable.maybeOf(context);
  final box = context.findRenderObject();
  if (scrollable == null ||
      box is! RenderBox ||
      !box.attached ||
      !box.hasSize) {
    return;
  }
  final viewport = RenderAbstractViewport.maybeOf(box);
  if (viewport == null) return;
  final hf = HandsFree.of(context);
  final position = scrollable.position;

  /// [r] with room for the hard shadow under a row and some air; [above] more
  /// above it when it is to come to the top.
  Rect pad(Rect r, {double above = 12}) => Rect.fromLTRB(
    r.left,
    r.top - hf.sp(above),
    r.right,
    r.bottom + hf.sp(12),
  );
  // The offsets that put [r] at the top and at the bottom of the page.
  double lead(Rect r) => viewport.getOffsetToReveal(box, 0, rect: r).offset;
  double trail(Rect r) => viewport.getOffsetToReveal(box, 1, rect: r).offset;
  bool fits(Rect r) => trail(r) <= lead(r);
  bool seen(Rect r) =>
      fits(r) &&
      position.pixels >= trail(r) - .5 &&
      position.pixels <= lead(r) + .5;

  var want = Offset.zero & box.size;
  if (stage != null) want = want.expandToInclude(stage);
  // Together too tall: the stage first.
  if (stage != null && !fits(pad(want)) && fits(pad(stage))) want = stage;
  // The stage alone is taller than the page too: it ends in the actions, so
  // its end is what must be in view (its start is a scroll up).
  if (stage != null && !fits(pad(stage)) && !fits(pad(want))) {
    final target = trail(pad(stage)).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final shown = (viewport as RenderBox).size.height - hf.sp(24);
    if (position.pixels >= target - .5 && position.pixels <= target + shown) {
      return;
    }
    if ((target - position.pixels).abs() < 1) return;
    unawaited(
      position.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      ),
    );
    return;
  }
  if (seen(pad(want))) return;
  // The item at the top, with as much of what comes before it as leaves its
  // end in view.
  var target = lead(pad(want, above: 36));
  if (fits(pad(want))) target = math.max(target, trail(pad(want)));
  if (lead(pad(want)) <= position.minScrollExtent + hf.sp(64)) {
    target = position.minScrollExtent;
  }
  target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
  if ((target - position.pixels).abs() < 1) return;
  unawaited(
    position.animateTo(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    ),
  );
}

/// Something that is not an item but must be seen when it comes (the confirm
/// cards waiting for an answer): the page scrolls to show it when it appears
/// and whenever [signature] changes (another card). Nothing else.
class AgentReveal extends StatefulWidget {
  const AgentReveal({super.key, required this.signature, required this.child});
  final Object? signature;
  final Widget child;

  @override
  State<AgentReveal> createState() => _AgentRevealState();
}

class _AgentRevealState extends State<AgentReveal> {
  void _schedule() => SchedulerBinding.instance.addPostFrameCallback((_) {
    if (mounted) revealInPage(context);
  });

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(AgentReveal old) {
    super.didUpdateWidget(old);
    if (old.signature != widget.signature) _schedule();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
