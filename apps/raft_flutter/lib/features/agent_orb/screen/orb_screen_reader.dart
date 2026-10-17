import 'dart:ui';

import 'package:flutter/rendering.dart';

import 'orb_screen_snapshot.dart';

/// The actions the contract names, in the order it lists them.
const _named = <(SemanticsAction, String)>[
  (SemanticsAction.tap, 'tap'),
  (SemanticsAction.longPress, 'longPress'),
  (SemanticsAction.setText, 'setText'),
  (SemanticsAction.increase, 'increase'),
  (SemanticsAction.decrease, 'decrease'),
  (SemanticsAction.expand, 'expand'),
  (SemanticsAction.collapse, 'collapse'),
  (SemanticsAction.dismiss, 'dismiss'),
];

const _scrolls = <(SemanticsAction, String)>[
  (SemanticsAction.scrollUp, 'scrollUp'),
  (SemanticsAction.scrollDown, 'scrollDown'),
  (SemanticsAction.scrollLeft, 'scrollLeft'),
  (SemanticsAction.scrollRight, 'scrollRight'),
];

/// A region the text is grouped under (a dialog, a menu, a list ...).
const _areaRoles = {
  SemanticsRole.dialog: 'dialog',
  SemanticsRole.alertDialog: 'alert',
  SemanticsRole.menu: 'menu',
  SemanticsRole.tabPanel: 'tabPanel',
  SemanticsRole.table: 'table',
  SemanticsRole.list: 'list',
  SemanticsRole.form: 'form',
  SemanticsRole.navigation: 'navigation',
  SemanticsRole.region: 'region',
  SemanticsRole.tabBar: 'tabs',
};

/// [text] on one line: line breaks of a merged node become ` · `.
String orbOneLine(String text) {
  final parts = <String>[];
  for (final part in text.split(RegExp(r'\s*\n\s*'))) {
    final p = part.trim().replaceAll(RegExp(r'[ \t]+'), ' ');
    if (p.isNotEmpty && (parts.isEmpty || parts.last != p)) parts.add(p);
  }
  return parts.join(' · ');
}

/// Reads what a screen reader would read: the semantics tree under [root],
/// without the subtree of the orb itself. Ids are `a` and the node's number.
OrbScreenSnapshot readOrbScreen(
  SemanticsNode root, {
  required int number,
  required String route,
}) {
  final nodes = <OrbScreenNode>[];
  final scrolls = <OrbScreenScroll>[];
  final text = <String>[];
  final areas = <String, List<String>>{};
  final size = (width: root.rect.width, height: root.rect.height);
  final screen = Offset.zero & Size(size.width, size.height);

  void addText(String raw, String? area) {
    final line = orbOneLine(raw);
    if (line.isEmpty) return;
    final into = area == null ? text : areas.putIfAbsent(area, () => []);
    if (into.isNotEmpty && into.last == line) return;
    into.add(line);
  }

  void visit(SemanticsNode node, Matrix4 toRoot, String? area) {
    if (node.isMergedIntoParent) return;
    final data = node.getSemanticsData();
    final f = data.flagsCollection;
    if (data.identifier == orbSemanticsIdentifier) return;
    if (f.isHidden) return;

    final rect = MatrixUtils.transformRect(toRoot, node.rect);
    final visible = rect.overlaps(screen) && !rect.isEmpty;

    var here = area;
    final areaRole = _areaRoles[data.role];
    if (areaRole != null) {
      final name = orbOneLine(data.label);
      here = name.isEmpty ? areaRole : '$areaRole $name';
    }

    final acts = [
      for (final (action, name) in _named)
        if (data.hasAction(action)) name,
    ];
    final scroll = [
      for (final (action, name) in _scrolls)
        if (data.hasAction(action)) name,
    ];
    final label = _labelOf(data);
    final role = _roleOf(data);
    final disabled = f.isEnabled == Tristate.isFalse;
    final control =
        role != 'row' &&
        role != 'tab' &&
        (f.isButton ||
            f.isTextField ||
            f.isSlider ||
            f.isLink ||
            role == 'checkbox' ||
            role == 'switch' ||
            role == 'radio' ||
            role == 'menuItem');
    final dismissOnly = acts.length == 1 && acts.first == 'dismiss';
    // A tap on a wrapper that holds named controls (a section header, the
    // page behind them) is not a control a person would name: its children
    // are the controls.
    final wrapper =
        label.isEmpty &&
        node.hasChildren &&
        !node.mergeAllDescendantsIntoThisNode;
    final actionable =
        !wrapper &&
        ((acts.isNotEmpty && !(dismissOnly && label.isEmpty)) ||
            (control && disabled));

    if (actionable) {
      if (f.isTextField && !f.isReadOnly) {
        // A field takes text once it has the focus; a tap gives it the focus,
        // so setText is offered (and done) as one step.
        acts.remove('tap');
        if (!acts.contains('setText')) acts.insert(0, 'setText');
      }
      nodes.add(
        OrbScreenNode(
          id: 'a${node.id}',
          role: role,
          label: label,
          hint: label == orbOneLine(data.hint) ? '' : orbOneLine(data.hint),
          value: f.isObscured ? '' : orbOneLine(data.value),
          enabled: !disabled,
          selected: switch (f.isSelected) {
            Tristate.isTrue => true,
            Tristate.isFalse => false,
            _ => null,
          },
          checked: _checked(f),
          focused: f.isFocused == Tristate.isTrue,
          visible: visible,
          at: visible ? _grid(rect, size) : '',
          actions: acts,
          node: node,
        ),
      );
    } else if (scroll.isNotEmpty) {
      scrolls.add(
        OrbScreenScroll(
          id: 'a${node.id}',
          label: label,
          at: visible ? _grid(rect, size) : '',
          actions: scroll,
          node: node,
        ),
      );
    }
    if (!actionable) {
      final shown = data.label.trim().isNotEmpty
          ? data.label
          : data.value.trim().isNotEmpty && !f.isObscured
          ? data.value
          : '';
      if (visible && shown.isNotEmpty) addText(shown, here);
    }

    if (node.mergeAllDescendantsIntoThisNode) return;
    node.visitChildren((child) {
      final m = child.transform;
      visit(child, m == null ? toRoot : toRoot.multiplied(m), here);
      return true;
    });
  }

  visit(root, Matrix4.identity(), null);
  return OrbScreenSnapshot(
    number: number,
    route: route,
    text: text,
    areas: areas,
    nodes: nodes,
    scrolls: scrolls,
    size: size,
  );
}

/// What a person would call the control: its label, else its tooltip, else
/// its hint.
String _labelOf(SemanticsData data) => orbOneLine(
  data.label.trim().isNotEmpty
      ? data.label
      : data.tooltip.trim().isNotEmpty
      ? data.tooltip
      : data.hint,
);

/// `role|label` of [node] as the reader reads it now.
String orbNodeFingerprint(SemanticsNode node) {
  final data = node.getSemanticsData();
  return '${_roleOf(data)}|${_labelOf(data)}';
}

String _roleOf(SemanticsData data) {
  final f = data.flagsCollection;
  if (f.isTextField) return 'textField';
  if (f.isSlider) return 'slider';
  if (f.isLink) return 'link';
  if (data.role == SemanticsRole.tab) return 'tab';
  if (data.role == SemanticsRole.menuItem) return 'menuItem';
  if (f.isChecked != CheckedState.none) {
    return f.isInMutuallyExclusiveGroup ? 'radio' : 'checkbox';
  }
  if (f.isToggled != Tristate.none) return 'switch';
  if (f.isButton) return 'button';
  return 'row';
}

bool? _checked(SemanticsFlags f) {
  if (f.isChecked == CheckedState.isTrue) return true;
  if (f.isChecked == CheckedState.isFalse) return false;
  if (f.isToggled == Tristate.isTrue) return true;
  if (f.isToggled == Tristate.isFalse) return false;
  return null;
}

/// The cell of a 3x3 grid that the middle of [rect] is in.
String _grid(Rect rect, ({double width, double height}) size) {
  final c = rect.center;
  final h = c.dx < size.width / 3
      ? '左'
      : c.dx > size.width * 2 / 3
      ? '右'
      : '中';
  final v = c.dy < size.height / 3
      ? '上'
      : c.dy > size.height * 2 / 3
      ? '下'
      : '中';
  if (h == '中' && v == '中') return '中';
  if (h == '中') return '$v中';
  if (v == '中') return '$h中';
  return '$h$v';
}
