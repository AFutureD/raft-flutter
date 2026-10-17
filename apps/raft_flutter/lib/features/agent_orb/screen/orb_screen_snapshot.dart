import 'package:flutter/semantics.dart';

/// The `identifier` of the Semantics node that wraps everything the orb
/// draws (the ball, its pills, the layer). The screen reader leaves that
/// subtree out: the orb must not read itself back to the model.
const orbSemanticsIdentifier = 'raft-agent-orb';

/// One thing on the screen the person (or the model) can act on.
class OrbScreenNode {
  OrbScreenNode({
    required this.id,
    required this.role,
    required this.label,
    required this.actions,
    required this.node,
    this.hint = '',
    this.value = '',
    this.enabled = true,
    this.selected,
    this.checked,
    this.focused = false,
    this.visible = true,
    this.at = '',
  });

  /// Short id of the snapshot: `a` and the semantics node's number. It is
  /// not reused by another widget, so a stale id never names a different
  /// control.
  final String id;

  /// button, link, checkbox, radio, switch, tab, textField, slider, menuItem
  /// or row (anything else that takes a tap).
  final String role;
  final String label;
  final String hint;

  /// What a field holds, a slider's value (never an obscured field's).
  final String value;
  final bool enabled;
  final bool? selected;

  /// A checkbox, radio or switch: its state.
  final bool? checked;
  final bool focused;

  /// On the screen now (false: in the list but scrolled out).
  final bool visible;

  /// Where on the screen: `右上`, `中`, `左下` ... (a 3x3 grid).
  final String at;

  /// tap, longPress, setText, increase, decrease, dismiss, expand, collapse.
  final List<String> actions;
  final SemanticsNode node;

  /// What the node was when it was read; a node that no longer says this is
  /// not the control the id promised.
  String get fingerprint => '$role|$label';

  /// A person (or the model) could not name this control.
  bool get unnamed => label.trim().isEmpty;

  /// Controls that the contract lists by name: everything but a bare scroll
  /// view.
  static const namedRoles = {
    'button',
    'link',
    'checkbox',
    'radio',
    'switch',
    'tab',
    'textField',
    'slider',
    'menuItem',
    'row',
  };
}

/// A scrollable region: its id and the directions it can move.
class OrbScreenScroll {
  OrbScreenScroll({
    required this.id,
    required this.actions,
    required this.node,
    this.label = '',
    this.at = '',
  });
  final String id;
  final String label;
  final String at;
  final List<String> actions;
  final SemanticsNode node;
}

/// What the screen reader found at one moment.
class OrbScreenSnapshot {
  OrbScreenSnapshot({
    required this.number,
    required this.route,
    required this.text,
    required this.areas,
    required this.nodes,
    required this.scrolls,
    required this.size,
  });

  /// Counts up with every reading.
  final int number;
  final String route;

  /// Text that is only text, in reading order (outside the named areas).
  final List<String> text;

  /// Text of named areas (a dialog, a list ...), in reading order.
  final Map<String, List<String>> areas;
  final List<OrbScreenNode> nodes;
  final List<OrbScreenScroll> scrolls;
  final ({double width, double height}) size;

  OrbScreenNode? byId(String id) => nodes.where((n) => n.id == id).firstOrNull;

  OrbScreenScroll? scrollById(String id) =>
      scrolls.where((n) => n.id == id).firstOrNull;
}
