import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// What fits on a page. A hands-free screen shows a few rows and a pager for
/// the rest, and how many is a matter of the space and of how long the words
/// are: three rows of one line each are not three rows of three. These
/// measure a row the way [HfRow] lays it out, so a view can fill its page
/// with as many whole rows as fit (never more than the surface's cap) and a TV, which
/// cannot scroll, never cuts one off.
abstract final class HfFit {
  /// Height of [text] set in [style] over [width] px, in at most [lines].
  static double text(
    String text,
    TextStyle style,
    double width,
    int lines,
    TextScaler scaler,
  ) {
    if (text.isEmpty) return 0;
    final p = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: lines,
    )..layout(maxWidth: width.clamp(1, double.infinity));
    final h = p.height;
    p.dispose();
    return h;
  }

  /// The height in px of an [HfRow] [width] px wide with these texts. [stat]
  /// is whether it has a stat block.
  static double row(
    HfData hf,
    TextScaler scaler, {
    required double width,
    required String title,
    String? meta,
    String? detail,
    bool badge = false,
    bool stat = false,
    int titleLines = 2,
    int detailLines = 1,
    double? verticalPad,
  }) {
    final wide = width / hf.s >= 560;
    final bar = hf.sp(wide ? 78 : 56);
    final side = stat ? hf.sp(wide ? 150 : 96) : 0.0;
    final pad = hf.sp(wide ? 18 : 12);
    final inner = width - bar - side - 2 * pad;
    var h = 0.0;
    if (meta != null && meta.isNotEmpty || badge) {
      h += hf.type(HfType.meta).fontSize! * 1.2 + (badge ? hf.sp(2) : 0);
    }
    h += text(title, hf.type(HfType.headline), inner, titleLines, scaler);
    if (detail != null && detail.isNotEmpty) {
      h += text(detail, hf.type(HfType.body), inner, detailLines, scaler);
    }
    h += 2 * hf.sp(verticalPad ?? hf.rowPad);
    // The stat block: a word, a big number.
    final block =
        (hf.type(HfType.meta).fontSize! + hf.type(HfType.stat).fontSize!) *
            1.2 +
        hf.sp(8);
    return (stat && block > h ? block : h) * 1.03;
  }

  /// The header of a layer: the title sticker, and on a phone the count line
  /// under it.
  static double header(HfData hf, {bool count = false}) {
    final sticker = hf.sp(30 * 1.2 + 8);
    return hf.phone && count ? sticker + hf.sp(12 + 36) : sticker;
  }

  /// A section label with the gap under it.
  static double section(HfData hf) => hf.sp(25 + 8);
}
