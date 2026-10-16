import 'package:flutter/material.dart';

import '../agent_theme.dart';
import '../scroll_fade.dart';
import 'hf_basics.dart';
import 'hf_scope.dart';
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

/// A header, a body that scrolls (a phone or a desktop; a TV is cut, so keep
/// it to a page) and a pager under it that is never cut off. This is the
/// content of one layer.
class HfLayerBody extends StatelessWidget {
  const HfLayerBody({
    super.key,
    required this.header,
    required this.body,
    this.pager,
    this.summary,
  });
  final Widget header, body;

  /// An [HfPager]. It is laid out under the body, outside its scroll.
  final Widget? pager;

  /// One line of what the layer says, under the header.
  final Widget? summary;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final gap = hfScreenGap(hf);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (summary != null) ...[SizedBox(height: hf.sp(8)), summary!],
        SizedBox(height: gap),
        Expanded(
          child: AgentScrollFade(
            // A desktop shows that there is more (a fade, a scrollbar); a
            // finger on a phone needs neither.
            enabled: hf.interactive && !hf.phone,
            builder: (context, controller) => SingleChildScrollView(
              controller: controller,
              physics: hf.interactive
                  ? const ClampingScrollPhysics()
                  : const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.only(bottom: hf.sp(10), right: hf.sp(8)),
              child: body,
            ),
          ),
        ),
        if (pager != null) ...[SizedBox(height: gap), pager!],
      ],
    );
  }
}

/// The frame of every screen: canvas, margins by the spec, [content], what
/// goes [above] the foot (a notice, a tray of cards), the caption strip and
/// (phone, desktop) the dock. A TV has no dock; its caption strip carries
/// the mood.
class HfScreenFrame extends StatelessWidget {
  const HfScreenFrame({
    super.key,
    required this.content,
    this.top,
    this.above,
    this.caption,
    this.dock,
    this.foot,
  });
  final Widget content;

  /// Chrome over the content (close, settings), small.
  final Widget? top;

  /// Between the content and the foot, with its own spacing (it may be
  /// empty: a tray of cards).
  final Widget? above;
  final Widget? caption, dock;

  /// The foot as one widget (a composite that lays out its own caption and
  /// dock); replaces [caption] and [dock].
  final Widget? foot;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final gap = hfScreenGap(hf);
    Widget? foot = this.foot;
    if (foot != null) {
      // as given
    } else if (caption != null && dock != null && !hf.tv) {
      foot = hf.phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [caption!, SizedBox(height: hf.sp(14)), dock!],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: caption!),
                SizedBox(width: hf.sp(28)),
                dock!,
              ],
            );
    } else {
      foot = caption ?? (hf.tv ? null : dock);
    }
    return HfCanvas(
      child: Padding(
        padding: hf.margin,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ?top,
            Expanded(child: content),
            ?above,
            if (foot != null) ...[SizedBox(height: gap), foot],
          ],
        ),
      ),
    );
  }
}

/// One whole hands-free screen: [HfScreenFrame] around a header, a body and
/// a pager.
class HfScreen extends StatelessWidget {
  const HfScreen({
    super.key,
    required this.header,
    required this.body,
    this.pager,
    this.caption,
    this.dock,
  });
  final Widget header, body;
  final Widget? pager;
  final Widget? caption, dock;

  @override
  Widget build(BuildContext context) => HfScreenFrame(
    content: HfLayerBody(header: header, body: body, pager: pager),
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
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
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
class HfLayerFrame extends StatelessWidget {
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
    this.pager,
  });
  final String title;

  /// A small note at the right of the title.
  final String? meta;
  final InlineSpan? summary;
  final Widget? count;
  final List<Widget> children;
  final bool loading;
  final String? error;

  /// The title types itself in (a screen the model composes).
  final bool enterTitle;
  final Widget? pager;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return HfLayerBody(
      header: HfHeader(
        title: title,
        count: count,
        enterTitle: enterTitle,
        trailing: (hf.phone ? null : HfChrome.of(context)) ??
            (meta == null
                ? null
                : Text(
                    meta!,
                    maxLines: 1,
                    style: hf.type(HfType.meta, color: HfColors.inkMuted),
                  )),
      ),
      summary: summary == null ? null : HfSummaryLine(summary!),
      pager: pager,
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
