import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

/// How urgent a priority item is. The order is the attention weight order.
enum AgentPriority { decision, blocked, mention, progress }

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
      backLayer: t.brutal ? c.fillMuted : t.card,
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
      border: t.border,
      orbSquare: t.brutal,
      layerShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(4, 4))]
          : sh.md.paintOrder,
      topShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(6, 6))]
          : sh.lg.paintOrder,
      cardShadow: t.brutal
          ? [BoxShadow(color: c.lineStrong, offset: const Offset(2, 2))]
          : const [],
      depthFade: t.dark ? .34 : .24,
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
