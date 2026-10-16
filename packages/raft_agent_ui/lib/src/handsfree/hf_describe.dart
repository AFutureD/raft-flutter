import 'package:flutter/widgets.dart';

import '../entity_model.dart';

/// What a component says about itself in words: the one description of what it
/// draws. The voice model is given these, so it knows what the person sees.
///
/// A component builds its description from the same values it draws from (the
/// same private method returns the widget the screen shows and the one that
/// is described), so the two cannot drift apart. The parity tests render every
/// layer and check that each string drawn is in the description.

/// What the describer needs to know that the widget gets from its place in the
/// tree: its number, where the things it points at are read, the window.
@immutable
class HfDescribeEnv {
  const HfDescribeEnv({
    this.index,
    this.resolver,
    this.phone = true,
    this.front = true,
  });

  /// The number the component wears on the screen (what [HfItemScope] gives
  /// it when it is drawn); null for a component that is not numbered.
  final int? index;

  /// Reads the entities a card or a cell points at; without one they are
  /// "找不到" (the same as drawn without a scope).
  final AgentEntityResolver? resolver;

  /// A phone's layout; a wider window draws some things differently (the
  /// note beside a title is the window chrome's place there).
  final bool phone;

  /// The layer is the front one (the one with the window chrome in its
  /// header).
  final bool front;

  HfDescribeEnv at(int? index) => HfDescribeEnv(
    index: index,
    resolver: resolver,
    phone: phone,
    front: front,
  );
}

/// The words of one component.
@immutable
class HfDescription {
  const HfDescription(
    this.lines, {
    this.actions = const [],
    this.index,
    this.block = false,
  });

  /// Everything it draws as text, in reading order; each entry is one line
  /// (or one cell group) of the component.
  final List<String> lines;

  /// The buttons it offers, by their labels.
  final List<String> actions;

  /// The number it wears.
  final int? index;

  /// More than a row: the lines are told one under the other.
  final bool block;

  bool get isEmpty => lines.isEmpty && actions.isEmpty;

  /// Everything on one line, for a row.
  String get oneLine => lines.join(' ｜ ');
}

/// A widget that can describe what it draws.
abstract interface class HfDescribed {
  HfDescription describe(HfDescribeEnv env);
}

/// The non-empty, trimmed of [parts].
List<String> hfKept(Iterable<String?> parts) => [
  for (final p in parts)
    if (p != null && p.trim().isNotEmpty) p.trim(),
];
