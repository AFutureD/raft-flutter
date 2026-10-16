import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'references/agent_reference_table.dart' as refs;

/// What the voice model is given about the screen: everything the person can
/// read on the front layer, in words, so that "which channel is this task in"
/// is answered from the screen and not guessed.
///
/// The words of each component come from the component itself
/// ([HfDescribed]), built from the very values it draws; the snapshot adds
/// only what is not drawn: the ids behind the names, which items are in view,
/// the buttons each item has. The parity tests (`agent_screen_parity_test`)
/// hold the two together.

/// The sizes the snapshot keeps to.
abstract final class AgentScreenLimits {
  /// One line of a description (a message, a quote): longer ones keep their
  /// head and tail.
  static const line = 600;

  /// Everything about one item, in characters.
  static const item = 1000;

  /// The whole snapshot, in characters: at most about 5 000 tokens of
  /// Chinese text. A layer of a dozen cards is about 2 000; the parity test
  /// prints the size of each layer type.
  static const total = 5000;

  /// An item that no longer fits in full keeps this much of its words.
  static const short = 90;
}

/// [text] cut to [max] characters from its middle: the head and the tail stay
/// and a marker says how much was left out. (A blind cut at the end loses the
/// last words, which are often the point.)
String agentClip(String text, int max) {
  if (text.length <= max) return text;
  // The marker says how many characters it replaces, and takes room itself.
  var keep = max;
  for (var i = 0; i < 3; i++) {
    keep = max - '…(${text.length - keep} chars omitted)…'.length;
  }
  if (keep < 8) return text.substring(0, max);
  var head = (keep * 0.6).ceil();
  var tail = keep - head;
  // Never cut a character in two.
  if (_splits(text, head)) head--;
  if (_splits(text, text.length - tail)) tail--;
  final marker = '…(${text.length - head - tail} chars omitted)…';
  return '${text.substring(0, head)}$marker'
      '${text.substring(text.length - tail)}';
}

bool _splits(String s, int at) =>
    at > 0 &&
    at < s.length &&
    s.codeUnitAt(at - 1) >= 0xD800 &&
    s.codeUnitAt(at - 1) <= 0xDBFF;

/// A rough count of the tokens of [text] a model reads: a character of Chinese
/// is about one token, other text about one in four characters.
int agentTokenEstimate(String text) {
  var wide = 0, narrow = 0;
  for (final r in text.runes) {
    if (r > 0x2E80) {
      wide++;
    } else {
      narrow++;
    }
  }
  return wide + (narrow / 4).ceil();
}

/// One thing on the layer: a numbered item, a block, a heading.
class AgentScreenPart {
  const AgentScreenPart(
    this.description, {
    this.n,
    this.facts = const [],
    this.actions = const [],
    this.view,
    this.entity,
    this.heading = false,
  });

  /// What it draws.
  final HfDescription description;

  /// Its number on the screen; null for a block or a heading.
  final int? n;

  /// What is behind the words and not drawn: ids, the channel, who.
  final List<String> facts;

  /// What can be done to it (the buttons its detail has).
  final List<String> actions;

  /// Where it is in the page right now; null when that is not known.
  final AgentItemView? view;

  /// What it stands for, as the reference table knows it.
  final refs.AgentEntityRef? entity;

  /// A label over the items under it.
  final bool heading;

  String get handle => n == null ? '' : refs.agentHandle(n!);

  /// The words, as the model reads them. [full] false keeps the first words
  /// of the title only.
  String text({bool full = true}) {
    final lines = [
      for (final l in description.lines) agentClip(l, AgentScreenLimits.line),
    ];
    final tag = switch (view) {
      AgentItemView.above => '〔已滚过，在上面〕',
      AgentItemView.below => '〔在下面，要往下翻〕',
      AgentItemView.partly => '〔只露出一部分〕',
      _ => '',
    };
    if (heading) return '▸ ${lines.join(' ')}';
    final extra = [
      if (entity != null) '${entity!.type}:${entity!.id ?? '无 id'}',
      ...facts,
    ];
    final act = [...description.actions, ...actions];
    if (!full) {
      final head = lines.isEmpty ? '' : lines.join(' ｜ ');
      return '${handle.isEmpty ? '·' : handle} '
          '${agentClip(head, AgentScreenLimits.short)}$tag';
    }
    final buf = StringBuffer();
    if (description.block && n == null) {
      buf.write('· ');
      buf.write(lines.join('\n  '));
    } else if (description.block) {
      buf.write('$handle ${lines.join('\n  ')}');
    } else {
      buf.write('${handle.isEmpty ? '·' : handle} ${lines.join(' ｜ ')}');
    }
    buf.write(tag);
    if (extra.isNotEmpty) buf.write('\n  ⟨${extra.join(' · ')}⟩');
    if (act.isNotEmpty) buf.write('\n  可做：${act.join(' / ')}');
    return agentClip(buf.toString(), AgentScreenLimits.item);
  }
}

/// The front layer as the model reads it.
class AgentScreenSnapshot {
  const AgentScreenSnapshot({
    required this.layer,
    required this.kind,
    required this.title,
    required this.head,
    required this.parts,
    this.loading = false,
    this.current,
    this.detail,
    this.tray = const [],
    this.views,
    this.notes = const [],
  });

  /// The layer's place in the stack, from 1.
  final int layer;

  /// What kind of layer: 首页, 频道, 任务, 详情, 屏幕.
  final String kind;
  final String title;

  /// What the layer says about itself: its note, its line, its counts.
  final HfDescription head;
  final List<AgentScreenPart> parts;
  final bool loading;

  /// The current item (from 1) and its detail, drawn beside or under it.
  final int? current;
  final AgentScreenPart? detail;

  /// The confirm cards at the end of the page.
  final List<HfDescription> tray;

  /// Where the items are in the page, by number; null when not drawn.
  final Map<int, AgentItemView>? views;

  /// Anything else worth saying about the screen (the workspace, a wrong
  /// ask).
  final List<String> notes;

  List<AgentScreenPart> get items => [
    for (final p in parts)
      if (p.n != null) p,
  ];

  /// The numbers of the items in view, as "①–④".
  String? get inView {
    final v = views;
    if (v == null || v.isEmpty) return null;
    final seen = [
      for (final e in v.entries)
        if (e.value == AgentItemView.whole || e.value == AgentItemView.partly)
          e.key,
    ]..sort();
    final above = v.values.where((x) => x == AgentItemView.above).length;
    final below = v.values.where((x) => x == AgentItemView.below).length;
    final range = seen.isEmpty
        ? '没有（都在屏幕外）'
        : seen.length == 1
        ? refs.agentHandle(seen.first)
        : '${refs.agentHandle(seen.first)}–${refs.agentHandle(seen.last)}';
    return '眼前 $range${above > 0 ? '，上面已滚过 $above 条' : ''}'
        '${below > 0 ? '，下面还有 $below 条没看到' : ''}';
  }

  /// The snapshot as text, kept to [AgentScreenLimits.total] characters:
  /// when it does not fit, the items out of view shrink to a few words, then
  /// every item but the current one, and in the end the last ones are counted
  /// instead of listed.
  String text() {
    final all = parts;
    final shortened = <int>{};
    var listed = all.length;
    String render() {
      final out = StringBuffer();
      out.writeln('【屏幕】第 $layer 层「$title」($kind)${loading ? '，还在读取' : ''}');
      for (final n in notes) {
        out.writeln(n);
      }
      final headLines = [
        for (final l in head.lines.skip(1))
          agentClip(l, AgentScreenLimits.line),
      ];
      if (headLines.isNotEmpty) out.writeln(headLines.join(' ｜ '));
      final count = items.length;
      final view = inView;
      out.writeln(
        '共 $count 条${view == null ? '' : '；$view'}；'
        '${current == null ? '没有选中哪一条' : '当前这一条：${refs.agentHandle(current!)}'}',
      );
      for (var i = 0; i < listed; i++) {
        out.writeln(all[i].text(full: !shortened.contains(i)));
      }
      if (listed < all.length) {
        final left = [
          for (final p in all.skip(listed))
            if (p.n != null) p.n!,
        ];
        out.writeln(
          '…另有 ${left.length} 条没有列出（${left.isEmpty ? '' : '${refs.agentHandle(left.first)}–${refs.agentHandle(left.last)}'}），'
          '往下翻之后再读屏幕，或用 spotlight / expand_item 看某一条',
        );
      }
      final d = detail;
      if (d != null) {
        out.writeln('【当前这一条 ${d.handle} 的详情（屏幕上就是这样写的）】');
        out.writeln(
          d.description.lines
              .map((l) => '  ${agentClip(l, AgentScreenLimits.line)}')
              .join('\n'),
        );
        final act = d.description.actions;
        if (act.isNotEmpty) out.writeln('  可做：${act.join(' / ')}');
      }
      for (final t in tray) {
        out.writeln('【等你确认的卡片】');
        out.writeln(
          t.lines
              .map((l) => '  ${agentClip(l, AgentScreenLimits.line)}')
              .join('\n'),
        );
        if (t.actions.isNotEmpty) out.writeln('  可做：${t.actions.join(' / ')}');
      }
      return out.toString().trimRight();
    }

    bool fits(String t) => t.length <= AgentScreenLimits.total;
    var text = render();
    if (fits(text)) return text;
    bool watched(int i) =>
        all[i].n == current ||
        all[i].view == AgentItemView.whole ||
        all[i].view == AgentItemView.partly;
    // First the items nobody looks at, last ones first.
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].heading || watched(i)) continue;
      shortened.add(i);
      text = render();
      if (fits(text)) return text;
    }
    // Then everything but the current one.
    for (var i = all.length - 1; i >= 0; i--) {
      if (all[i].heading || all[i].n == current) continue;
      shortened.add(i);
      text = render();
      if (fits(text)) return text;
    }
    // Still too much: the last items are counted, not listed.
    while (listed > 1) {
      listed--;
      if (all[listed].n == current) continue;
      text = render();
      if (fits(text)) return text;
    }
    return agentClip(text, AgentScreenLimits.total);
  }

  /// The items and what they point at, for the tools that look things up by
  /// number; the words are in [text].
  List<Map<String, Object?>> itemsJson() => [
    for (final p in items)
      {
        'n': p.n,
        'handle': p.handle,
        if (p.entity != null)
          'entity': {'type': p.entity!.type, 'id': ?p.entity!.id},
      },
  ];
}
