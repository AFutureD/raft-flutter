// raft-ui 0.7.1 role tokens and type styles for the ported core components.
//
// The components in lib/src/raft/ read the official 0.7.1 names (`sticker-ink`,
// `fill-pressed`, `line-hairline`, ...) straight from [RaftLight] / [RaftDark] instead of the 0.5.52 field
// schemas the older code still uses (see docs/design-tokens.md, "raft-ui 0.7.1 single look").
import 'package:flutter/material.dart';

import '../theme.dart'
    show RaftTokens, raftCssTextHeightBehavior, raftFontWeight;
import '../tokens/tokens.dart';

/// Colours of one mode, by official token name. Typed getters cover what the
/// ported components use; [] reads any other token (`palette-yellow-400`).
@immutable
class RaftUiColors {
  const RaftUiColors._(this.dark, this._colors);

  static const RaftUiColors light = RaftUiColors._(false, RaftLight.colors);
  static const RaftUiColors darkMode = RaftUiColors._(true, RaftDark.colors);

  static RaftUiColors of(bool dark) => dark ? darkMode : light;

  final bool dark;
  final Map<String, Color> _colors;

  Color operator [](String token) =>
      _colors[token] ??
      (throw ArgumentError.value(
        token,
        'token',
        'unknown raft-ui 0.7.1 colour token',
      ));

  Color get foreground => this['foreground'];
  Color get foregroundMuted => this['foreground-muted'];
  Color get foregroundHint => this['foreground-hint'];
  Color get foregroundDisabled => this['foreground-disabled'];
  Color get foregroundOnFrame => this['foreground-on-frame'];
  Color get layerCanvas => this['layer-canvas'];
  Color get layerCard => this['layer-card'];
  Color get layerFrame => this['layer-frame'];
  Color get layerSidebar => this['layer-sidebar'];
  Color get fillMuted => this['fill-muted'];
  Color get fillPressed => this['fill-pressed'];
  Color get fillFramePressed => this['fill-frame-pressed'];
  Color get lineStrong => this['line-strong'];
  Color get lineHairline => this['line-hairline'];
  Color get lineSeam => this['line-seam'];
  Color get lineField => this['line-field'];
  Color get stickerInk => this['sticker-ink'];
  Color get stickerPaper => this['sticker-paper'];
  Color get stickerEdge => this['sticker-edge'];
  Color get stickerPressed => this['sticker-pressed'];
  Color get brand => this['brand-400'];
  Color get attention => this['attention-400'];
  Color get info => this['info'];
  Color get success => this['success'];
  Color get warning => this['warning'];
  Color get danger => this['danger'];
  Color get dangerStrong => this['danger-strong'];
  Color get inactive => this['inactive'];

  /// `--presence-*`: online, busy, error, offline, external.
  Color presence(String name) => this['presence-$name'];

  /// The outer focus ring (`--focus-ring`: 2px surface gap, 2px ink).
  RaftShadow get focusRing => dark ? RaftDark.focusRing : RaftLight.focusRing;
}

/// 0.7.1 type styles and colours for the active mode.
extension RaftTokensUi on RaftTokens {
  RaftUiColors get ui => RaftUiColors.of(dark);

  /// A named style of the Raft type scale ([RaftTypeScale]) as a Flutter [TextStyle]:
  /// Space Grotesk (or Space Mono for [mono]), CSS half-leading, the scale's own weight and tracking unless
  /// overridden. `weight` follows CSS (`font-bold` is 700).
  TextStyle scale(
    RaftTypeStyle style, {
    FontWeight? weight,
    Color? color,
    bool mono = false,
    double? trackingEm,
  }) {
    final w =
        weight ??
        (style.fontWeight == null
            ? FontWeight.w400
            : raftFontWeight(style.fontWeight!.toDouble()));
    final tracking = trackingEm ?? style.letterSpacingEm ?? 0;
    return TextStyle(
      locale: textLocale,
      fontFamily: mono ? monoFont : bodyFont,
      fontFamilyFallback: mono ? const ['monospace'] : fontFallback,
      fontSize: style.fontSize,
      height: style.height,
      fontWeight: w,
      letterSpacing: tracking * style.fontSize,
      leadingDistribution: raftCssTextHeightBehavior.leadingDistribution,
      color: color ?? ui.foreground,
    );
  }
}
