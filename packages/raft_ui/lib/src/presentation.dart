import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'dismiss_scope.dart';
import 'overlays/dialog.dart' show RaftDialogBarrier;
import 'sheet.dart';
import 'settings_layout.dart' show RaftSpace;
import 'theme.dart';

// One place decides which form a floating window takes. A window states what
// it is for (a [RaftPresentationPolicy]); the window's width gives the layout
// class; the policy maps the class to a form. Nothing else may decide: not the
// platform, not whether the window is open or expanded. A window that is open
// follows the live width, so crossing a breakpoint switches its form in place
// and its content (a text field, a scroll position) keeps its state.

/// How much room the window has, by width. The cuts are the app's own:
/// [RaftLayoutMetrics.desktopBreakpoint] (the one compact predicate, see
/// `RaftAdaptiveWorkspace.compactOf`) and
/// [RaftLayoutMetrics.threadOverlayBreakpoint].
enum RaftLayoutClass {
  /// Phones and narrow desktop windows: below 768.
  compact,

  /// Tablets and foldable inner screens: 768 up to 1024.
  medium,

  /// Desktop windows: 1024 and wider.
  wide,
}

RaftLayoutClass raftLayoutClassForWidth(double width) =>
    width < RaftLayoutMetrics.desktopBreakpoint
    ? RaftLayoutClass.compact
    : width < RaftLayoutMetrics.threadOverlayBreakpoint
    ? RaftLayoutClass.medium
    : RaftLayoutClass.wide;

/// The layout class of the window [context] is in (the raw window width, not a
/// breakpoint band: the cut must be exact).
RaftLayoutClass raftLayoutClassOf(BuildContext context) =>
    raftLayoutClassForWidth(MediaQuery.sizeOf(context).width);

/// What a floating window looks like.
enum RaftSurfaceForm {
  /// Rises from the bottom edge, with a drag handle.
  sheet,

  /// Centered over a scrim.
  dialog,

  /// Docked to the trailing edge.
  side,

  /// Fills the window.
  page,

  /// Anchored to its trigger (menus, selects, hover cards). Drawn by the
  /// anchored overlay widgets, not by [RaftPresentedRoute]; a route asked for
  /// one shows a dialog.
  popover,
}

/// Which form a kind of window takes in each layout class.
@immutable
class RaftPresentationPolicy {
  const RaftPresentationPolicy({
    required this.compact,
    required this.medium,
    required this.wide,
  });

  final RaftSurfaceForm compact, medium, wide;

  RaftSurfaceForm formFor(RaftLayoutClass layout) => switch (layout) {
    RaftLayoutClass.compact => compact,
    RaftLayoutClass.medium => medium,
    RaftLayoutClass.wide => wide,
  };

  /// A short question that needs an answer.
  static const confirm = RaftPresentationPolicy(
    compact: RaftSurfaceForm.dialog,
    medium: RaftSurfaceForm.dialog,
    wide: RaftSurfaceForm.dialog,
  );

  /// Create and edit forms with inputs.
  static const form = RaftPresentationPolicy(
    compact: RaftSurfaceForm.sheet,
    medium: RaftSurfaceForm.dialog,
    wide: RaftSurfaceForm.dialog,
  );

  /// Long text editing with a keyboard (the expanded composer).
  static const editor = RaftPresentationPolicy(
    compact: RaftSurfaceForm.sheet,
    medium: RaftSurfaceForm.dialog,
    wide: RaftSurfaceForm.dialog,
  );

  /// Read-only details: profiles, settings panels.
  static const detail = RaftPresentationPolicy(
    compact: RaftSurfaceForm.page,
    medium: RaftSurfaceForm.side,
    wide: RaftSurfaceForm.side,
  );

  /// Choosing from a list: selects, emoji pickers.
  static const picker = RaftPresentationPolicy(
    compact: RaftSurfaceForm.sheet,
    medium: RaftSurfaceForm.popover,
    wide: RaftSurfaceForm.popover,
  );

  /// Context, overflow and dropdown menus.
  static const menu = RaftPresentationPolicy(
    compact: RaftSurfaceForm.popover,
    medium: RaftSurfaceForm.popover,
    wide: RaftSurfaceForm.popover,
  );

  /// Image, file and document previews.
  static const viewer = RaftPresentationPolicy(
    compact: RaftSurfaceForm.page,
    medium: RaftSurfaceForm.dialog,
    wide: RaftSurfaceForm.dialog,
  );
}

/// The route of a floating window whose form follows the window width.
///
/// One route for every form: the form is read from the live width each build,
/// so a resize switches it without closing the window. [content] is built in
/// whichever frame the form needs and keeps its state across the switch.
///
/// The sheet form is the framework's modal bottom sheet route (scrim, Back,
/// drag-to-dismiss and the sheet's animation come from it) with the
/// design-system look of [RaftSheet]; the dialog, side and page forms are
/// frames of the same route.
// ignore: raft_lints/avoid_raw_bottom_sheet -- the one place a framework sheet route is built on: raft_ui's presentation primitive
class RaftPresentedRoute<T> extends ModalBottomSheetRoute<T> {
  RaftPresentedRoute({
    required RaftPresentationPolicy policy,
    required Widget Function(BuildContext context, RaftSurfaceForm form)
    content,
    required CapturedThemes capturedThemes,
    required RaftSurfaceForm initialForm,
    required Color panelColor,
    required ShapeBorder sheetShape,
    String? label,
    RouteSettings? settings,
    bool dismissible = true,
    double dialogMaxWidth = 560,
    double? dialogMaxHeight,
    bool dialogFillsHeight = false,
    bool sheetFillsHeight = false,
    double sheetInitialSize = RaftSheetMetrics.largeDetent,
    RaftSheetDetents? sheetDetents,
    double sideWidth = 420,
  }) : this._(
         _SheetBuilder(),
         policy: policy,
         content: content,
         capturedThemes: capturedThemes,
         initialForm: initialForm,
         panelColor: panelColor,
         sheetShape: sheetShape,
         label: label,
         settings: settings,
         dismissible: dismissible,
         dialogMaxWidth: dialogMaxWidth,
         dialogMaxHeight: dialogMaxHeight,
         dialogFillsHeight: dialogFillsHeight,
         sheetFillsHeight: sheetFillsHeight,
         sheetInitialSize: sheetInitialSize,
         sheetDetents: sheetDetents,
         sideWidth: sideWidth,
       );

  RaftPresentedRoute._(
    this._sheetBuilder, {
    required this.policy,
    required this.content,
    required CapturedThemes capturedThemes,
    required RaftSurfaceForm initialForm,
    required Color panelColor,
    required ShapeBorder sheetShape,
    String? label,
    super.settings,
    required bool dismissible,
    required this.dialogMaxWidth,
    required this.dialogMaxHeight,
    required this.dialogFillsHeight,
    required this.sheetFillsHeight,
    required this.sheetInitialSize,
    required this.sheetDetents,
    required this.sideWidth,
  }) : super(
         builder: _sheetBuilder.call,
         capturedThemes: capturedThemes,
         barrierLabel: label ?? 'Dismiss',
         isDismissible: dismissible,
         isScrollControlled: true,
         useSafeArea: true,
         // A fixed sheet (an editor) is dragged as a whole by the framework's
         // sheet; a scrolling sheet is dragged by its draggable detents, which
         // also decide when a pull at the top of the content closes it.
         enableDrag: sheetFillsHeight,
         showDragHandle: false,
         backgroundColor: panelColor,
         shape: sheetShape,
         elevation: 0,
         clipBehavior: Clip.antiAlias,
         constraints: const BoxConstraints(maxWidth: RaftSheetMetrics.maxWidth),
         sheetAnimationStyle:
             initialForm == RaftSurfaceForm.dialog ||
                 initialForm == RaftSurfaceForm.popover
             ? const AnimationStyle(
                 duration: Duration(milliseconds: 150),
                 reverseDuration: Duration(milliseconds: 150),
               )
             : null,
       ) {
    _sheetBuilder.target = _buildSheet;
  }

  final _SheetBuilder _sheetBuilder;
  final RaftPresentationPolicy policy;

  /// Builds the window's content for [form]. Called again when the form
  /// changes; the widgets it returns keep their state when they keep their
  /// types and keys.
  final Widget Function(BuildContext context, RaftSurfaceForm form) content;
  final double dialogMaxWidth, sideWidth;
  final double? dialogMaxHeight;

  /// The dialog takes all the height there is (up to [dialogMaxHeight]).
  final bool dialogFillsHeight;

  /// The sheet is always [RaftSheetMetrics.largeDetent] tall (an editor whose
  /// content scrolls itself). Otherwise the sheet is a scrolling [RaftSheet]
  /// that opens at [sheetInitialSize] of the window and can be dragged up to
  /// the large detent.
  final bool sheetFillsHeight;
  final double sheetInitialSize;

  /// Lets the host move the scrolling sheet between its detents (and adds a
  /// peek detent to them); null for the usual two.
  final RaftSheetDetents? sheetDetents;

  final contentKey = GlobalKey(debugLabel: 'presented content');

  /// The form the live width gives; a popover has no frame here.
  RaftSurfaceForm formOf(BuildContext context) {
    final form = policy.formFor(raftLayoutClassOf(context));
    return form == RaftSurfaceForm.popover ? RaftSurfaceForm.dialog : form;
  }

  Widget _buildSheet(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final body = KeyedSubtree(
      key: contentKey,
      child: Builder(
        builder: (context) => content(context, RaftSurfaceForm.sheet),
      ),
    );
    // The sheet rides above the keyboard: its room shrinks by the inset.
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: sheetFillsHeight
          ? LayoutBuilder(
              builder: (context, box) => SizedBox(
                height: math.min(
                  media.size.height * RaftSheetMetrics.largeDetent,
                  box.maxHeight,
                ),
                child: RaftSheetScope(scrollController: null, child: body),
              ),
            )
          : _DetentSheet(
              initialSize: sheetInitialSize,
              detents: sheetDetents,
              builder: (controller, drag) => RaftSheetScope(
                scrollController: controller,
                pointerDrag: drag,
                child: body,
              ),
            ),
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final form = formOf(context);
    // Esc closes whichever form it is.
    return RaftDismissScope(
      child: form == RaftSurfaceForm.sheet
          ? super.buildPage(context, animation, secondaryAnimation)
          : capturedThemes!.wrap(_PresentedFrame(route: this, form: form)),
    );
  }

  @override
  Widget buildModalBarrier() {
    final barrier = RaftDialogBarrier(
      animation: animation!,
      dismissible: barrierDismissible,
      label: barrierLabel,
      capturedThemes: capturedThemes!,
    );
    // A full page covers the window; a scrim under it would only cost a blur.
    return Builder(
      builder: (context) => formOf(context) == RaftSurfaceForm.page
          ? const SizedBox.shrink()
          : barrier,
    );
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => switch (formOf(context)) {
    // The sheet animates itself, with the route's controller.
    RaftSurfaceForm.sheet => child,
    RaftSurfaceForm.dialog ||
    RaftSurfaceForm.popover => _fadeScale(animation, child),
    RaftSurfaceForm.page => SlideTransition(
      position: animation.drive(
        Tween(begin: const Offset(0, 1), end: Offset.zero),
      ),
      child: child,
    ),
    RaftSurfaceForm.side => SlideTransition(
      position: animation.drive(
        Tween(begin: const Offset(1, 0), end: Offset.zero),
      ),
      child: child,
    ),
  };

  // `duration-150 ease-out`, content from 0.98.
  static Widget _fadeScale(Animation<double> animation, Widget child) {
    final curved = animation.drive(CurveTween(curve: Curves.easeOut));
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween(begin: .98, end: 1.0).animate(curved),
        child: child,
      ),
    );
  }
}

/// Moves a presented scrolling sheet between its detents from outside: a host
/// that did something on the screen behind the sheet (an agent opened a page)
/// lowers the sheet to a peek so the page shows, and raises it again when the
/// person asks. Give it to [showRaftPresented] / [raftPresentedRoute]; the
/// sheet then also snaps at [peekSize]. The sheet's own dragging is unchanged.
class RaftSheetDetents {
  RaftSheetDetents({this.peekSize = .3})
    : assert(peekSize > .25 && peekSize < RaftSheetMetrics.largeDetent);

  /// The low detent: the sheet's top edge, as a fraction of the window.
  final double peekSize;

  _DetentSheetState? _sheet;

  /// Whether a sheet is on screen to move.
  bool get attached => (_sheet?.controller.isAttached ?? false);

  /// The sheet's size now, as a fraction of the window; null when none.
  double? get size => attached ? _sheet!.controller.size : null;

  /// Whether the sheet is lowered to the peek (or dragged below its opening
  /// size toward it).
  bool get peeking => size != null && size! <= peekSize + .02;

  /// Lowers the sheet to the peek detent. False when no sheet is open.
  Future<bool> peek() => _moveTo(peekSize);

  /// Raises the sheet to the size it opened at. False when no sheet is open.
  Future<bool> restore() => _moveTo(_sheet?.widget.initialSize);

  Future<bool> _moveTo(double? to) async {
    final sheet = _sheet;
    if (sheet == null || to == null || !sheet.controller.isAttached) {
      return false;
    }
    await sheet.controller.animateTo(
      to,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
    return true;
  }
}

/// The scrolling sheet: draggable detents (the opening size and the large
/// one) with one rule for closing it. A drag down to the bottom is a request
/// to close, answered the way Back and Esc are: [Navigator.maybePop]. A route
/// that vetoes the pop (`PopScope(canPop: false)`, a form with unsaved input)
/// hears `didPop: false` and the sheet slides back to its detent; the framework
/// would close it with a raw `Navigator.pop` instead.
class _DetentSheet extends StatefulWidget {
  const _DetentSheet({
    required this.initialSize,
    required this.builder,
    this.detents,
  });
  final double initialSize;
  final RaftSheetDetents? detents;
  final Widget Function(ScrollController controller, RaftSheetPointerDrag drag)
  builder;

  @override
  State<_DetentSheet> createState() => _DetentSheetState();
}

class _DetentSheetState extends State<_DetentSheet>
    implements RaftSheetPointerDrag {
  final controller = DraggableScrollableController();
  bool asking = false;

  /// The height the sheet's sizes are fractions of.
  double extentHeight = 0;
  static const _minSize = .25;

  @override
  void initState() {
    super.initState();
    widget.detents?._sheet = this;
  }

  @override
  void didUpdateWidget(_DetentSheet old) {
    super.didUpdateWidget(old);
    if (old.detents != widget.detents) {
      if (old.detents?._sheet == this) old.detents?._sheet = null;
      widget.detents?._sheet = this;
    }
  }

  List<double> get snapSizes => [
    if (widget.detents case final detents?) detents.peekSize,
    if (widget.initialSize < RaftSheetMetrics.largeDetent) widget.initialSize,
    RaftSheetMetrics.largeDetent,
  ];

  /// Below this a released drag is a request to close.
  double get _closeBelow => widget.detents == null
      ? widget.initialSize / 2
      : (_minSize + widget.detents!.peekSize) / 2;

  @override
  void update(double dy) {
    if (!controller.isAttached || extentHeight <= 0) return;
    // Held just above the bottom: reaching it is a request to close, and
    // that is asked once, when the drag ends.
    controller.jumpTo(
      (controller.size - dy / extentHeight).clamp(
        _minSize + .01,
        RaftSheetMetrics.largeDetent,
      ),
    );
  }

  @override
  void end(double velocityDy) {
    if (!controller.isAttached) return;
    final size = controller.size;
    // Flung down, or let go below half the opening size: a request to close,
    // answered the way a finger's drag to the bottom is.
    if (velocityDy > 700 || size < _closeBelow) {
      // Reaching the bottom asks the route (see [onExtent]).
      unawaited(
        controller.animateTo(
          _minSize,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
        ),
      );
      return;
    }
    final target = velocityDy < -700
        ? RaftSheetMetrics.largeDetent
        : snapSizes.reduce(
            (a, b) => (a - size).abs() <= (b - size).abs() ? a : b,
          );
    unawaited(
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  void dispose() {
    if (widget.detents?._sheet == this) widget.detents?._sheet = null;
    controller.dispose();
    super.dispose();
  }

  bool onExtent(DraggableScrollableNotification n) {
    if (n.extent > n.minExtent + .001) return false;
    close();
    return false;
  }

  void close() {
    if (asking || !mounted) return;
    asking = true;
    final route = ModalRoute.of(context);
    Navigator.of(context).maybePop().then((_) {
      asking = false;
      // Still open: the route said no. Back to the detent it was opened at.
      if (mounted && route != null && route.isActive && controller.isAttached) {
        unawaited(
          controller.animateTo(
            widget.initialSize,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      extentHeight = box.maxHeight;
      return NotificationListener<DraggableScrollableNotification>(
        onNotification: onExtent,
        // ignore: raft_lints/avoid_raw_bottom_sheet -- the sheet's detents and nested-scroll coordination come from the framework
        child: DraggableScrollableSheet(
          controller: controller,
          expand: false,
          initialChildSize: widget.initialSize,
          minChildSize: _minSize,
          maxChildSize: RaftSheetMetrics.largeDetent,
          snap: true,
          snapSizes: snapSizes,
          // The framework closes at the bottom with a raw pop; this sheet asks.
          shouldCloseOnMinExtent: false,
          builder: (context, scroll) => widget.builder(scroll, this),
        ),
      );
    },
  );
}

/// Lets the route's super constructor take a builder that needs the route.
class _SheetBuilder {
  Widget Function(BuildContext)? target;
  Widget call(BuildContext context) => target!(context);
}

/// Opens [content] in the form [policy] gives the window's layout class.
Future<T?> showRaftPresented<T>(
  BuildContext context, {
  required RaftPresentationPolicy policy,
  required Widget Function(BuildContext context, RaftSurfaceForm form) content,
  String? label,
  RouteSettings? routeSettings,
  bool dismissible = true,
  double dialogMaxWidth = 560,
  double? dialogMaxHeight,
  bool dialogFillsHeight = false,
  bool sheetFillsHeight = false,
  double sheetInitialSize = RaftSheetMetrics.largeDetent,
  RaftSheetDetents? sheetDetents,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push(
    raftPresentedRoute<T>(
      context,
      policy: policy,
      content: content,
      label: label,
      routeSettings: routeSettings,
      dismissible: dismissible,
      dialogMaxWidth: dialogMaxWidth,
      dialogMaxHeight: dialogMaxHeight,
      dialogFillsHeight: dialogFillsHeight,
      sheetFillsHeight: sheetFillsHeight,
      sheetInitialSize: sheetInitialSize,
      sheetDetents: sheetDetents,
    ),
  );
}

/// The route [showRaftPresented] pushes, for hosts that keep the route (to
/// close it, or to know whether it is open).
RaftPresentedRoute<T> raftPresentedRoute<T>(
  BuildContext context, {
  required RaftPresentationPolicy policy,
  required Widget Function(BuildContext context, RaftSurfaceForm form) content,
  String? label,
  RouteSettings? routeSettings,
  bool dismissible = true,
  double dialogMaxWidth = 560,
  double? dialogMaxHeight,
  bool dialogFillsHeight = false,
  bool sheetFillsHeight = false,
  double sheetInitialSize = RaftSheetMetrics.largeDetent,
  RaftSheetDetents? sheetDetents,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final t = RaftTokens.of(context);
  return RaftPresentedRoute<T>(
    policy: policy,
    content: content,
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    initialForm: policy.formFor(raftLayoutClassOf(context)),
    panelColor: t.panel,
    sheetShape: RaftSheetMetrics.shape(t),
    label: label,
    settings: routeSettings,
    dismissible: dismissible,
    dialogMaxWidth: dialogMaxWidth,
    dialogMaxHeight: dialogMaxHeight,
    dialogFillsHeight: dialogFillsHeight,
    sheetFillsHeight: sheetFillsHeight,
    sheetInitialSize: sheetInitialSize,
    sheetDetents: sheetDetents,
  );
}

class _PresentedFrame extends StatelessWidget {
  const _PresentedFrame({required this.route, required this.form});
  final RaftPresentedRoute<dynamic> route;
  final RaftSurfaceForm form;

  @override
  Widget build(BuildContext context) {
    // The key lets the content move between frames with its state.
    final content = KeyedSubtree(
      key: route.contentKey,
      child: Builder(builder: (context) => route.content(context, form)),
    );
    switch (form) {
      case RaftSurfaceForm.page:
        return RaftPageFrame(child: content);
      case RaftSurfaceForm.side:
        return RaftSideFrame(width: route.sideWidth, child: content);
      case RaftSurfaceForm.dialog:
      case RaftSurfaceForm.popover:
      case RaftSurfaceForm.sheet:
        return RaftDialogFrame(
          maxWidth: route.dialogMaxWidth,
          maxHeight: route.dialogMaxHeight,
          fillsHeight: route.dialogFillsHeight,
          child: content,
        );
    }
  }
}

/// The dialog frame: centered with the dialog inset around it.
class RaftDialogFrame extends StatelessWidget {
  const RaftDialogFrame({
    super.key,
    required this.child,
    required this.maxWidth,
    this.maxHeight,
    this.fillsHeight = false,
  });
  final Widget child;
  final double maxWidth;
  final double? maxHeight;
  final bool fillsHeight;

  /// Space between the window edge and the dialog.
  static const inset = RaftSpace.x4;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final fixed = fillsHeight
        ? SizedBox(height: size.height - inset * 2, child: child)
        : child;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(inset),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              maxHeight: maxHeight ?? double.infinity,
            ),
            child: fixed,
          ),
        ),
      ),
    );
  }
}

/// The full-page frame: opaque, inside the system insets, above the keyboard.
class RaftPageFrame extends StatelessWidget {
  const RaftPageFrame({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return BlockSemantics(
      child: ColoredBox(
        color: t.panel,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: SafeArea(child: child),
          ),
        ),
      ),
    );
  }
}

/// The side-panel frame: docked to the trailing edge, full height.
class RaftSideFrame extends StatelessWidget {
  const RaftSideFrame({super.key, required this.child, required this.width});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final line = t.brutal ? Colors.black : t.colors['line-muted']!;
    return Align(
      alignment: AlignmentDirectional.centerEnd,
      child: SizedBox(
        width: width,
        height: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: t.panel,
            border: BorderDirectional(
              start: BorderSide(color: line, width: t.brutal ? 2 : 1),
            ),
          ),
          child: SafeArea(child: child),
        ),
      ),
    );
  }
}
