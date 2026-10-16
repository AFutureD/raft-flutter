import 'package:flutter/material.dart';

import '../layer_frame.dart';
import 'hf_basics.dart';
import 'hf_scope.dart';

/// The top of a screen: the title sticker and the count line. A phone stacks
/// them; wider screens put them on one line, with "在手机上处理" at the right
/// on a TV.
class HfHeader extends StatelessWidget {
  const HfHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.phoneHint = true,
  });
  final String title;
  final Widget? count;
  final Widget? trailing;

  /// A TV shows the "在手机上处理" badge at the right.
  final bool phoneHint;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final end = trailing ?? (hf.tv && phoneHint ? const HfPhoneBadge() : null);
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
    this.caption,
    this.dock,
  });
  final Widget header, body;
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
            if (foot != null) ...[SizedBox(height: gap), foot],
          ],
        ),
      ),
    );
  }
}
