import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The yellow sticker with the pink hard shadow that names the screen. Tilted
/// -0.9 degrees.
class HfTitleSticker extends StatelessWidget {
  const HfTitleSticker(this.text, {super.key, this.maxLines = 2});
  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Semantics(
      header: true,
      child: Transform.rotate(
        angle: -0.9 * math.pi / 180,
        alignment: Alignment.centerLeft,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: hf.sp(16),
            vertical: hf.sp(4),
          ),
          decoration: BoxDecoration(
            color: HfColors.sticker,
            boxShadow: [
              BoxShadow(
                color: HfColors.mention,
                offset: Offset(hf.sp(4), hf.sp(4)),
              ),
            ],
          ),
          child: Text(
            text,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: hf.type(HfType.display),
          ),
        ),
      ),
    );
  }
}

/// A number in the colour of what it counts, with an ink outline.
class HfBadge extends StatelessWidget {
  const HfBadge(
    this.count, {
    super.key,
    required this.tone,
    this.small = false,
  });
  final int count;
  final HfTone tone;

  /// The size used in section labels.
  final bool small;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: hf.sp(small ? 6 : 8)),
      constraints: BoxConstraints(minWidth: hf.sp(small ? 28 : 34)),
      decoration: BoxDecoration(
        color: HfColors.of(tone),
        borderRadius: BorderRadius.circular(hf.sp(small ? 8 : 9)),
        border: Border.all(color: HfColors.ink, width: hf.sp(2.5)),
      ),
      // Shrink to the number: a box with an alignment would fill a Wrap.
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Text(
          '$count',
          style: hf.type(HfType.headline, base: small ? 16 : null),
        ),
      ),
    );
  }
}

/// One counted group of the count line.
@immutable
class HfCount {
  const HfCount(this.tone, this.count, this.label);
  final HfTone tone;
  final int count;

  /// What is counted, after the number: "件等你决定".
  final String label;
}

/// "② 件等你决定 · ① 件卡住了": the whole screen in one line. A group of
/// zero is left out. On a phone it wraps.
class HfCountLine extends StatelessWidget {
  const HfCountLine({super.key, required this.counts});
  final List<HfCount> counts;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final shown = [
      for (final c in counts)
        if (c.count > 0) c,
    ];
    final style = hf.type(HfType.count);
    return Semantics(
      label: [for (final c in shown) '${c.count}${c.label}'].join('，'),
      excludeSemantics: true,
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: hf.sp(6),
        children: [
          for (var i = 0; i < shown.length; i++)
            // A group stays whole: a wrap breaks between groups only.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (i > 0)
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: hf.sp(10)),
                    child: Text('·', style: style),
                  ),
                HfBadge(shown[i].count, tone: shown[i].tone),
                SizedBox(width: hf.sp(8)),
                Text(shown[i].label, style: style),
              ],
            ),
        ],
      ),
    );
  }
}

/// A group name with its count and a rule: "等你决定 ②".
class HfSectionLabel extends StatelessWidget {
  const HfSectionLabel(this.label, {super.key, this.count, required this.tone});
  final String label;
  final int? count;
  final HfTone tone;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Semantics(
      header: true,
      child: Row(
        children: [
          Text(label, style: hf.type(HfType.body)),
          if (count != null) ...[
            SizedBox(width: hf.sp(8)),
            HfBadge(count!, tone: tone, small: true),
          ],
          SizedBox(width: hf.sp(12)),
          Expanded(
            child: Container(height: hf.sp(2.5), color: HfColors.ink),
          ),
        ],
      ),
    );
  }
}

/// Cream block with a big number: "已等 / 3 / 天".
class HfStatBlock extends StatelessWidget {
  const HfStatBlock({
    super.key,
    required this.label,
    required this.value,
    this.unit,
  });
  final String label, value;
  final String? unit;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Container(
      color: HfColors.cream,
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(vertical: hf.sp(4), horizontal: hf.sp(4)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            style: hf.type(HfType.meta, color: HfColors.inkSoft),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, maxLines: 1, style: hf.type(HfType.stat)),
              if (unit != null) ...[
                SizedBox(width: hf.sp(4)),
                Text(unit!, maxLines: 1, style: hf.type(HfType.body)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
