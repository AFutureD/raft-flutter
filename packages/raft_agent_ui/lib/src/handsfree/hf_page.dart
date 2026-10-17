import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'hf_scope.dart';

/// What [HfPageController.nextScreen] did.
enum HfPageStep {
  /// Scrolled down by about a screen.
  moved,

  /// Was at the end: went back to the top.
  wrapped,

  /// Everything is on one screen: there is nothing to move to.
  none,
}

/// The scroll of one layer's page. The owner of a layer holds it to move the
/// page for the voice ("下一批": the next items).
class HfPageController extends ScrollController {
  /// Scrolls down by about a screen (a little less, so the last row seen
  /// stays in view as a landmark); from the end it goes back to the top. The
  /// scroll is animated and goes on after this returns what it will do.
  HfPageStep nextScreen() {
    if (!hasClients) return HfPageStep.none;
    final p = position;
    if (!p.hasContentDimensions || p.maxScrollExtent <= 1) {
      return HfPageStep.none;
    }
    const duration = Duration(milliseconds: 350);
    if (p.pixels >= p.maxScrollExtent - 1) {
      unawaited(p.animateTo(0, duration: duration, curve: Curves.easeOutCubic));
      return HfPageStep.wrapped;
    }
    unawaited(
      p.animateTo(
        (p.pixels + p.viewportDimension * .85).clamp(0.0, p.maxScrollExtent),
        duration: duration,
        curve: Curves.easeOutCubic,
      ),
    );
    return HfPageStep.moved;
  }
}

/// Hands a layer its [HfPageController]; without one a layer keeps its own.
class HfPageControllerScope extends InheritedWidget {
  const HfPageControllerScope({
    super.key,
    required this.controller,
    required super.child,
  });
  final HfPageController controller;

  static HfPageController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HfPageControllerScope>()
      ?.controller;

  @override
  bool updateShouldNotify(HfPageControllerScope old) =>
      old.controller != controller;
}

/// What goes at the end of the front layer's page (the confirm cards that
/// wait for an answer): part of the page, not a pane with a scroll of its
/// own.
class HfPageTail extends InheritedWidget {
  const HfPageTail({super.key, required this.tail, required super.child});
  final Widget? tail;

  static Widget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfPageTail>()?.tail;

  @override
  bool updateShouldNotify(HfPageTail old) => old.tail != tail;
}

/// Which edges of the front layer's page have content behind an overlay: the
/// page has been scrolled ([top]), or more of it lies below what is seen
/// ([bottom]). The screen frame shows the fade behind an overlay only then.
typedef HfBehind = ({bool top, bool bottom});

/// The bars that float over the front layer's page: the small top bar of a
/// phone and the dock. The page scrolls under them, so it pads its content by
/// their heights (everything can be scrolled clear of them), and the
/// scroll-to-reveal code keeps the current item out from under them.
///
/// The screen frame provides it; without one the insets are zero.
class HfOverlayInsets extends InheritedWidget {
  const HfOverlayInsets({
    super.key,
    this.top = 0,
    this.bottom = 0,
    this.behind,
    required super.child,
  });

  /// The heights of the overlays at the top and at the bottom of the page.
  final double top, bottom;

  /// Where the page tells which edges have content behind an overlay.
  final ValueNotifier<HfBehind>? behind;

  static HfOverlayInsets? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfOverlayInsets>();

  /// The top and bottom insets in effect (zero outside a frame).
  static ({double top, double bottom}) of(BuildContext context) {
    final o = maybeOf(context);
    return (top: o?.top ?? 0, bottom: o?.bottom ?? 0);
  }

  @override
  bool updateShouldNotify(HfOverlayInsets old) =>
      old.top != top || old.bottom != bottom || old.behind != behind;
}

/// A layer's page: the one scroll of the layer. A phone and a desktop scroll
/// it by hand; a TV cannot, so the layer scrolls it to the current item.
/// Nothing inside scrolls on its own and nothing is cut off at an edge. What
/// floats over it (see [HfOverlayInsets]) is padded for, so the first and the
/// last item can be scrolled clear of it.
class HfPage extends StatefulWidget {
  const HfPage({super.key, required this.child});
  final Widget child;

  @override
  State<HfPage> createState() => _HfPageState();
}

class _HfPageState extends State<HfPage> {
  HfPageController? _own;
  HfPageController? _listening;
  bool _scheduled = false;

  HfPageController _controller(BuildContext context) =>
      HfPageControllerScope.maybeOf(context) ?? (_own ??= HfPageController());

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = _controller(context);
    if (!identical(c, _listening)) {
      _listening?.removeListener(_report);
      _listening = c..addListener(_report);
    }
    _schedule();
  }

  @override
  void dispose() {
    _listening?.removeListener(_report);
    _own?.dispose();
    super.dispose();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _report();
    });
  }

  /// Tells the frame which edges have content behind an overlay.
  void _report() {
    final sink = HfOverlayInsets.maybeOf(context)?.behind;
    final c = _listening;
    if (sink == null || c == null || !c.hasClients) return;
    final p = c.position;
    if (!p.hasContentDimensions) return;
    sink.value = (
      top: p.pixels > .5,
      bottom: p.maxScrollExtent - p.pixels > .5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final controller = _controller(context);
    final inset = HfOverlayInsets.of(context);
    final page = SingleChildScrollView(
      key: const ValueKey('hf-page'),
      controller: controller,
      physics: hf.interactive
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: inset.top,
        bottom: hf.sp(10) + inset.bottom,
        right: hf.sp(8),
      ),
      child: widget.child,
    );
    // A desktop with a pointer gets a bar that stays in view, so a stage taller
    // than the window says there is more under it; a finger needs none.
    final bar = hf.interactive && !hf.phone
        ? Scrollbar(controller: controller, thumbVisibility: true, child: page)
        : page;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _schedule();
        return false;
      },
      child: bar,
    );
  }
}
