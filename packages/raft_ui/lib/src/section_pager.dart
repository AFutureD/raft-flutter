import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

/// Controlled section paging. The owner supplies the accepted selection;
/// neighboring pages do not mount their content until first selected.
///
/// Visited pages retain their elements. Inactive pages cannot receive focus,
/// pointer input or accessibility actions, and their tickers are suspended.
/// Swipes commit after scrolling stops, so owners do not mount data views or
/// change the outgoing page's presentation during the drag/settling frames.
/// Change [key] when the authority owning the content changes.
class RaftSectionPager<T extends Object> extends StatefulWidget {
  const RaftSectionPager({
    super.key,
    required this.sections,
    required this.value,
    required this.onChanged,
    required this.builder,
    this.swipeEnabled = true,
    this.initiallyMounted = const [],
    this.unvisitedBuilder,
  }) : assert(sections.length > 0);

  final List<T> sections;
  final T value;

  /// Null when navigation is owned by controls outside the pager.
  /// Such a pager exposes no section keyboard or accessibility actions.
  final ValueChanged<T>? onChanged;
  final Widget Function(BuildContext, T) builder;
  final WidgetBuilder? unvisitedBuilder;
  final bool swipeEnabled;
  final List<T> initiallyMounted;

  @override
  State<RaftSectionPager<T>> createState() => _RaftSectionPagerState<T>();
}

class _RaftSectionPagerState<T extends Object>
    extends State<RaftSectionPager<T>> {
  late final PageController controller = PageController(
    initialPage: index,
    keepPage: false,
  );
  late final Set<T> visited = {...widget.initiallyMounted, widget.value};
  late final selection = ValueNotifier<T>(widget.value);
  int syncRevision = 0;
  bool synchronizing = false;
  T? reportedSwipe;
  int get index => widget.sections
      .indexOf(widget.value)
      .clamp(0, widget.sections.length - 1);

  @override
  void didUpdateWidget(RaftSectionPager<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    visited.removeWhere((id) => !widget.sections.contains(id));
    visited.add(widget.value);
    selection.value = widget.value;
    final fromSwipe = widget.value == reportedSwipe;
    reportedSwipe = null;
    if (oldWidget.value != widget.value && !fromSwipe ||
        !listEquals(oldWidget.sections, widget.sections)) {
      synchronizing = true;
      final revision = ++syncRevision;
      if (controller.hasClients && controller.position.hasViewportDimension) {
        controller.jumpToPage(index);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || revision != syncRevision) return;
        if (controller.hasClients && controller.page != index.toDouble()) {
          // Jumping directly also avoids activating intermediate sections
          // (and starting their reads) when a distant tab is clicked.
          controller.jumpToPage(index);
        }
        synchronizing = false;
      });
    }
  }

  void select(int next) {
    if (next < 0 || next >= widget.sections.length) return;
    final value = widget.sections[next];
    if (value != widget.value) widget.onChanged?.call(value);
  }

  @override
  void dispose() {
    ++syncRevision;
    controller.dispose();
    selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      if (widget.onChanged != null)
        const SingleActivator(LogicalKeyboardKey.pageDown, control: true): () =>
            select(index + 1),
      if (widget.onChanged != null)
        const SingleActivator(LogicalKeyboardKey.pageUp, control: true): () =>
            select(index - 1),
    },
    child: Semantics(
      onIncrease: widget.onChanged != null && index + 1 < widget.sections.length
          ? () => select(index + 1)
          : null,
      onDecrease: widget.onChanged != null && index > 0
          ? () => select(index - 1)
          : null,
      child: NotificationListener<ScrollEndNotification>(
        onNotification: (notification) {
          if (notification.depth != 0 ||
              notification.metrics.axis != Axis.horizontal ||
              synchronizing ||
              !controller.hasClients) {
            return false;
          }
          final page = controller.page?.round();
          if (page != null && page >= 0 && page < widget.sections.length) {
            reportedSwipe = widget.sections[page];
            select(page);
          }
          return false;
        },
        child: _SystemBackEdgeBoundary(
          view: View.of(context),
          insets: Theme.of(context).platform == TargetPlatform.android
              ? MediaQuery.systemGestureInsetsOf(context)
              : EdgeInsets.zero,
          child: PageView.builder(
            controller: controller,
            physics: widget.swipeEnabled
                ? const PageScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            itemCount: widget.sections.length,
            findChildIndexCallback: (key) {
              if (key is! ValueKey<T>) return null;
              final i = widget.sections.indexOf(key.value);
              return i >= 0 ? i : null;
            },
            itemBuilder: (context, i) {
              final id = widget.sections[i];
              return _RetainedSection<T>(
                key: ValueKey<T>(id),
                section: id,
                selection: selection,
                child: visited.contains(id)
                    ? widget.builder(context, id)
                    : widget.unvisitedBuilder?.call(context) ??
                          const SizedBox.expand(),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _RetainedSection<T extends Object> extends StatefulWidget {
  const _RetainedSection({
    super.key,
    required this.child,
    required this.section,
    required this.selection,
  });
  final Widget child;
  final T section;
  final ValueListenable<T> selection;
  @override
  State<_RetainedSection<T>> createState() => _RetainedSectionState<T>();
}

class _RetainedSectionState<T extends Object> extends State<_RetainedSection<T>>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    // Kept-alive sliver children need not re-enter itemBuilder when selection
    // changes. Update their presentation directly, including offscreen pages.
    return ValueListenableBuilder<T>(
      valueListenable: widget.selection,
      child: widget.child,
      builder: (context, selected, child) {
        final active = selected == widget.section;
        return TickerMode(
          enabled: active,
          child: ExcludeFocus(
            excluding: !active,
            child: ExcludeSemantics(
              excluding: !active,
              child: IgnorePointer(ignoring: !active, child: child),
            ),
          ),
        );
      },
    );
  }
}

// System back owns gestures which *start* in the display's side insets. Do
// not let the PageView or its content enter their gesture arenas at all: a
// late drag cancellation can already have scrolled a page or started a child
// action. This changes hit testing only; content still paints edge to edge.
class _SystemBackEdgeBoundary extends SingleChildRenderObjectWidget {
  const _SystemBackEdgeBoundary({
    required this.view,
    required this.insets,
    required super.child,
  });

  final ui.FlutterView view;
  final EdgeInsets insets;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSystemBackEdgeBoundary(view, insets);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSystemBackEdgeBoundary renderObject,
  ) {
    renderObject
      ..view = view
      ..insets = insets;
  }
}

class _RenderSystemBackEdgeBoundary extends RenderProxyBox {
  _RenderSystemBackEdgeBoundary(this.view, this.insets);

  ui.FlutterView view;
  EdgeInsets insets;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position) && (insets.left > 0 || insets.right > 0)) {
      // Insets are physical display edges, not logical start/end or the local
      // bounds of a panel. Flutter pointer coordinates are in logical pixels.
      final x = localToGlobal(position).dx;
      final displayWidth = view.physicalSize.width / view.devicePixelRatio;
      if (x < insets.left || x >= displayWidth - insets.right) return true;
    }
    return super.hitTest(result, position: position);
  }
}
