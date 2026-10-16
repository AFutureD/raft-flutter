import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

/// How urgent a priority item is. The order is the attention weight order.
enum AgentPriority { decision, blocked, mention, progress }

/// Labels for [AgentPriority]; apps may pass localized ones.
const agentPriorityLabels = {
  AgentPriority.decision: '等你决定',
  AgentPriority.blocked: '卡住了',
  AgentPriority.mention: '提到了你',
  AgentPriority.progress: '进展',
};

/// Visual settings for agent mode, kept outside raft_ui so the mode can
/// diverge from the product design system without touching it.
///
/// [RaftAgentTheme.of] uses an explicit [ThemeExtension] when the app supplies
/// one and otherwise derives defaults from the active [RaftTokens].
@immutable
class RaftAgentTheme extends ThemeExtension<RaftAgentTheme> {
  const RaftAgentTheme({
    required this.canvas,
    required this.layer,
    required this.backLayer,
    required this.card,
    required this.line,
    required this.foreground,
    required this.muted,
    required this.hint,
    required this.chip,
    required this.hud,
    required this.hudForeground,
    required this.orb,
    required this.orbHalo,
    required this.orbForeground,
    required this.priorityColors,
    required this.headingFont,
    required this.bodyFont,
    required this.fontFallback,
    required this.layerRadius,
    required this.cardRadius,
    required this.border,
    required this.orbSquare,
    required this.layerShadow,
    required this.topShadow,
    required this.cardShadow,
    this.cardFills,
    this.stickerLabels = false,
    this.weightNumerals = false,
    this.canvasDots,
    this.messageFill,
    this.titleSize = 22,
    this.titleWeight = FontWeight.w700,
    this.cardBorder,
    this.depthScale = .06,
    this.depthOffset = 34,
    this.depthFade = .28,
    this.visibleBehind = 2,
    this.leavingScale = .14,
    this.leavingOffset = 90,
    this.duration = const Duration(milliseconds: 380),
    this.curve = Curves.easeOutCubic,
  });

  final Color canvas, layer, backLayer, card, line, foreground, muted, hint;
  final Color chip, hud, hudForeground, orb, orbHalo, orbForeground;
  final Map<AgentPriority, Color> priorityColors;
  final String headingFont, bodyFont;
  final List<String> fontFallback;
  final double layerRadius, cardRadius, border;

  /// Brutal draws a square orb with a hard shadow; the others a circle.
  final bool orbSquare;
  final List<BoxShadow> layerShadow, topShadow, cardShadow;

  /// Full-color card backgrounds per priority (sticker board). Null keeps
  /// [card] with only a colored bar.
  final Map<AgentPriority, Color>? cardFills;

  /// Priority labels drawn as tilted bordered stickers.
  final bool stickerLabels;

  /// Weight drawn as a large numeral instead of bars.
  final bool weightNumerals;

  /// Dot-grid color for the canvas; null draws a plain canvas.
  final Color? canvasDots;

  /// Background of message tiles; null uses [card].
  final Color? messageFill;
  final double titleSize;
  final FontWeight titleWeight;

  /// Border width of cards; null uses [border].
  final double? cardBorder;

  /// Marker pen ink and highlighter colour for annotations.
  Color get markInk =>
      stickerLabels ? const Color(0xfffe2f8b) : priority(AgentPriority.mention);
  Color get markHighlight => stickerLabels ? const Color(0xffffd441) : orb;

  double get cardBorderWidth => cardBorder ?? border;

  /// Per step of depth behind the front layer.
  final double depthScale, depthOffset, depthFade;

  /// Layers drawn behind the front one. Deeper layers are not painted.
  final int visibleBehind;

  /// A layer leaving toward the viewer grows and drops by these at depth -1.
  final double leavingScale, leavingOffset;
  final Duration duration;
  final Curve curve;

  Color priority(AgentPriority p) => priorityColors[p] ?? foreground;

  TextStyle heading(double size, {FontWeight weight = FontWeight.w700}) =>
      TextStyle(
        fontFamily: headingFont,
        fontFamilyFallback: fontFallback,
        fontSize: size,
        fontWeight: weight,
        color: foreground,
        height: 1.3,
      );

  TextStyle body(double size, {Color? color, FontWeight? weight}) => TextStyle(
    fontFamily: bodyFont,
    fontFamilyFallback: fontFallback,
    fontSize: size,
    fontWeight: weight,
    color: color ?? foreground,
    height: 1.5,
  );

  /// Defaults for the active raft_ui theme family and brightness.
  factory RaftAgentTheme.fromRaft(RaftTokens t) {
    final c = t.semantic;
    final sh = t.themeShadows;
    return RaftAgentTheme(
      canvas: t.canvas,
      layer: t.panel,
      backLayer: t.brutal ? const Color(0xffc9b8ff) : t.card,
      card: t.brutal ? t.panel : t.card,
      line: t.brutal ? c.lineStrong : t.line,
      foreground: t.ink,
      muted: t.muted,
      hint: c.foregroundHint,
      chip: c.fillMuted,
      hud: c.layerHud,
      hudForeground: c.layerHudForeground,
      orb: c.primary400,
      orbHalo: c.primary400.withValues(alpha: t.dark ? .16 : .28),
      orbForeground: c.ink,
      priorityColors: {
        AgentPriority.decision: c.danger,
        AgentPriority.blocked: c.warning,
        AgentPriority.mention: c.accent500,
        AgentPriority.progress: c.success,
      },
      headingFont: t.headingFont,
      bodyFont: t.bodyFont,
      fontFallback: t.fontFallback,
      layerRadius: t.brutal ? 0 : t.radius + 12,
      cardRadius: t.brutal ? 0 : t.radius + 4,
      border: t.brutal ? 4 : t.border,
      orbSquare: t.brutal,
      layerShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(6, 6))]
          : sh.md.paintOrder,
      topShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(8, 8))]
          : sh.lg.paintOrder,
      cardShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(4, 4))]
          : const [],
      depthFade: t.dark ? .34 : .24,
      // Neo-brutalist sticker board (Kevin's pick): saturated full-color
      // cards, thick ink borders, hard shadows, tilted sticker labels,
      // large weight numerals on dot-grid paper.
      cardFills: t.brutal
          ? const {
              AgentPriority.decision: Color(0xffff5a69),
              AgentPriority.blocked: Color(0xffff9a4d),
              AgentPriority.mention: Color(0xffff8cc2),
              AgentPriority.progress: Color(0xff7fe3a9),
            }
          : null,
      stickerLabels: t.brutal,
      weightNumerals: t.brutal,
      canvasDots: t.brutal ? c.lineStrong.withValues(alpha: .35) : null,
      messageFill: null,
      titleSize: t.brutal ? 32 : 22,
      titleWeight: t.brutal ? FontWeight.w900 : FontWeight.w700,
      cardBorder: t.brutal ? 3 : null,
    );
  }

  static RaftAgentTheme of(BuildContext context) =>
      Theme.of(context).extension<RaftAgentTheme>() ??
      RaftAgentTheme.fromRaft(RaftTokens.of(context));

  @override
  RaftAgentTheme copyWith({
    double? depthScale,
    double? depthOffset,
    double? depthFade,
    int? visibleBehind,
    Duration? duration,
    Curve? curve,
    Map<AgentPriority, Color>? priorityColors,
  }) => RaftAgentTheme(
    canvas: canvas,
    layer: layer,
    backLayer: backLayer,
    card: card,
    line: line,
    foreground: foreground,
    muted: muted,
    hint: hint,
    chip: chip,
    hud: hud,
    hudForeground: hudForeground,
    orb: orb,
    orbHalo: orbHalo,
    orbForeground: orbForeground,
    priorityColors: priorityColors ?? this.priorityColors,
    headingFont: headingFont,
    bodyFont: bodyFont,
    fontFallback: fontFallback,
    layerRadius: layerRadius,
    cardRadius: cardRadius,
    border: border,
    orbSquare: orbSquare,
    layerShadow: layerShadow,
    topShadow: topShadow,
    cardShadow: cardShadow,
    cardFills: cardFills,
    stickerLabels: stickerLabels,
    weightNumerals: weightNumerals,
    canvasDots: canvasDots,
    messageFill: messageFill,
    titleSize: titleSize,
    titleWeight: titleWeight,
    cardBorder: cardBorder,
    depthScale: depthScale ?? this.depthScale,
    depthOffset: depthOffset ?? this.depthOffset,
    depthFade: depthFade ?? this.depthFade,
    visibleBehind: visibleBehind ?? this.visibleBehind,
    leavingScale: leavingScale,
    leavingOffset: leavingOffset,
    duration: duration ?? this.duration,
    curve: curve ?? this.curve,
  );

  @override
  RaftAgentTheme lerp(RaftAgentTheme? other, double t) =>
      other == null || t < .5 ? this : other;
}
