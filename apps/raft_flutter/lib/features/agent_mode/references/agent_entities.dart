import '../agent_catalog.dart' show AgentComponents;
import '../agent_entity_binding.dart' show AgentEntityComponents;
import '../agent_mode_data.dart';
import '../agent_surface.dart' show SurfaceNode;
import '../agent_surface_tools.dart' show AgentFacts;
import 'agent_reference_table.dart';

/// The `entity` of a frame item: what the card stands for, as the reference
/// table reads it (`type`, `id`, `label`, `hints`). Built from the app's own
/// rows and from what the model read, never from words the model wrote.
Map<String, Object?> agentEntity(
  String type,
  String? id,
  String label, [
  Iterable<String?> hints = const [],
]) => {
  'type': type,
  'id': ?id,
  'label': AgentHeadlines.plain(label, max: 60),
  'hints': [
    for (final h in hints)
      if (h != null && h.trim().isNotEmpty) h.trim(),
  ],
};

String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

/// An attention card: the task, or the discussion a mention is in.
Map<String, Object?> attentionEntity(AgentAttentionItem i) => agentEntity(
  i.taskNumber != null ? AgentEntityTypes.task : AgentEntityTypes.thread,
  i.taskNumber != null ? i.taskId : i.id,
  i.headline,
  [
    if (i.taskNumber != null) '#${i.taskNumber}',
    i.doer,
    ...i.waiters,
    i.channelName,
    i.threadTitle,
  ],
);

/// A task row of the server (summary or full).
Map<String, Object?> taskRowEntity(Map<String, dynamic> t) =>
    agentEntity(AgentEntityTypes.task, _s(t['id']), '${t['title'] ?? ''}', [
      if (t['taskNumber'] != null) '#${t['taskNumber']}',
      _s(t['claimedByName']),
      _s(t['createdByName']),
      _s(t['channelName']),
    ]);

/// A message row of the server.
Map<String, Object?> messageRowEntity(Map<String, dynamic> m) => agentEntity(
  AgentEntityTypes.message,
  _s(m['id']),
  '${m['content'] ?? ''}',
  [_s(m['senderName'] ?? m['senderDisplayName'])],
);

/// A component the model composed, resolved to ids through what it read.
/// Null for components that stand for no entity.
///
/// An `EntityCard` already names its kind and id; [labelOf] gives what the
/// app reads for them (its title), so "Cody 那个任务" can find it too.
Map<String, Object?>? surfaceEntity(
  SurfaceNode n,
  AgentFacts facts, {
  String? Function(String kind, String id)? labelOf,
}) {
  switch (n.component) {
    case AgentEntityComponents.entity:
      final kind = n.string('entity'), id = n.string('id');
      if (kind == null || id == null) return null;
      final label = labelOf?.call(kind, id);
      return agentEntity(
        kind,
        id,
        label == null || label.trim().isEmpty
            ? (AgentEntityTypes.labels[kind] ?? kind)
            : label,
        // "#98" is how people say a task; the label's own cleaning drops it.
        [for (final m in RegExp(r'#\d+').allMatches(label ?? '')) m[0]],
      );
    case AgentComponents.statusCard:
      final name = n.string('name') ?? '';
      return agentEntity(AgentEntityTypes.agent, facts.agentId(name), name, [
        n.string('activity'),
        n.string('channel'),
      ]);
    case AgentComponents.taskCard:
      final number = n.integer('number');
      return agentEntity(
        AgentEntityTypes.task,
        number == null
            ? null
            : facts.taskId(number, channel: n.string('channel')),
        n.string('title') ?? '',
        [
          if (number != null) '#$number',
          n.string('assignee'),
          n.string('channel'),
        ],
      );
    case AgentComponents.messageQuote:
      final who = n.string('author') ?? '';
      return agentEntity(
        AgentEntityTypes.message,
        facts.messageId(who, n.string('text') ?? ''),
        n.string('text') ?? '',
        [who],
      );
  }
  return null;
}
