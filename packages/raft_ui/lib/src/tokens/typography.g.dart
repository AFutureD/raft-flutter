// GENERATED — do not edit. Regenerate with `tool/gen-tokens`.
// Source: control-typography.json (authored in-repo; Flutter-only policy, no Web CSS counterpart)
// dart format off

/// Typography policy tokens for single-line control labels.
///
/// Flutter centres a font's line box, not the visible glyphs. The Android system
/// CJK fallback draws Chinese ink above that centre, so single-line control labels
/// (badges, chips, buttons, tabs, segments) use a taller, proportionally split line
/// there. See `RaftControlTypography` and docs/android-cjk-control-typography.md.
abstract final class RaftControlTypographyTokens {
  /// `control.androidChineseLineHeight`: `TextStyle.height` factor.
  static const double androidChineseLineHeight = 1.3;
}
