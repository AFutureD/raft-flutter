import 'package:flutter/material.dart';

import '../layer_frame.dart';
import 'hf_basics.dart';
import 'hf_scope.dart';

/// The top of a screen: the title sticker and the count line. A phone stacks
/// them; wider screens (desktop, TV) put them on one line.
class HfHeader extends StatelessWidget {
  const HfHeader({super.key, required this.title, this.count, this.trailing});
  final String title;
  final Widget? count;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final end = trailing;
    if (hf.phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HfTitleSticker(title),
          if (count != null) ...[SizedBox(height: hf.sp(12)), count!],
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          // The sticker never takes more than half the line, so the count
          // line and the badge keep their room.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * .5),
            child: HfTitleSticker(title, maxLines: 1),
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

/// One whole hands-free screen: dotted canvas, margins by the spec, header,
/// body, the caption strip and (phone, desktop) the dock. The body scrolls
/// only where a finger or a mouse can; on a TV it is cut, so keep it to a
/// page.
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

  /// An [HfPager]. It is laid out under the body, outside its scroll, so it
  /// is never cut off.
  final Widget? pager;
  final Widget? caption, dock;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final gap = hf.sp(
      hf.tv
          ? 14
          : hf.phone
          ? 12
          : 10,
    );
    Widget? foot;
    if (caption != null && dock != null && !hf.tv) {
      foot = hf.phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                caption!,
                SizedBox(height: hf.sp(14)),
                dock!,
              ],
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
    return AgentCanvas(
      child: Padding(
        padding: hf.margin,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            SizedBox(height: gap),
            Expanded(
              child: SingleChildScrollView(
                physics: hf.interactive
                    ? const ClampingScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                padding: EdgeInsets.only(bottom: hf.sp(4), right: hf.sp(8)),
                child: body,
              ),
            ),
            if (pager != null) ...[SizedBox(height: gap), pager!],
            if (foot != null) ...[SizedBox(height: gap), foot],
          ],
        ),
      ),
    );
  }
}
