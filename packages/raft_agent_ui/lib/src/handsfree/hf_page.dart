import 'dart:async';

import 'package:flutter/material.dart';

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

/// A layer's page: the one scroll of the layer, below its fixed header. A
/// phone and a desktop scroll it by hand; a TV cannot, so the layer scrolls
/// it to the current item. Nothing inside scrolls on its own and nothing
/// fades or is cut off at an edge.
class HfPage extends StatefulWidget {
  const HfPage({super.key, required this.child});
  final Widget child;

  @override
  State<HfPage> createState() => _HfPageState();
}

class _HfPageState extends State<HfPage> {
  HfPageController? _own;

  HfPageController _controller(BuildContext context) =>
      HfPageControllerScope.maybeOf(context) ?? (_own ??= HfPageController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final controller = _controller(context);
    final page = SingleChildScrollView(
      key: const ValueKey('hf-page'),
      controller: controller,
      physics: hf.interactive
          ? const ClampingScrollPhysics()
          : const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.only(bottom: hf.sp(10), right: hf.sp(8)),
      child: widget.child,
    );
    // A desktop with a pointer gets a bar that stays in view, so a stage taller
    // than the window says there is more under it; a finger needs none.
    return hf.interactive && !hf.phone
        ? Scrollbar(controller: controller, thumbVisibility: true, child: page)
        : page;
  }
}
