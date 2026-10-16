import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' as ui show AgentEntityRef;

import 'agent_entity_binding.dart';
import 'agent_surface.dart';
import 'references/agent_handle_tag.dart';

/// Names of the standard components, for code that composes surfaces.
abstract final class AgentComponents {
  static const statusCard = 'AgentStatusCard';
  static const statusGroup = 'AgentStatusGroup';
  static const taskCard = 'TaskCard';
  static const messageQuote = 'MessageQuote';
  static const statRow = 'StatRow';
  static const column = 'Column';
  static const section = 'Section';

  /// 通过 / 打开讨论 / 稍后: only the app puts this on a detail layer.
  static const actionRow = 'ActionRow';
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
String _clip(String text, int max) =>
    text.length <= max ? text : '${text.substring(0, max)}…';

/// The quote line a task card shows: `who · time  text`.
String formatQuote(Map<String, Object?> q) {
  final head = [
    for (final k in const ['who', 'time'])
      if ('${q[k] ?? ''}'.isNotEmpty) '${q[k]}',
  ].join(' · ');
  return head.isEmpty ? '${q['text']}' : '$head  ${q['text']}';
}

/// The `display` field of a component: a preset level and which of its
/// elements are shown (see [agentDisplayKinds] for the names).
Map<String, Object?> _display(String kind) => agentDisplaySchema([kind]);

/// The `childDisplay` field of a list: the display of every child that does
/// not say its own. [kinds] are the components it may hold.
Map<String, Object?> _childDisplay([Iterable<String>? kinds]) =>
    agentDisplaySchema(kinds ?? agentDisplayKinds.keys, childDisplay: true);

DisplaySpec? _spec(SurfaceNode n, [String key = 'display']) {
  final d = agentDisplayOf(n.props, key);
  return d.isEmpty ? null : d;
}

/// The key of [n]'s element inventory in [agentDisplayKinds]: the kind for an
/// entity card, else the component.
String displayKindOf(SurfaceNode n) =>
    n.component == AgentEntityComponents.entity
    ? (n.string('entity') ?? n.component)
    : n.component;

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
        'display': _display('AgentStatusCard'),
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
    line: (n) {
      final activity = n.string('activity') ?? '';
      final skip =
          activity.isEmpty || agentWorkStateLabels.values.contains(activity);
      return '${n.string('name') ?? ''}${skip ? '' : ' $activity'}';
    },
    build: (context, n, _) => HfStatusCard(
      name: n.string('name') ?? '',
      state: _state(n.string('state')),
      activity: n.string('activity'),
      since: n.string('since'),
      channel: n.string('channel'),
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.statusGroup,
    description: '同一种状态的一组 Agent，带标题和个数',
    container: true,
    fold: true,
    childNames: {AgentComponents.statusCard},
    schema: {
      'type': 'object',
      'properties': {
        'title': _string('组标题，如“在忙”“卡住了”', 40),
        'density': agentDensityField,
        'state': {
          'type': 'string',
          'enum': _states,
          'description': '这一组的状态，决定颜色',
        },
        'display': _display('AgentStatusGroup'),
        'childDisplay': _childDisplay(['AgentStatusCard']),
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
    build: (context, n, children) => HfGroup(
      title: n.string('title') ?? '',
      tone: n.string('state') == null
          ? HfTone.progress
          : hfWorkTone(_state(n.string('state'))),
      display: _spec(n),
      displayKind: 'AgentStatusGroup',
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
        'display': _display('TaskCard'),
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
    line: (n) => [
      if (n.integer('number') != null) '#${n.integer('number')}',
      n.string('title') ?? '',
    ].join(' '),
    build: (context, n, _) {
      final q = n.object('quote');
      return HfTaskCard(
        title: n.string('title') ?? '',
        status: n.string('status') ?? 'todo',
        number: n.integer('number'),
        assignee: n.string('assignee'),
        channel: n.string('channel'),
        quote: q == null ? null : formatQuote(q),
        ask: n.string('ask'),
        display: _spec(n),
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
        'display': _display('MessageQuote'),
      },
      'required': ['author', 'text'],
    },
    example: {
      'component': 'MessageQuote',
      'author': 'Cindy',
      'time': '昨天 18:20',
      'text': 'PR 已合入，全量检查 0 失败。',
    },
    line: (n) =>
        '${n.string('author') ?? ''}：${_clip(n.string('text') ?? '', 24)}',
    build: (context, n, _) => HfMessageQuote(
      author: n.string('author') ?? '',
      text: n.string('text') ?? '',
      time: n.string('time'),
      channel: n.string('channel'),
      display: _spec(n),
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
        'display': _display('StatRow'),
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
    line: (n) => [
      for (final s in n.list('stats'))
        if (s is Map) '${s['label']} ${s['value']}',
    ].join('，'),
    build: (context, n, _) => HfStatStrip(
      stats: [
        for (final s in n.list('stats'))
          if (s is Map) HfStat('${s['label']}', '${s['value']}'),
      ],
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.column,
    description: '竖着排列子组件',
    container: true,
    schema: {
      'type': 'object',
      'properties': {
        'density': agentDensityField,
        'childDisplay': _childDisplay(),
      },
    },
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
    fold: true,
    schema: {
      'type': 'object',
      'properties': {
        'title': _string('小标题', 40),
        'density': agentDensityField,
        'display': _display('Section'),
        'childDisplay': _childDisplay(),
      },
      'required': ['title'],
    },
    example: {
      'component': 'Section',
      'title': '最近讨论',
      'children': [
        {'component': 'MessageQuote', 'author': 'Cindy', 'text': '已合入'},
      ],
    },
    build: (context, n, children) => HfGroup(
      title: n.string('title') ?? '',
      display: _spec(n),
      children: children,
    ),
  ),
  AgentCatalogItem(
    name: AgentComponents.actionRow,
    description: '通过 / 打开讨论 / 稍后',
    internal: true,
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'itemId': _string('这一条的 id', 120),
        'approve': {'type': 'boolean', 'description': '提供“通过”'},
        'openLabel': _string('不能通过时主按钮的字', 30),
      },
      'required': ['itemId'],
    },
    build: (context, n, _) {
      final scope = AgentActionScope.maybeOf(context);
      void Function()? act(String a) =>
          scope == null ? null : () => scope.onAction(a);
      final id = n.string('itemId') ?? '';
      final approve = n.flag('approve') ?? false;
      return HfActions(
        actions: [
          if (approve)
            HfAction(
              '通过',
              key: ValueKey('attention-approve-$id'),
              kind: HfActionKind.primary,
              icon: Icons.check_rounded,
              onPressed: act('approve'),
            ),
          HfAction(
            n.string('openLabel') ?? '打开讨论',
            key: ValueKey('attention-open-$id'),
            kind: approve ? HfActionKind.secondary : HfActionKind.primary,
            onPressed: act('open'),
          ),
          HfAction(
            '稍后',
            key: ValueKey('attention-later-$id'),
            kind: HfActionKind.text,
            onPressed: act('later'),
          ),
        ],
      );
    },
  ),
  ...agentEntityCatalogItems,
]);

/// The catalog agent mode composes screens from.
final AgentCatalog agentStandardCatalog = _standard();

/// Draws a validated surface as a layer: title sticker, summary and the tree.
/// Items (the leaves, and a folded container as one) are [AgentFocusable]
/// numbered from 1 in reading order, the same numbers [agentSurfaceFrame] gives
/// them, so spotlight and marks work, and each draws that number on its bar
/// (the handle: ① is "1").
///
/// On a [compact] screen (the phone) a group or section folds to one summary
/// row unless its `density` says `detail`; tapping the row calls [onExpand]
/// with its path, and the owner adds it to [expanded].
class AgentSurfaceView extends StatefulWidget {
  const AgentSurfaceView({
    super.key,
    required this.spec,
    required this.focusPrefix,
    this.catalog,
    this.compact,
    this.expanded = const {},
    this.onExpand,
    this.animate = false,
  });
  final AgentSurfaceSpec spec;
  final String focusPrefix;

  /// Components enter one after another (a screen the model is composing);
  /// off for a screen that is simply there (the detail of a card).
  final bool animate;

  /// Defaults to [agentStandardCatalog].
  final AgentCatalog? catalog;

  /// Defaults to the surface: a phone folds, a desktop and a TV do not.
  final bool? compact;
  final Set<String> expanded;
  final ValueChanged<String>? onExpand;

  @override
  State<AgentSurfaceView> createState() => _AgentSurfaceViewState();
}

class _AgentSurfaceViewState extends State<AgentSurfaceView> {
  /// Components that appear (the skeleton that came with the layer, then
  /// whatever is added) enter one after another when [AgentSurfaceView.animate]
  /// is on; paint only, nothing is laid out differently for it.
  final _pacer = AgentEnterPacer();

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final spec = widget.spec;
    final catalog = widget.catalog ?? agentStandardCatalog;
    final compact = widget.compact ?? hf.phone;
    final folded = foldedPaths(
      catalog,
      spec.root,
      compact: compact,
      expanded: widget.expanded,
    );
    final numbers = focusNumbers(catalog, spec.root, folded);
    // [inherited] is what the lists above say every child looks like
    // (`childDisplay`): the nearest list that says something wins, and a
    // child's own `display` wins over all of it, element by element.
    Widget draw(SurfaceNode node, String path, DisplaySpec? inherited) {
      final item = catalog.item(node.component);
      if (item == null) return const SizedBox.shrink();
      final own = agentDisplayOf(node.props).over(inherited);
      final below = agentDisplayOf(node.props, 'childDisplay').over(inherited);
      final Widget drawn;
      if (folded.contains(path)) {
        final id = '${widget.focusPrefix}#${numbers[path]}';
        drawn = _slot(
          hf,
          AgentFocusable(
            id: id,
            child: HfItemScope(
              index: numbers[path]!,
              focusId: id,
              child: _summaryRow(
                catalog,
                node,
                display: own,
                onTap: () => widget.onExpand?.call(path),
              ),
            ),
          ),
        );
      } else {
        final children = [
          for (final (i, c) in node.children.indexed)
            draw(c, surfaceChildPath(path, i), below.isEmpty ? null : below),
        ];
        final built = item.build(
          context,
          node.copyWith(
            props: {
              ...node.props,
              // What the card draws: its own display over the lists'.
              if (!own.isEmpty) 'display': own.toJson(),
            },
          ),
          children,
        );
        if (item.container) {
          drawn = built;
        } else if (!item.focusable) {
          drawn = _slot(hf, built);
        } else {
          // A component wears the number of its place on the screen (the
          // number on its bar: "第二个" and "2" mean it), never one the
          // model wrote.
          final id = '${widget.focusPrefix}#${numbers[path]}';
          drawn = _slot(
            hf,
            AgentFocusable(
              id: id,
              child: AgentHandleTag(
                focusId: id,
                child: HfItemScope(
                  index: numbers[path]!,
                  focusId: id,
                  child: built,
                ),
              ),
            ),
          );
        }
      }
      if (path == 'r') return drawn;
      return AgentAppear(
        key: ValueKey(node.id ?? path),
        animate: widget.animate,
        child: drawn,
      );
    }

    final body = draw(spec.root, 'r', null);
    return AgentEnterPacing(
      pacer: _pacer,
      child: HfLayerFrame(
        title: spec.title,
        enterTitle: widget.animate,
        summary: spec.summary == null ? null : TextSpan(text: spec.summary),
        children: [body],
      ),
    );
  }

  /// The gap under a numbered component: a row's hard shadow hangs below it.
  Widget _slot(HfData hf, Widget child) => Padding(
    padding: EdgeInsets.only(bottom: hf.rowGap),
    child: child,
  );
}

/// The kind of thing an entity card stands for, as a person says it
/// ("消息"): what a folded row says for a card that is not read yet. Never
/// the id.
String _kindWord(SurfaceNode card) {
  final kind = AgentEntityKind.values
      .where((k) => k.name == card.string('entity'))
      .firstOrNull;
  return kind == null ? '' : agentEntityKindLabels[kind] ?? '';
}

/// What a folded container says: its members in one run. An entity card is
/// worded by [labelOf] (the label the app reads for it, "#98 修复返回", the
/// same one the card prints), else by its kind alone; never by the ids the
/// model wrote.
String _foldedText(
  AgentCatalog catalog,
  SurfaceNode node, {
  String? Function(SurfaceNode card)? labelOf,
}) => [
  for (final c in node.children)
    if (c.component == AgentEntityComponents.entity)
      _entityPhrase(c, labelOf)
    else
      catalog.item(c.component)?.line?.call(c) ?? '',
].where((s) => s.isNotEmpty).join('、');

String _entityPhrase(SurfaceNode card, String? Function(SurfaceNode)? labelOf) {
  final label = labelOf?.call(card)?.trim();
  return label == null || label.isEmpty ? _kindWord(card) : label;
}

/// The folded row of a container, kept up to date with what the cards in it
/// say: it listens to the entity resolver, so a task that changes its title
/// or an agent that goes busy shows in the row without a new surface.
class _LiveSummaryRow extends StatefulWidget {
  const _LiveSummaryRow({
    required this.catalog,
    required this.node,
    required this.onTap,
    this.display,
  });
  final AgentCatalog catalog;
  final SurfaceNode node;
  final DisplaySpec? display;
  final VoidCallback? onTap;

  @override
  State<_LiveSummaryRow> createState() => _LiveSummaryRowState();
}

class _LiveSummaryRowState extends State<_LiveSummaryRow> {
  AgentEntityResolver? _resolver;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AgentEntityScope.maybeOf(context)?.resolver;
    if (next == _resolver) return;
    _resolver?.removeListener(_changed);
    _resolver = next?..addListener(_changed);
  }

  @override
  void dispose() {
    _resolver?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    // The resolver may speak while a frame is being built.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  String? _label(SurfaceNode card) {
    final kind = AgentEntityKind.values
        .where((k) => k.name == card.string('entity'))
        .firstOrNull;
    final id = card.string('id');
    if (kind == null || id == null) return null;
    final r = _resolver?.resolve(ui.AgentEntityRef(kind, id));
    return r is AgentEntityFound ? r.data.label : null;
  }

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final display = widget.display;
    return HfSummaryRow(
      title: node.string('title') ?? '',
      count: node.children.length,
      text: _foldedText(widget.catalog, node, labelOf: _label),
      tone: node.string('state') == null
          ? HfTone.progress
          : hfWorkTone(_state(node.string('state'))),
      display: display == null || display.isEmpty ? null : display,
      displayKind: node.component == AgentComponents.section
          ? 'Section'
          : 'AgentStatusGroup',
      onTap: widget.onTap,
    );
  }
}

Widget _summaryRow(
  AgentCatalog catalog,
  SurfaceNode node, {
  DisplaySpec? display,
  VoidCallback? onTap,
}) => _LiveSummaryRow(
  catalog: catalog,
  node: node,
  display: display,
  onTap: onTap,
);

/// The surface as a serialized layer (see `AgentFrameView`): what the TV
/// mirror draws and what the voice model reads as numbered screen items.
Map<String, Object?> agentSurfaceFrame(
  AgentSurfaceSpec spec, {
  bool compact = false,
  Set<String> expanded = const {},
  AgentCatalog? catalog,
  Map<String, Object?>? Function(SurfaceNode node)? entityOf,
  String? Function(String kind, String id)? entityLabel,
  AgentEntityData? Function(String kind, String id)? entityData,
}) {
  final catalog0 = catalog ?? agentStandardCatalog;
  final folded = foldedPaths(
    catalog0,
    spec.root,
    compact: compact,
    expanded: expanded,
  );
  final items = <Map<String, Object?>>[];
  void visit(SurfaceNode n, String path) {
    if (folded.contains(path)) {
      final state = n.string('state') == null
          ? null
          : _state(n.string('state'));
      items.add({
        'kind': 'priority',
        'priority': switch (state) {
          AgentWorkState.blocked => AgentPriority.blocked,
          AgentWorkState.idle => AgentPriority.mention,
          _ => AgentPriority.progress,
        }.name,
        'label': n.string('title') ?? '',
        'weight': items.length + 1,
        'title':
            '${n.string('title') ?? ''} ${n.children.length}：${_foldedText(catalog0, n, labelOf: (c) => entityLabel != null ? entityLabel(c.string('entity') ?? '', c.string('id') ?? '') : entityOf?.call(c)?['label'] as String?)}',
        'detail': '摘要，点开或说“展开”看全部',
      });
      return;
    }
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
          'entity': ?entityOf?.call(n),
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
          'entity': ?entityOf?.call(n),
        });
      case AgentComponents.messageQuote:
        items.add({
          'kind': 'message',
          'sender': n.string('author') ?? '',
          'time': n.string('time') ?? '',
          'text': n.string('text') ?? '',
          'entity': ?entityOf?.call(n),
        });
      case AgentEntityComponents.entity:
        // What it shows is read by the app at draw time; the model is told
        // which thing it pointed at, by the title the app read for it. The
        // TV has no workspace of its own, so the facts travel in the frame.
        final entity = entityOf?.call(n);
        final kind = n.string('entity') ?? '';
        final id = n.string('id') ?? '';
        final facts = switch (entityData?.call(kind, id)) {
          final d? => agentEntityFacts(d),
          null => null,
        };
        items.add({
          'kind': facts?.message == true ? 'message' : 'priority',
          'priority': (facts?.priority ?? AgentPriority.progress).name,
          'label':
              facts?.status ??
              agentEntityKindLabels.entries
                  .firstWhere(
                    (e) => e.key.name == kind,
                    orElse: () => agentEntityKindLabels.entries.first,
                  )
                  .value,
          'weight': items.length + 1,
          'title': entity == null ? id : '${entity['label']}',
          'detail': facts == null ? (entity == null ? id : null) : facts.detail,
          if (facts?.message == true) ...{
            'sender': facts!.sender,
            'time': facts.time,
            'text': facts.text,
          },
          'entity': ?entity,
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
    for (final (i, c) in n.children.indexed) {
      visit(c, surfaceChildPath(path, i));
    }
  }

  visit(spec.root, 'r');
  // What the TV draws the screen from: the screen itself, and what the
  // entity cards on it say (the TV has no workspace to read them from).
  final entities = <String, Object?>{};
  for (final (kind, id) in _entityRefs(spec.root)) {
    final data = entityData?.call(kind, id);
    if (data != null) entities['$kind:$id'] = agentEntityToJson(data);
  }
  return {
    'title': spec.title,
    'loading': false,
    'summary': spec.summary,
    'items': items,
    'spec': spec.toJson(),
    'expanded': expanded.toList(),
    // Folded the way the numbers above were counted: the TV draws the same.
    'compact': compact,
    'entities': entities,
  };
}

/// Every thing the screen points at: entity cards, table cells, timeline
/// items.
Iterable<(String, String)> _entityRefs(SurfaceNode root) sync* {
  for (final n in root.walk()) {
    switch (n.component) {
      case AgentEntityComponents.entity:
        yield (n.string('entity') ?? '', n.string('id') ?? '');
      case AgentEntityComponents.table:
        for (final row in n.list('rows')) {
          if (row is! List) continue;
          for (final c in row) {
            if (c is Map) yield ('${c['entity']}', '${c['id']}');
          }
        }
      case AgentEntityComponents.timeline:
        for (final i in n.list('items')) {
          if (i is Map && i['entity'] != null) {
            yield ('${i['entity']}', '${i['id']}');
          }
        }
    }
  }
}

/// What an entity card says when it is drawn from a frame instead of the
/// workspace (the TV): its status word, how urgent it looks, and one line.
typedef AgentEntityFacts = ({
  String? status,
  AgentPriority priority,
  String? detail,
  bool message,
  String? sender,
  String? time,
  String? text,
});

AgentEntityFacts agentEntityFacts(AgentEntityData d) {
  String? line(List<String?> parts) {
    final kept = [
      for (final p in parts)
        if (p != null && p.trim().isNotEmpty) p.trim(),
    ];
    return kept.isEmpty ? null : kept.join(' · ');
  }

  AgentEntityFacts plain(String? status, AgentPriority p, String? detail) => (
    status: status,
    priority: p,
    detail: detail,
    message: false,
    sender: null,
    time: null,
    text: null,
  );
  return switch (d) {
    AgentAgentData() => plain(agentWorkStateLabels[d.state], switch (d.state) {
      AgentWorkState.busy => AgentPriority.progress,
      AgentWorkState.blocked => AgentPriority.blocked,
      _ => AgentPriority.mention,
    }, line([d.activity, d.since, if (d.channel != null) '#${d.channel}'])),
    AgentTaskData() => plain(
      agentTaskStatusLabels[d.status] ?? d.status,
      switch (d.status) {
        'in_review' => AgentPriority.decision,
        'in_progress' => AgentPriority.progress,
        _ => AgentPriority.mention,
      },
      line([
        d.assignee,
        if (d.channel != null) '#${d.channel}',
        d.latestProgress ?? d.updated,
      ]),
    ),
    AgentMessageData() => (
      status: null,
      priority: AgentPriority.progress,
      detail: null,
      message: true,
      sender: d.author,
      time: line([d.time, if (d.channel != null) '#${d.channel}']),
      text: d.text,
    ),
    AgentChannelData() => plain(
      d.unread > 0 ? '${d.unread} 条未读' : (d.direct ? '私信' : '频道'),
      d.mentioned ? AgentPriority.mention : AgentPriority.progress,
      line([
        d.description,
        if (d.memberCount != null) '${d.memberCount} 人',
        d.lastActivity,
      ]),
    ),
    AgentMemberData() => plain(
      d.presence == null ? '成员' : agentPresenceLabels[d.presence],
      AgentPriority.progress,
      d.role,
    ),
    AgentComputerData() => plain(
      d.online ? '在线' : '离线',
      d.online ? AgentPriority.progress : AgentPriority.blocked,
      line([
        if (d.agentCount > 0) '${d.agentCount} 个 Agent',
        if (d.runtimes.isNotEmpty) d.runtimes.join('、'),
        d.version,
      ]),
    ),
    AgentFileData() => plain(
      d.type ?? '文件',
      AgentPriority.progress,
      line([d.size, d.author]),
    ),
  };
}
