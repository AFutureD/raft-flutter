import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'references/agent_handle_tag.dart';

/// One serialized layer (see `agentSurfaceFrame` and the `_frame` of the
/// page) drawn as hands-free rows: a channel's brief, the tasks, anything
/// that is a list of numbered items. The phone, the desktop and the TV draw
/// it with the same code; a TV only shows.
///
/// A page holds [HfData.listRows] rows with the section labels they come
/// under; the pager asks for the next page. The page that holds [focused] (the
/// item the agent is talking about, `layer#n`) is the one shown.
class AgentFrameView extends StatefulWidget {
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

  /// The spotlit item, `layer#n`.
  final String? focused;

  /// A row was tapped: it is the current item (never on a TV).
  final ValueChanged<int>? onCurrent;

  @override
  State<AgentFrameView> createState() => _AgentFrameViewState();
}

typedef _Entry = ({String? section, Map<String, Object?> item, int n});

class _AgentFrameViewState extends State<AgentFrameView> {
  int _start = 0;
  String? _seenFocus;

  static AgentPriority _priority(Object? v) => AgentPriority.values.firstWhere(
    (p) => p.name == v,
    orElse: () => AgentPriority.progress,
  );

  List<_Entry> _entries() {
    final title = '${widget.frame['title'] ?? ''}';
    final entries = <_Entry>[];
    String? section;
    var n = 0;
    for (final i in (widget.frame['items'] as List?) ?? const []) {
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

  HfRow _row(HfData hf, _Entry e) {
    final i = e.item;
    final message = i['kind'] == 'message';
    final label = '${i['label'] ?? ''}';
    final current = widget.onCurrent;
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
      onTap: current != null && hf.interactive ? () => current(e.n) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final frame = widget.frame;
    final entries = _entries();
    final rows = hf.listRows;
    final id = '${frame['id'] ?? widget.focusPrefix ?? ''}';
    final focus = widget.focused != null && widget.focused!.startsWith('$id#')
        ? int.tryParse(widget.focused!.substring(id.length + 1))
        : null;
    // The agent points at an item on another page: that page comes.
    if (focus != null && widget.focused != _seenFocus) {
      _start = ((focus - 1) ~/ rows) * rows;
    }
    _seenFocus = widget.focused;
    if (_start >= entries.length) _start = 0;
    final page = entries.skip(_start).take(rows).toList();
    final end = _start + page.length;
    final summary = frame['summary'] as String?;
    final failed = summary != null && summary.startsWith('读取失败');
    final prefix = widget.focusPrefix;
    return HfLayerFrame(
      title: '${frame['title'] ?? ''}',
      meta: frame['meta'] as String?,
      summary: summary == null || failed ? null : TextSpan(text: summary),
      loading: frame['loading'] == true && entries.isEmpty,
      error: failed ? summary : null,
      pager: entries.length > rows
          ? HfPager(
              from: _start + 1,
              to: end,
              total: entries.length,
              onNext: () =>
                  setState(() => _start = end < entries.length ? end : 0),
            )
          : null,
      children: [
        for (final (r, e) in page.indexed) ...[
          if (r > 0) SizedBox(height: hf.rowGap),
          if (prefix == null)
            _row(hf, e)
          else
            AgentFocusable(
              id: '$prefix#${e.n}',
              child: AgentHandleTag(
                focusId: '$prefix#${e.n}',
                child: _row(hf, e),
              ),
            ),
        ],
      ],
    );
  }
}

/// One item of a [AgentFrameView] (or of a screen's frame) in its detail
/// rendering: what the stage beside a list, or a phone's sheet, shows for the
/// current item. A message says who and when, with its words in full; the
/// rest say what they are, their title and their facts. [trailing] is the
/// sheet's small tools.
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
  Widget build(BuildContext context) {
    final message = item['kind'] == 'message';
    final detail = '${item['detail'] ?? ''}';
    final label = '${item['label'] ?? ''}';
    return HfDetail(
      key: const ValueKey('agent-frame-stage'),
      titleMode: HfDetailTitle.heading,
      index: number,
      titleLines: 5,
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
          HfFact('情况', detail, lines: 4),
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
