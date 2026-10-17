import 'dart:convert';

import 'orb_screen_snapshot.dart';

/// How much of the screen a result carries.
enum OrbScreenDetail {
  /// The visible text and the actions: for pages the data layer does not
  /// describe, and for `describe_page`.
  full,

  /// Only the actions (and shorter labels): the page's own data already says
  /// what is written on it. For `navigate` and `open_item`.
  arrival,
}

/// The most of the result the contract may use (UTF-8 bytes of JSON); the
/// rest of the 16 KB tool limit is for the data next to it.
const orbScreenBudgetFull = 9 * 1024;
const orbScreenBudgetArrival = 5 * 1024;

String _clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max).trimRight()}…';

Map<String, Object?> _entry(OrbScreenNode n, int labelMax) => {
  'id': n.id,
  'role': n.role,
  'label': _clip(n.label, labelMax),
  if (n.hint.isNotEmpty) 'hint': _clip(n.hint, 80),
  if (n.value.isNotEmpty) 'value': _clip(n.value, 120),
  if (!n.enabled) 'disabled': true,
  if (n.selected != null) 'selected': n.selected,
  if (n.checked != null) 'checked': n.checked,
  if (n.focused) 'focused': true,
  if (!n.visible) 'offscreen': true,
  if (n.at.isNotEmpty) 'at': n.at,
  'do': n.actions,
};

int _bytes(Object? json) => utf8.encode(jsonEncode(json)).length;

/// [s] as the JSON the model reads: `{snapshot, text, areas, actions, scroll}`.
///
/// The controls come focused first, then the ones on the screen in reading
/// order, then the ones scrolled out. When the whole is over [maxBytes] the
/// tail goes first (the scrolled-out controls, then lines and controls from
/// the end) and the counts of what was left out say so.
Map<String, Object?> orbScreenContract(
  OrbScreenSnapshot s, {
  OrbScreenDetail detail = OrbScreenDetail.full,
  int? maxBytes,
}) {
  final limit =
      maxBytes ??
      (detail == OrbScreenDetail.full
          ? orbScreenBudgetFull
          : orbScreenBudgetArrival);
  final labelMax = detail == OrbScreenDetail.full ? 160 : 60;
  // A row that only takes a long press is a message of a conversation: the
  // page's data has it (with the whole text), so the controls do not repeat it.
  final listed = detail == OrbScreenDetail.arrival
      ? [
          for (final n in s.nodes)
            if (!(n.role == 'row' &&
                n.actions.length == 1 &&
                n.actions.first == 'longPress'))
              n,
        ]
      : s.nodes;
  final nodes = [
    ...listed.where((n) => n.focused && n.visible),
    ...listed.where((n) => !n.focused && n.visible),
    ...listed.where((n) => !n.visible),
  ];
  final lines = detail == OrbScreenDetail.full
      ? [for (final l in s.text) _clip(l, 200)]
      : const <String>[];
  final areas = detail == OrbScreenDetail.full
      ? {
          for (final e in s.areas.entries)
            e.key: [for (final l in e.value) _clip(l, 200)],
        }
      : const <String, List<String>>{};
  final scrolls = [
    for (final c in s.scrolls)
      {
        'id': c.id,
        if (c.label.isNotEmpty) 'label': _clip(c.label, 60),
        if (c.at.isNotEmpty) 'at': c.at,
        'do': c.actions,
      },
  ];

  Map<String, Object?> build(int keepText, int keepNodes) {
    final shownNodes = nodes.take(keepNodes).toList();
    final textLeft = keepText;
    var budgetLeft = textLeft;
    final shownAreas = <String, List<String>>{};
    for (final e in areas.entries) {
      if (budgetLeft <= 0) break;
      final part = e.value.take(budgetLeft).toList();
      shownAreas[e.key] = part;
      budgetLeft -= part.length;
    }
    final shownText = lines.take(budgetLeft.clamp(0, lines.length)).toList();
    final textTotal =
        lines.length + areas.values.fold<int>(0, (a, b) => a + b.length);
    final textShown =
        shownText.length +
        shownAreas.values.fold<int>(0, (a, b) => a + b.length);
    return {
      'snapshot': s.number,
      if (detail == OrbScreenDetail.full) 'text': shownText,
      if (shownAreas.isNotEmpty) 'areas': shownAreas,
      'actions': [for (final n in shownNodes) _entry(n, labelMax)],
      if (scrolls.isNotEmpty) 'scroll': scrolls,
      if (textShown < textTotal) 'textOmitted': textTotal - textShown,
      if (shownNodes.length < nodes.length)
        'actionsOmitted': nodes.length - shownNodes.length,
      if (detail == OrbScreenDetail.arrival)
        'note': '这一页写着什么在 page 里；这里只列出能点的。要点哪个，用 screen_action 带上这里的 id。',
    };
  }

  const steps = [
    (160, 80),
    (100, 60),
    (60, 40),
    (30, 30),
    (12, 20),
    (4, 10),
    (0, 5),
  ];
  Map<String, Object?> out = build(steps.first.$1, steps.first.$2);
  for (final (text, nodeCount) in steps) {
    out = build(text, nodeCount);
    if (_bytes(out) <= limit) return out;
  }
  return out;
}

/// What the person can do here, in one line for the model's silent page
/// note: the labels of the first controls on the screen (no ids: those
/// belong to a reading of `describe_page`).
String orbScreenShort(OrbScreenSnapshot s, {int max = 8}) {
  final seen = <String>{};
  final labels = <String>[];
  final order = [
    ...s.nodes.where((n) => n.visible && n.role != 'row'),
    ...s.nodes.where((n) => n.visible && n.role == 'row'),
  ];
  for (final n in order) {
    final label = _clip(n.label, 16);
    if (label.isEmpty || !n.enabled || !seen.add(label)) continue;
    labels.add(label);
    if (labels.length >= max) break;
  }
  if (labels.isEmpty) return '';
  final more = s.nodes.where((n) => n.visible).length - labels.length;
  return '屏幕上能点的：${labels.join('、')}${more > 0 ? '等 ${labels.length + more} 处' : ''}。';
}
