import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_surface.dart';

/// Names of the standard components, for code that composes surfaces.
abstract final class AgentComponents {
  static const statusCard = 'AgentStatusCard';
  static const statusGroup = 'AgentStatusGroup';
  static const taskCard = 'TaskCard';
  static const messageQuote = 'MessageQuote';
  static const statRow = 'StatRow';
  static const column = 'Column';
  static const section = 'Section';
}

AgentWorkState _state(String? name) => AgentWorkState.values.firstWhere(
  (s) => s.name == name,
  orElse: () => AgentWorkState.idle,
);

const _states = ['busy', 'idle', 'blocked', 'offline'];
const _statuses = ['todo', 'in_progress', 'in_review', 'done', 'closed'];

Map<String, Object?> _string(String doc, [int max = 120]) => {
  'type': 'string',
  'description': doc,
  'maxLength': max,
};

/// The quote line a task card shows: `who · time  text`.
String formatQuote(Map<String, Object?> q) {
  final head = [
    for (final k in const ['who', 'time'])
      if ('${q[k] ?? ''}'.isNotEmpty) '${q[k]}',
  ].join(' · ');
  return head.isEmpty ? '${q['text']}' : '$head  ${q['text']}';
}

AgentCatalog _standard() => AgentCatalog([
  AgentCatalogItem(
    name: AgentComponents.statusCard,
    description: '一个 Agent 现在的状态',
    schema: {
      'type': 'object',
      'properties': {
        'name': _string('Agent 的名字，必须是 list_agents 返回的', 60),
        'state': {
          'type': 'string',
          'enum': _states,
          'description': 'list_agents 返回的 state，原样使用',
        },
        'activity': _string('正在做什么，一句话，取自 list_agents 的 activity'),
        'since': _string('持续多久，取自 list_agents 的 since', 30),
        'channel': _string('所在频道名，不带 #', 60),
      },
      'required': ['name', 'state'],
    },
    example: {
      'component': 'AgentStatusCard',
      'name': 'Grok',
      'state': 'busy',
      'activity': '在做 #102「历史上拉」',
      'since': '12 分钟前有进展',
      'channel': 'raft-flutter',
    },
    build: (context, n, _) => AgentStatusCardView(
      name: n.string('name') ?? '',
      state: _state(n.string('state')),
      activity: n.string('activity'),
      since: n.string('since'),
      channel: n.string('channel'),
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.statusGroup,
    description: '同一种状态的一组 Agent，带标题和个数',
    container: true,
    childNames: {AgentComponents.statusCard},
    schema: {
      'type': 'object',
      'properties': {
        'title': _string('组标题，如“在忙”“卡住了”', 40),
        'state': {
          'type': 'string',
          'enum': _states,
          'description': '这一组的状态，决定颜色',
        },
      },
      'required': ['title'],
    },
    example: {
      'component': 'AgentStatusGroup',
      'title': '在忙',
      'state': 'busy',
      'children': [
        {'component': 'AgentStatusCard', 'name': 'Grok', 'state': 'busy'},
      ],
    },
    build: (context, n, children) => AgentStatusGroupView(
      title: n.string('title') ?? '',
      state: n.string('state') == null ? null : _state(n.string('state')),
      children: children,
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.taskCard,
    description: '一个任务：一句话标题、状态、负责人、最新进展和要用户做的事',
    schema: {
      'type': 'object',
      'properties': {
        'title': _string('用一句话说这个任务做什么', 140),
        'status': {
          'type': 'string',
          'enum': _statuses,
          'description': 'get_task 返回的 status，原样使用',
        },
        'number': {'type': 'integer', 'description': '任务编号，不带 #'},
        'assignee': _string('负责人（claimer）', 60),
        'channel': _string('所在频道名，不带 #', 60),
        'quote': {
          'type': 'object',
          'description': '最新进展：thread 里最后一条的原话',
          'properties': {
            'who': _string('谁说的', 60),
            'time': _string('什么时候', 40),
            'text': _string('原话，可以截取开头，不要改写', 300),
          },
          'required': ['text'],
        },
        'ask': _string('要用户做什么，如“验收这个任务”', 80),
      },
      'required': ['title', 'status'],
    },
    example: {
      'component': 'TaskCard',
      'title': '修复搜索打开频道后无法返回',
      'status': 'in_review',
      'number': 98,
      'assignee': 'Grok',
      'channel': 'raft-flutter',
      'quote': {'who': 'Grok', 'time': '10:32', 'text': '已修复并补了测试'},
      'ask': '验收这个任务',
    },
    build: (context, n, _) {
      final q = n.object('quote');
      return AgentTaskCardView(
        title: n.string('title') ?? '',
        status: n.string('status') ?? 'todo',
        number: n.integer('number'),
        assignee: n.string('assignee'),
        channel: n.string('channel'),
        quote: q == null ? null : formatQuote(q),
        ask: n.string('ask'),
      );
    },
  ),
  AgentCatalogItem(
    name: AgentComponents.messageQuote,
    description: '引用某人说过的一句话',
    schema: {
      'type': 'object',
      'properties': {
        'author': _string('谁说的', 60),
        'text': _string('原话，可以截取开头，不要改写', 400),
        'time': _string('什么时候', 40),
        'channel': _string('哪个频道，不带 #', 60),
      },
      'required': ['author', 'text'],
    },
    example: {
      'component': 'MessageQuote',
      'author': 'Cindy',
      'time': '昨天 18:20',
      'text': 'PR 已合入，全量检查 0 失败。',
    },
    build: (context, n, _) => AgentMessageQuoteView(
      author: n.string('author') ?? '',
      text: n.string('text') ?? '',
      time: n.string('time'),
      channel: n.string('channel'),
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.statRow,
    description: '几个数字，一行：标签和值',
    schema: {
      'type': 'object',
      'properties': {
        'stats': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 6,
          'items': {
            'type': 'object',
            'properties': {
              'label': _string('标签', 20),
              'value': _string('值', 20),
            },
            'required': ['label', 'value'],
          },
        },
      },
      'required': ['stats'],
    },
    example: {
      'component': 'StatRow',
      'stats': [
        {'label': '在忙', 'value': '3'},
        {'label': '卡住', 'value': '1'},
      ],
    },
    build: (context, n, _) => AgentStatRowView(
      stats: [
        for (final s in n.list('stats'))
          if (s is Map) AgentStatData('${s['label']}', '${s['value']}'),
      ],
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.column,
    description: '竖着排列子组件',
    container: true,
    schema: {'type': 'object', 'properties': <String, Object?>{}},
    example: {
      'component': 'Column',
      'children': [
        {
          'component': 'StatRow',
          'stats': [
            {'label': '在忙', 'value': '3'},
          ],
        },
      ],
    },
    build: (context, n, children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.section,
    description: '带小标题的一段，放子组件',
    container: true,
    schema: {
      'type': 'object',
      'properties': {'title': _string('小标题', 40)},
      'required': ['title'],
    },
    example: {
      'component': 'Section',
      'title': '最近讨论',
      'children': [
        {'component': 'MessageQuote', 'author': 'Cindy', 'text': '已合入'},
      ],
    },
    build: (context, n, children) => AgentSurfaceSectionView(
      title: n.string('title') ?? '',
      children: children,
    ),
  ),
]);

/// The catalog agent mode composes screens from.
final AgentCatalog agentStandardCatalog = _standard();

/// Draws a validated surface as a layer: heading, summary and the tree. Items
/// (the leaves) are [AgentFocusable] numbered from 1 in reading order, the same
/// numbers [agentSurfaceFrame] gives them, so spotlight and marks work.
class AgentSurfaceView extends StatelessWidget {
  const AgentSurfaceView({
    super.key,
    required this.spec,
    required this.focusPrefix,
    this.catalog,
  });
  final AgentSurfaceSpec spec;
  final String focusPrefix;

  /// Defaults to [agentStandardCatalog].
  final AgentCatalog? catalog;

  @override
  Widget build(BuildContext context) {
    final catalog = this.catalog ?? agentStandardCatalog;
    var n = 0;
    Widget draw(SurfaceNode node) {
      final item = catalog.item(node.component);
      if (item == null) return const SizedBox.shrink();
      final children = [for (final c in node.children) draw(c)];
      final built = item.build(context, node, children);
      return item.container
          ? built
          : AgentFocusable(id: '$focusPrefix#${++n}', child: built);
    }

    final body = draw(spec.root);
    return AgentLayerFrame(
      title: spec.title,
      summary: spec.summary == null ? null : TextSpan(text: spec.summary),
      children: [body],
    );
  }
}

/// The surface as a serialized layer (see `AgentFrameView`): what the TV
/// mirror draws and what the voice model reads as numbered screen items.
Map<String, Object?> agentSurfaceFrame(AgentSurfaceSpec spec) {
  final items = <Map<String, Object?>>[];
  void visit(SurfaceNode n) {
    switch (n.component) {
      case AgentComponents.statusGroup || AgentComponents.section:
        items.add({'kind': 'section', 'text': n.string('title') ?? ''});
      case AgentComponents.statusCard:
        final state = _state(n.string('state'));
        items.add({
          'kind': 'priority',
          'priority': switch (state) {
            AgentWorkState.busy => AgentPriority.progress,
            AgentWorkState.blocked => AgentPriority.blocked,
            _ => AgentPriority.mention,
          }.name,
          'label': agentWorkStateLabels[state],
          'weight': items.length + 1,
          'title': n.string('name') ?? '',
          'detail': [
            ?n.string('activity'),
            ?n.string('since'),
            if (n.string('channel') != null) '#${n.string('channel')}',
          ].join(' · '),
        });
      case AgentComponents.taskCard:
        final status = n.string('status') ?? '';
        final q = n.object('quote');
        items.add({
          'kind': 'priority',
          'priority': switch (status) {
            'in_review' => AgentPriority.decision,
            'in_progress' => AgentPriority.progress,
            _ => AgentPriority.mention,
          }.name,
          'label': agentTaskStatusLabels[status] ?? status,
          'weight': items.length + 1,
          'title': n.string('title') ?? '',
          'detail': [
            if (n.integer('number') != null) '#${n.integer('number')}',
            ?n.string('assignee'),
            if (n.string('channel') != null) '#${n.string('channel')}',
            if (q != null) formatQuote(q),
            if (n.string('ask') != null) '要你做：${n.string('ask')}',
          ].join(' · '),
        });
      case AgentComponents.messageQuote:
        items.add({
          'kind': 'message',
          'sender': n.string('author') ?? '',
          'time': n.string('time') ?? '',
          'text': n.string('text') ?? '',
        });
      case AgentComponents.statRow:
        items.add({
          'kind': 'priority',
          'priority': AgentPriority.progress.name,
          'label': '数字',
          'weight': items.length + 1,
          'title': [
            for (final s in n.list('stats'))
              if (s is Map) '${s['label']} ${s['value']}',
          ].join('　'),
        });
    }
    n.children.forEach(visit);
  }

  visit(spec.root);
  return {
    'title': spec.title,
    'meta': 'GenUI',
    'loading': false,
    'summary': spec.summary,
    'items': items,
  };
}
