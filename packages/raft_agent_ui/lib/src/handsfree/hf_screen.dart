import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:raft_ui/raft_ui.dart' show RaftSpace;

import '../agent_theme.dart';
import 'hf_basics.dart';
import 'hf_describe.dart';
import 'hf_page.dart';
import 'hf_scope.dart';
import 'hf_split.dart';
import 'hf_stage.dart';
import 'hf_tokens.dart';

/// The canvas every screen sits on: Raft UI's paper with its dots (the dots
/// are the theme's; a theme without them draws plain paper).
class HfCanvas extends StatelessWidget {
  const HfCanvas({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final dots = t.canvasDots;
    return ColoredBox(
      color: t.canvas,
      child: dots == null
          ? child
          : CustomPaint(painter: _DotGrid(dots), child: child),
    );
  }
}

class _DotGrid extends CustomPainter {
  _DotGrid(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const step = 18.0;
    for (var y = step / 2; y < size.height; y += step) {
      for (var x = step / 2; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.1, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DotGrid old) => old.color != color;
}

/// The top of a screen: the title sticker and the count line. A phone stacks
/// them; wider screens (desktop, TV) put them on one line. [trailing] is a
/// small note at the right of the title ("按紧急程度").
class HfHeader extends StatelessWidget {
  const HfHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.enterTitle = false,
  });
  final String title;
  final Widget? count;
  final Widget? trailing;

  /// The title types itself in, in step with the layer entering.
  final bool enterTitle;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final end = trailing;
    if (hf.phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(child: HfTitleSticker(title, enter: enterTitle)),
              if (end != null) ...[SizedBox(width: hf.sp(12)), end],
            ],
          ),
          if (count != null) ...[SizedBox(height: hf.sp(12)), count!],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          // The sticker never takes more than half the line, so the count
          // line keeps its room.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * .5),
            child: HfTitleSticker(title, maxLines: 1, enter: enterTitle),
          ),
          Expanded(
            child: count == null
                ? const SizedBox.shrink()
                : Center(child: count),
          ),
          ?end,
        ],
      ),
    );
  }
}

/// The gap between the parts of a screen.
double hfScreenGap(HfData hf) => hf.sp(hf.phone ? 12 : 10);

/// A header and the layer's page: everything else is one scroll (the summary
/// line, the [body], the stage of the current item and the [HfPageTail]).
/// This is the content of one layer.
///
/// On a desktop or a TV the header stays where it is, above the page. A
/// phone's header is by default the first part of the page: the small bar over
/// the page floats and the heading scrolls up under it with the rest. A layer
/// whose header has something to press (a conversation's tasks) sets
/// [scrollHeader] false: its header stays, under the bar.
///
/// The current item's stage goes where the item is, in the same page: beside
/// the list at the height of the current row on a wide window or a TV
/// ([HfSplit]), under the row on a phone (the row's [AgentFocusable] puts it
/// there). The page scrolls to the current item; see [HfPage].
class HfLayerBody extends StatelessWidget {
  const HfLayerBody({
    super.key,
    required this.header,
    required this.body,
    this.summary,
    this.scrollHeader = true,
  });
  final Widget header, body;

  /// One line of what the layer says, under the header.
  final Widget? summary;

  /// Whether a phone's header scrolls with the page.
  final bool scrollHeader;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final gap = hfScreenGap(hf);
    final scrolls = hf.phone && scrollHeader;
    final stage = HfStageScope.maybeOf(context);
    final tail = HfPageTail.of(context);
    final content = hf.split
        ? HfSplit(
            list: body,
            stage: stage?.stage,
            gap: hf.sp(28),
            snap: hf.sp(70),
          )
        : body;
    final page = HfPage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (scrolls) ...[header, SizedBox(height: gap)],
          if (summary != null) ...[summary!, SizedBox(height: gap)],
          content,
          if (tail != null) tail,
        ],
      ),
    );
    if (scrolls) return page;
    // A fixed header sits under the floating bar, and the page under it.
    final over = HfOverlayInsets.maybeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: over?.top ?? 0),
        header,
        SizedBox(height: gap),
        Expanded(
          child: over == null
              ? page
              : HfOverlayInsets(
                  bottom: over.bottom,
                  behind: over.behind,
                  child: page,
                ),
        ),
      ],
    );
  }
}

/// The frame of every screen: canvas, margins, [content], what goes [above]
/// the foot (a notice, a tray of cards), the caption strip and (phone,
/// desktop) the dock. A TV has no dock; its caption strip carries the mood.
///
/// The top bar ([top]) and the foot float over the content: the page scrolls
/// under them (see [HfOverlayInsets]), and behind each is a fade from the
/// canvas colour that shows only while content is behind it. Taps on the part
/// of an overlay that is only fade reach the page. The margins are the
/// device's safe area, which the screen puts around the frame, and one small
/// spacing token (see [HfData.margin]).
class HfScreenFrame extends StatefulWidget {
  const HfScreenFrame({
    super.key,
    required this.content,
    this.top,
    this.above,
    this.tail,
    this.caption,
    this.dock,
    this.foot,
  });
  final Widget content;

  /// Chrome over the content (close, settings), small. It floats.
  final Widget? top;

  /// Between the content and the foot, with its own spacing (it may be
  /// empty: a tray of cards).
  final Widget? above;

  /// What goes at the end of the layer's page (the confirm cards that wait
  /// for an answer): it scrolls with the page, whatever its height.
  final Widget? tail;
  final Widget? caption, dock;

  /// The foot as one widget (a composite that lays out its own caption and
  /// dock); replaces [caption] and [dock].
  final Widget? foot;

  @override
  State<HfScreenFrame> createState() => _HfScreenFrameState();
}

class _HfScreenFrameState extends State<HfScreenFrame> {
  /// The heights of the floating top bar and foot, as laid out.
  double _topH = 0, _footH = 0;
  final _behind = ValueNotifier<HfBehind>((top: false, bottom: false));

  @override
  void dispose() {
    _behind.dispose();
    super.dispose();
  }

  void _measured({double? top, double? foot}) {
    if (!mounted) return;
    if ((top == null || top == _topH) && (foot == null || foot == _footH)) {
      return;
    }
    setState(() {
      _topH = top ?? _topH;
      _footH = foot ?? _footH;
    });
  }

  Widget? _foot(HfData hf) {
    final w = widget;
    if (w.foot != null) return w.foot;
    if (w.caption != null && w.dock != null && !hf.tv) {
      return hf.phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                w.caption!,
                SizedBox(height: hf.sp(14)),
                w.dock!,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: w.caption!),
                SizedBox(width: hf.sp(28)),
                w.dock!,
              ],
            );
    }
    return w.caption ?? (hf.tv ? null : w.dock);
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final gap = hfScreenGap(hf);
    final m = hf.margin;
    final foot = _foot(hf);
    final top = widget.top;
    final above = widget.above;
    final fade = hf.sp(RaftSpace.x3);
    final canvas = RaftAgentTheme.of(context).canvas;
    final clear = canvas.withValues(alpha: 0);

    Widget fadeLayer(Key key, bool towardsTop) => Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<HfBehind>(
          valueListenable: _behind,
          builder: (context, b, _) => AnimatedOpacity(
            opacity: (towardsTop ? b.top : b.bottom) ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            // The top bar is solid behind its text, so a row passing under it
            // never shows through; only the [fade] band at its lower edge
            // turns clear. Rows stay visible, fading out, behind the dock.
            child: LayoutBuilder(
              builder: (context, c) {
                final h = c.maxHeight;
                final band = h > 0 ? (fade / h).clamp(0.0, 1.0) : 1.0;
                return DecoratedBox(
                  key: key,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: towardsTop
                          ? [canvas, canvas, clear]
                          : [clear, canvas],
                      stops: towardsTop ? [0, 1 - band, 1] : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );

    // The top bar floats at the very top, the foot at the very bottom; the
    // page under them is padded by their heights.
    final topBar = top == null
        ? null
        : Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: _SizeReporter(
              onSize: (s) => _measured(top: s.height),
              child: Stack(
                children: [
                  fadeLayer(const ValueKey('hf-top-fade'), true),
                  Padding(
                    padding: EdgeInsets.fromLTRB(m.left, m.top, m.right, fade),
                    child: top,
                  ),
                ],
              ),
            ),
          );
    final bottomBar = foot == null && above == null
        ? null
        : Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _SizeReporter(
              onSize: (s) => _measured(foot: s.height),
              child: Stack(
                children: [
                  fadeLayer(const ValueKey('hf-dock-fade'), false),
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      m.left,
                      fade,
                      m.right,
                      m.bottom,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        ?above,
                        if (foot != null) ...[
                          if (above != null) SizedBox(height: gap),
                          foot,
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );

    return HfCanvas(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            // What has no overlay keeps the margin as plain padding.
            padding: EdgeInsets.fromLTRB(
              m.left,
              top == null ? m.top : 0,
              m.right,
              bottomBar == null ? m.bottom : 0,
            ),
            child: HfOverlayInsets(
              top: _topH,
              bottom: bottomBar == null ? 0 : _footH,
              behind: _behind,
              child: HfPageTail(tail: widget.tail, child: widget.content),
            ),
          ),
          ?topBar,
          ?bottomBar,
        ],
      ),
    );
  }
}

/// Reports the size its child is laid out at (after the frame, so the owner
/// can rebuild with it).
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSizeReporter renderObject,
  ) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);
  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final reported = size;
    SchedulerBinding.instance.addPostFrameCallback((_) => onSize(reported));
  }
}

/// One whole hands-free screen: [HfScreenFrame] around a header and a body.
class HfScreen extends StatelessWidget {
  const HfScreen({
    super.key,
    required this.header,
    required this.body,
    this.caption,
    this.dock,
  });
  final Widget header, body;
  final Widget? caption, dock;

  @override
  Widget build(BuildContext context) => HfScreenFrame(
    content: HfLayerBody(header: header, body: body),
    caption: caption,
    dock: dock,
  );
}

/// What a layer says in a line under its header: the takeaway.
class HfSummaryLine extends StatelessWidget {
  const HfSummaryLine(this.span, {super.key, this.error = false});
  final InlineSpan span;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Text.rich(
      span,
      style: hf.type(
        HfType.body,
        color: error ? HfColors.decision : HfColors.inkSoft,
      ),
    );
  }
}

/// What a layer's header carries at its right on a desktop window (the close
/// button, the settings): the screen puts it around the front layer. A phone
/// has no room in its header and keeps these in a bar of their own.
class HfChrome extends InheritedWidget {
  const HfChrome({super.key, required this.trailing, required super.child});
  final Widget trailing;

  static Widget? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HfChrome>()?.trailing;

  @override
  bool updateShouldNotify(HfChrome old) => old.trailing != trailing;
}

/// One layer of agent mode: its header (title, a note, the count line), what
/// it says in a line, a spinner while it loads or the reason it could not,
/// and its [children] as the body.
class HfLayerFrame extends StatelessWidget implements HfDescribed {
  const HfLayerFrame({
    super.key,
    required this.title,
    this.meta,
    this.summary,
    this.count,
    this.children = const [],
    this.loading = false,
    this.error,
    this.enterTitle = false,
    this.scrollHeader = true,
  });
  final String title;

  /// Whether a phone's header scrolls with the page (see [HfLayerBody]).
  final bool scrollHeader;

  /// A small note at the right of the title.
  final String? meta;
  final InlineSpan? summary;
  final Widget? count;
  final List<Widget> children;
  final bool loading;
  final String? error;

  /// The title types itself in (a screen the model composes).
  final bool enterTitle;

  /// The words of the header, the line under it and the error: what the layer
  /// says about itself. [children] are described by their owner.
  @override
  HfDescription describe(HfDescribeEnv env) => HfDescription([
    title,
    // A wide window's front layer has the window chrome where the note goes.
    if (meta != null && (env.phone || !env.front)) meta!,
    if (summary != null) summary!.toPlainText(),
    if (count is HfDescribed) ...(count! as HfDescribed).describe(env).lines,
    ?error,
  ], block: true);

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return HfLayerBody(
      scrollHeader: scrollHeader,
      header: HfHeader(
        title: title,
        count: count,
        enterTitle: enterTitle,
        trailing:
            (hf.phone ? null : HfChrome.of(context)) ??
            (meta == null
                ? null
                : Text(
                    meta!,
                    maxLines: 1,
                    style: hf.type(HfType.meta, color: HfColors.inkMuted),
                  )),
      ),
      summary: summary == null ? null : HfSummaryLine(summary!),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading)
            Padding(
              padding: EdgeInsets.all(hf.sp(24)),
              child: Center(
                child: SizedBox.square(
                  dimension: hf.sp(24),
                  child: CircularProgressIndicator(
                    strokeWidth: hf.sp(3),
                    color: HfColors.ink,
                  ),
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: EdgeInsets.all(hf.sp(8)),
              child: Text(
                error!,
                style: hf.type(HfType.body, color: HfColors.decision),
              ),
            ),
          ...children,
        ],
      ),
    );
  }
}
