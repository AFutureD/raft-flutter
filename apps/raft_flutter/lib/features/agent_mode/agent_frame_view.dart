import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'references/agent_handle_tag.dart';

/// One item of a frame: the section it comes under, its data, its number.
typedef AgentFrameEntry = ({String? section, Map<String, Object?> item, int n});

/// One serialized layer (see `agentSurfaceFrame` and the `_frame` of the
/// page) drawn as hands-free rows: a channel's brief, the tasks, anything
/// that is a list of numbered items. The phone, the desktop and the TV draw
/// it with the same code; a TV only shows.
///
/// All the rows, with the section labels they come under, are one page that
/// scrolls as a whole. [focused] (the item the agent is talking about,
/// `layer#n`) is brought into view by the item itself (see [AgentFocusable]).
class AgentFrameView extends StatelessWidget {
  const AgentFrameView({
    super.key,
    required this.frame,
    this.onCurrent,
    this.focusPrefix,
    this.focused,
  });
  final Map<String, Object?> frame;

  /// When set, every item is an [AgentFocusable] with id `prefix#n`, n
  /// counting items (not section labels) from 1 as the agent sees them.
  final String? focusPrefix;

  /// The spotlit item, `layer#n`. (The items themselves scroll the page to it.)
  final String? focused;

  /// A row was tapped: it is the current item (never on a TV).
  final ValueChanged<int>? onCurrent;

  static AgentPriority _priority(Object? v) => AgentPriority.values.firstWhere(
    (p) => p.name == v,
    orElse: () => AgentPriority.progress,
  );

  /// The items of [frame] with the section label they come under, numbered
  /// from 1 as the agent numbers them (section labels do not count).
  static List<AgentFrameEntry> entriesOf(Map<String, Object?> frame) {
    final title = '${frame['title'] ?? ''}';
    final entries = <AgentFrameEntry>[];
    String? section;
    var n = 0;
    for (final i in (frame['items'] as List?) ?? const []) {
      if (i is! Map) continue;
      final item = Map<String, Object?>.from(i);
      if (item['kind'] == 'section') {
        // A section that only repeats the title says nothing.
        final text = '${item['text'] ?? ''}';
        section = text == title ? null : text;
        continue;
      }
      entries.add((section: section, item: item, n: ++n));
      section = null;
    }
    return entries;
  }

  /// The row of one item. [onTap] makes it the current one.
  static HfRow rowOf(AgentFrameEntry e, {VoidCallback? onTap}) {
    final i = e.item;
    final message = i['kind'] == 'message';
    final label = '${i['label'] ?? ''}';
    return HfRow(
      key: ValueKey('frame-row-${e.n}'),
      index: e.n,
      tone: message ? HfTone.info : HfColors.toneOf(_priority(i['priority'])),
      meta: [
        ?e.section,
        if (message) '${i['sender'] ?? ''}' else label,
        if (message) '${i['time'] ?? ''}',
      ].where((s) => s.isNotEmpty).join(' · '),
      title: message ? '${i['text'] ?? ''}' : '${i['title'] ?? ''}',
      detail: message || i['detail'] == label ? null : '${i['detail'] ?? ''}',
      onTap: onTap,
    );
  }

  /// The frame of the layer: its header, the line under it, the spinner or
  /// the error, with [children] as the body.
  static HfLayerFrame frameOf(
    Map<String, Object?> frame, {
    List<Widget> children = const [],
  }) {
    final summary = frame['summary'] as String?;
    final failed = summary != null && summary.startsWith('读取失败');
    final empty = AgentFrameView.entriesOf(frame).isEmpty;
    return HfLayerFrame(
      title: '${frame['title'] ?? ''}',
      meta: frame['meta'] as String?,
      summary: summary == null || failed ? null : TextSpan(text: summary),
      loading: frame['loading'] == true && empty,
      error: failed ? summary : null,
      children: children,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final entries = entriesOf(frame);
    final prefix = focusPrefix;
    final current = onCurrent;
    return frameOf(
      frame,
      children: [
        for (final (r, e) in entries.indexed) ...[
          if (r > 0) SizedBox(height: hf.rowGap),
          if (prefix == null)
            rowOf(
              e,
              onTap: current != null && hf.interactive
                  ? () => current(e.n)
                  : null,
            )
          else
            AgentFocusable(
              id: '$prefix#${e.n}',
              child: AgentHandleTag(
                focusId: '$prefix#${e.n}',
                child: rowOf(
                  e,
                  onTap: current != null && hf.interactive
                      ? () => current(e.n)
                      : null,
                ),
              ),
            ),
        ],
      ],
    );
  }
}

/// One item of a [AgentFrameView] (or of a screen's frame) in its detail
/// rendering: what the stage beside a list, or under a row on a phone, shows
/// for the current item. A message says who and when, with its words in full;
/// the rest say what they are, their title and their facts. [trailing] is the
/// stage's small tools.
class AgentFrameStage extends StatelessWidget {
  const AgentFrameStage({
    super.key,
    required this.item,
    required this.number,
    this.trailing,
    this.onOpen,
  });
  final Map<String, Object?> item;
  final int number;
  final Widget? trailing;

  /// 打开讨论: the item's channel as a layer (when it has one).
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => view();

  /// The detail as the screen draws it; the description of the current item
  /// is read from this same widget.
  HfDetail view() {
    final message = item['kind'] == 'message';
    final detail = '${item['detail'] ?? ''}';
    final label = '${item['label'] ?? ''}';
    return HfDetail(
      key: const ValueKey('agent-frame-stage'),
      titleMode: HfDetailTitle.heading,
      index: number,
      tone: message
          ? HfTone.info
          : HfColors.toneOf(
              AgentPriority.values.firstWhere(
                (p) => p.name == item['priority'],
                orElse: () => AgentPriority.progress,
              ),
            ),
      status: message
          ? [
              '${item['sender'] ?? ''}',
              '${item['time'] ?? ''}',
            ].where((e) => e.isNotEmpty).join(' · ')
          : label,
      title: message ? '${item['text'] ?? ''}' : '${item['title'] ?? ''}',
      facts: [
        if (!message && detail.isNotEmpty && detail != label)
          HfFact('情况', detail),
      ],
      trailing: trailing,
      oneRowActions: trailing != null,
      actions: [
        if (onOpen != null)
          HfAction(
            '打开讨论',
            key: const ValueKey('agent-stage-open'),
            kind: HfActionKind.secondary,
            onPressed: onOpen,
          ),
      ],
    );
  }
}
