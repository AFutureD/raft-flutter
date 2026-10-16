import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_catalog.dart';
import 'agent_mode_data.dart';
import 'agent_surface.dart';

String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max - 1)}…';

Map<String, Object?> _quote(AgentProgressLine l) => {
  'component': AgentComponents.messageQuote,
  'author': _clip(l.who, 60),
  if (l.time.isNotEmpty) 'time': _clip(l.time, 40),
  'text': _clip(l.text, 400),
};

String? _who(AgentAttentionItem i) =>
    i.doer ?? (i.waiters.isEmpty ? null : i.waiters.first);

/// The detail of one attention item as a surface, composed from the same
/// catalog the model uses: the task (or the mention) with its latest
/// progress, the lines before it as quotes, and the actions. It is what a
/// tap on a card and the voice tool `expand_item` both show, so the two can
/// never differ.
AgentSurfaceSpec attentionDetailSpec(AgentAttentionItem item, int rank) {
  final lines = item.progress.length > 3
      ? item.progress.sublist(item.progress.length - 3)
      : item.progress;
  final latest = lines.isEmpty ? null : lines.last;
  final earlier = lines.isEmpty
      ? const <AgentProgressLine>[]
      : lines.sublist(0, lines.length - 1);
  final isTask = item.taskId != null || item.taskNumber != null;
  final children = <Map<String, Object?>>[
    if (isTask)
      {
        'component': AgentComponents.taskCard,
        'title': _clip(item.headline, 140),
        'status': item.priority == AgentPriority.blocked
            ? 'in_progress'
            : 'in_review',
        if (item.taskNumber != null) 'number': item.taskNumber,
        if (item.doer != null) 'assignee': _clip(item.doer!, 60),
        if (item.channelName != null) 'channel': _clip(item.channelName!, 60),
        if (latest != null)
          'quote': {
            'who': _clip(latest.who, 60),
            'time': _clip(latest.time, 40),
            'text': _clip(latest.text, 300),
          },
        'ask': _clip(item.askText, 80),
      },
    // A mention has no task card: the words said to the person come first.
    if (!isTask && latest != null) _quote(latest),
    if (earlier.isNotEmpty)
      {
        'component': AgentComponents.section,
        'title': '之前的进展',
        'density': 'detail',
        'children': [for (final l in earlier) _quote(l)],
      },
    {
      'component': AgentComponents.actionRow,
      'itemId': item.id,
      'approve': item.canApprove,
      'openLabel': item.action == AgentAction.reply
          ? '回复${_who(item) == null ? '' : ' ${_clip(_who(item)!, 20)}'}'
          : '打开讨论',
    },
  ];
  final parsed = agentStandardCatalog.parse({
    'title': '第 $rank 条',
    if (!isTask) 'summary': _clip(item.headline, 200),
    'root': {
      'component': AgentComponents.column,
      'density': 'detail',
      'children': children,
    },
  });
  // Everything above is clipped to the schema; a refusal is a bug here.
  return parsed.spec ??
      (throw StateError('detail surface refused: ${parsed.problems}'));
}

/// The facts of an item as the voice model reads them after `expand_item`.
Map<String, Object?> attentionFacts(AgentAttentionItem item, int rank) => {
  'index': rank,
  'headline': item.headline,
  'ask': item.askText,
  'reason': item.reason,
  'wait': item.waitLabel,
  if (item.channelName != null) 'channel': item.channelName,
  if (item.threadTitle != null) 'thread': item.threadTitle,
  if (item.taskNumber != null) 'task': item.taskNumber,
  if (item.waiters.isNotEmpty) 'waiting': item.waitingText,
  'canApprove': item.canApprove,
  'progress': [
    for (final l in item.progress)
      {'who': l.who, 'time': l.time, 'text': l.text},
  ],
};

/// One or two spoken sentences for an expanded item, from [attentionFacts]:
/// what happened, what the last word was, and what is asked. Used when no
/// model is there to say it.
String explainAttention(Map<String, Object?> facts) {
  String clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
  final progress = [
    for (final p in (facts['progress'] as List? ?? const []))
      (p as Map).cast<String, Object?>(),
  ];
  final last = progress.isEmpty ? null : progress.last;
  final head = '第 ${facts['index']} 条：${facts['headline']}';
  final said = last == null || '${last['text']}'.isEmpty
      ? ''
      : '${last['who']} 最后说：「${clip('${last['text']}', 36)}」。';
  final ask = facts['canApprove'] == true
      ? '没问题的话，点下面的“通过”。'
      : '要你${facts['ask']}。';
  return '$head。$said$ask'.replaceAll('。。', '。');
}
