import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../agent_theme.dart';

/// Which kind of screen the hands-free components are drawn for. Same
/// components everywhere; only size, layout and whether things can be
/// pressed change.
enum HfSurface { phone, desktop, tv }

/// What a row, badge or shadow means. Colour follows meaning, never rank.
enum HfTone { decision, blocked, mention, progress, info, sticker }

/// The Raft UI hands-free palette (spec §2).
abstract final class HfColors {
  /// 等你决定
  static const decision = Color(0xffff5a69);

  /// 卡住了
  static const blocked = Color(0xffff9a4d);

  /// 点名你
  static const mention = Color(0xffff8cc2);

  /// 进行中
  static const progress = Color(0xff7fe0a6);

  /// 信息
  static const info = Color(0xff2ccbf0);

  /// 强调: title sticker, primary button.
  static const sticker = Color(0xffffd441);
  static const cream = Color(0xfffff0bd);
  static const ink = Color(0xff141110);
  static const card = Color(0xffffffff);

  /// Secondary text on white and cream.
  static const inkSoft = Color(0xff57524c);

  /// Small labels (channel, reason, time).
  static const inkMuted = Color(0xff6b6660);

  static Color of(HfTone tone) => switch (tone) {
    HfTone.decision => decision,
    HfTone.blocked => blocked,
    HfTone.mention => mention,
    HfTone.progress => progress,
    HfTone.info => info,
    HfTone.sticker => sticker,
  };

  static HfTone toneOf(AgentPriority p) => switch (p) {
    AgentPriority.decision => HfTone.decision,
    AgentPriority.blocked => HfTone.blocked,
    AgentPriority.mention => HfTone.mention,
    AgentPriority.progress => HfTone.progress,
  };
}

/// The type ramp (spec §1), base sizes at s = 1.
enum HfType {
  display(30, FontWeight.w900, true),
  rank(40, FontWeight.w900, true),
  stat(34, FontWeight.w900, true),
  headline(22, FontWeight.w900, true),
  count(24, FontWeight.w900, true),
  body(15, FontWeight.w800, false),
  meta(13, FontWeight.w800, false);

  const HfType(this.size, this.weight, this.heading);
  final double size;
  final FontWeight weight;

  /// Set in the heading face; the rest in the body face.
  final bool heading;
}

/// The "far-view unit" s: every size is a base value times s.
abstract final class HfScale {
  static const min = 1.0;
  static const max = 3.0;

  /// A phone is 412 wide; a layout is 540 tall at s = 1.
  static const baseWidth = 412.0;
  static const baseHeight = 540.0;

  /// `clamp(min(height / 540, width / 412), 1, 3)`
  static double of(Size size) => math
      .min(size.height / baseHeight, size.width / baseWidth)
      .clamp(min, max);

  /// Windows from this width on show a list with the detail beside it.
  static const splitWidth = 1280.0;

  /// From this width a window counts as a desktop, not a phone.
  static const desktopWidth = 700.0;
}
