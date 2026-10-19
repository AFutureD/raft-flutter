import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import 'component_colors.g.dart';
import 'metrics.g.dart';
import 'product_colors.g.dart';
import 'raft_token_mapping.dart';
import 'raft_tokens.g.dart';
import 'semantic_colors.g.dart';
import 'shadows.g.dart';

/// Bundled design faces (`packages/raft_ui/assets/fonts`, pubspec families).
const String raftSansFontFamily = 'packages/raft_ui/SpaceGrotesk';
const String raftMonoFontFamily = 'packages/raft_ui/SpaceMono';

/// raft-ui 0.7.1 `fonts.css`: `--heading-font` and `--sans-font` are the same stack.
const List<String> raftSansFontStack = [
  'Space Grotesk',
  'PingFang SC',
  'Hiragino Sans GB',
  'Microsoft YaHei',
  'Noto Sans SC',
  'system-ui',
  'sans-serif',
];

/// `--mono-font`.
const List<String> raftMonoFontStack = [
  'Space Mono',
  'ui-monospace',
  'SF Mono',
  'Menlo',
  'monospace',
];

/// The Raft Design System has one look in two modes.
enum RaftThemeId { light, dark }

/// Everything one mode resolves to: semantic, product and component colours,
/// shadows and metrics, filled from [RaftLight] / [RaftDark] through the tables
/// in raft_token_mapping.dart.
@immutable
class RaftTokenSet {
  const RaftTokenSet._(
    this.id,
    this.colors,
    this.product,
    this.components,
    this.shadows,
    this.metrics,
  );
  final RaftThemeId id;
  final RaftSemanticColors colors;
  final RaftProductColors product;
  final RaftComponentColors components;
  final RaftThemeShadows shadows;
  final RaftThemeMetrics metrics;

  static final RaftTokenSet light = _build(RaftThemeId.light);
  static final RaftTokenSet dark = _build(RaftThemeId.dark);

  static RaftTokenSet of(RaftThemeId id) => switch (id) {
    RaftThemeId.light => light,
    RaftThemeId.dark => dark,
  };

  static RaftTokenSet _build(RaftThemeId id) {
    final dark = id == RaftThemeId.dark;
    final tokens = dark ? RaftDark.colors : RaftLight.colors;
    final shadows = dark ? RaftDark.shadows : RaftLight.shadows;
    Map<String, Color> colors(Map<String, String> table) => {
      for (final e in table.entries)
        e.key: e.value == raftTransparentToken
            ? const Color(0x00000000)
            : tokens[e.value] ??
                  (throw StateError('${e.key}: no 0.7.1 token ${e.value}')),
    };
    RaftShadow shadow(String name) {
      final token = raftShadowMapping[name]!;
      return token == raftNoShadowToken
          ? const RaftShadow([])
          : shadows[token]!;
    }

    double metric(String field) => raftCarriedMetrics[field]!;
    return RaftTokenSet._(
      id,
      RaftSemanticColors.fromCssMap(colors(raftSemanticMapping)),
      RaftProductColors.fromCssMap(colors(raftProductMapping)),
      RaftComponentColors.fromCssMap(colors(raftComponentMapping)),
      RaftThemeShadows(
        xs: shadow('theme-shadow-xs'),
        sm: shadow('theme-shadow-sm'),
        md: shadow('theme-shadow-md'),
        lg: shadow('theme-shadow-lg'),
        xl: shadow('theme-shadow-xl'),
      ),
      RaftThemeMetrics(
        fieldFontSize: metric('fieldFontSize'),
        fieldFontWeight: metric('fieldFontWeight'),
        fieldLineHeight: metric('fieldLineHeight'),
        cardTitleFontSize: metric('cardTitleFontSize'),
        cardTitleFontWeight: metric('cardTitleFontWeight'),
        cardTitleLineHeight: metric('cardTitleLineHeight'),
        // raft-ui 0.7.1 fonts.css `--heading-font` / `--sans-font` / `--mono-font`.
        headingFontStack: raftSansFontStack,
        sansFontStack: raftSansFontStack,
        monoFontStack: raftMonoFontStack,
        headingFont: raftSansFontFamily,
        sansFont: raftSansFontFamily,
        monoFont: raftMonoFontFamily,
      ),
    );
  }
}
