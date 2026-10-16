import 'package:raft_agent_ui/raft_agent_ui.dart'
    show AgentEntityKind, DisplaySpec, agentDisplaySchema, mergeDisplayJson;

import '../../../data/workspace_controller.dart';
import '../agent_catalog.dart';
import '../agent_entity_binding.dart' show AgentEntityComponents;
import '../agent_surface.dart';
import '../agent_surface_stream.dart';
import '../agent_surface_tools.dart' show AgentSurfaceHost;
import '../references/agent_reference_table.dart';
import 'action_support.dart' show messageById;
import 'agent_capability.dart';
import 'agent_capability_args.dart';
import 'agent_capability_standard.dart';
import 'task_capabilities.dart' show taskRelations;

/// The direct read tools: one call fetches through the capability registry and
/// the app draws the answer itself, as entity cards, on the screen. The model
/// then says one sentence. They exist so that the common questions ("看所有
/// 任务", "搜一下发布", "Cody 在干嘛") are one tool call, not find, query and
/// compose.
const agentReadToolNames = {
  'show_list',
  'show_item',
  'search_messages',
  'show_thread',
  'show_agent_activity',
  'show_task_history',
};

/// The kinds `show_list` lists.
const agentListKinds = [
  'channels',
  'dms',
  'tasks',
  'agents',
  'computers',
  'members',
  'saved',
  'inbox',
  'mentions',
];

/// The kinds `show_item` shows.
const agentItemKinds = [
  'channel',
  'task',
  'agent',
  'computer',
  'member',
  'message',
];

final _entityKindNames = [for (final k in AgentEntityKind.values) k.name];

/// The schema of a display field as the model is given it (the same words as
/// the catalog's, without the catalog's own markers).
Map<String, Object?> _plain(Map<String, Object?> schema) => {
  for (final e in schema.entries)
    if (e.key != 'x-describe')
      e.key: e.value is Map
          ? _plain((e.value as Map).cast<String, Object?>())
          : e.value,
};

/// `display` of the one card a tool draws.
final _cardDisplay = _plain(agentDisplaySchema(_entityKindNames));

/// `display` of the list a tool draws (the group of cards, not the cards).
final _listDisplay = _plain(agentDisplaySchema(['Section']));

/// `childDisplay`: what every card of the list looks like. A list is drawn
/// at `medium` (headline and one meta line) on a phone and at `detail` on a
/// wide screen, unless this says otherwise.
final _cardsDisplay = _plain(
  agentDisplaySchema(_entityKindNames, childDisplay: true),
);

/// The declarations of the direct read tools. The descriptions are what the
/// model chooses by, so each says when to use it and when not.
final agentReadToolDeclarations = <Map<String, Object?>>[
  {
    'name': 'show_list',
    'description':
        '把一类东西完整展开在屏幕上：App 直接画成卡片，你只说一句话。用户说“看所有X”“列出X”“有哪些X”“我的X”时用，'
        '例：“看所有任务”→kind=tasks；“有哪些频道”→channels；“谁在线/所有成员”→members；“有未读的频道”→channels+unread_only；'
        '“等验收的任务”→tasks+status=in_review；“提到我的”→mentions。'
        '“我的任务”→kind=tasks+mine=true（我创建的、派给我的、或提到我的；只要派给我的用 relation=assigned，只要我创建的用 relation=created），不要把“我的”当成 assignee=me。'
        '不是搜关键词（那用 search_messages），也不是看某一个（那用 show_item）。'
        '结果按固定顺序排（result.order，任务是最近更新的在前），屏幕上的卡片和 result.items 完全同序，items 里每项带编号 handle：之后说到其中一项就用它的编号。'
        '默认手机上每张卡片是一行标题加一行说明（medium），宽屏是完整的（detail）；用户说“详细一点”“简单点”“不要头像”，才用 childDisplay（或 update_component）改。',
    'parameters': {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': agentListKinds,
          'description': 'channels 频道 / dms 私信 / tasks 任务 / agents Agent / computers 电脑 / members 成员 / saved 收藏 / inbox 动态 / mentions 提到我的',
        },
        'status': {
          'type': 'string',
          'description': 'tasks：todo、in_progress、in_review、done、closed、open（默认，进行中+待验收+待办）；agents：busy、idle、blocked、offline；computers：online、offline',
        },
        'channel': {'type': 'string', 'description': '只看这个频道（名字或 id）'},
        'assignee': {
          'type': 'string',
          'description':
              'tasks：负责人（名字；me 是我自己，unassigned 是没人认领）。“我的任务”不要用这个，用 mine',
        },
        'mine': {
          'type': 'boolean',
          'description': 'tasks：我的任务：我创建的、派给我的、或提到我的（等于 relation=any_mine）',
        },
        'relation': {
          'type': 'string',
          'enum': taskRelations,
          'description': 'tasks：和我的关系：assigned 派给我 / created 我创建的 / any_mine 三者之一（“我的任务”的默认）',
        },
        'creator': {'type': 'string', 'description': 'tasks：创建人（名字；me 是我）'},
        'role': {
          'type': 'string',
          'description': 'members：owner / admin / member',
        },
        'query': {'type': 'string', 'description': '名字或标题里的字（筛选，不是全文搜索）'},
        'unread_only': {
          'type': 'boolean',
          'description': 'channels、inbox：只要有未读的',
        },
        'include_archived': {
          'type': 'boolean',
          'description': 'channels：包含已归档',
        },
        'limit': {'type': 'integer', 'description': '最多几个，默认 30'},
        'offset': {'type': 'integer', 'description': '往后翻：跳过几个'},
        'display': _listDisplay,
        'childDisplay': _cardsDisplay,
      },
      'required': ['kind'],
    },
  },
  {
    'name': 'show_item',
    'description':
        '在屏幕上展开一个具体的东西（一个频道、任务、Agent、电脑、成员或消息）的卡片。'
        '用户点名要看某一个时用：“Cody 怎么样”“看看 #98”“打开 design 频道”“第二个展开”。'
        '给 id，或屏幕上的编号 handle（③），或名字（任务给 number）。要看一类的全部用 show_list。',
    'parameters': {
      'type': 'object',
      'properties': {
        'kind': {'type': 'string', 'enum': agentItemKinds},
        'id': {'type': 'string', 'description': '读取工具或屏幕引用给的 id'},
        'handle': {'type': 'string', 'description': '屏幕上的编号，如 ③ 或 3'},
        'name': {'type': 'string', 'description': '名字：频道名、Agent 名、成员名、电脑名'},
        'number': {'type': 'integer', 'description': 'tasks：任务编号，不带 #'},
        'channel': {'type': 'string', 'description': '任务编号重复时的频道名'},
        'display': _cardDisplay,
      },
      'required': ['kind'],
    },
  },
  {
    'name': 'search_messages',
    'description':
        '按关键词搜消息，结果直接画成消息卡片。用户说“搜一下X”“找找谁说过X”“X 那条消息”时用，'
        '例：“搜一下发布”→q=发布；“Cody 昨天说了什么”→sender=Cody+since；“design 频道里提到上线的”→q=上线+channel=design。'
        '不是列一类东西（那用 show_list）。',
    'parameters': {
      'type': 'object',
      'properties': {
        'q': {'type': 'string', 'description': '关键词；只按发送人或时间找时可省略'},
        'channel': {'type': 'string', 'description': '限定频道（名字或 id）'},
        'sender': {'type': 'string', 'description': '限定发送人（成员或 Agent 的名字）'},
        'since': {
          'type': 'string',
          'description': '从什么时候起：today、7d、30d，或日期 2026-10-15',
        },
        'sort': {
          'type': 'string',
          'enum': ['relevance', 'recent'],
          'description': 'relevance 相关度（默认）/ recent 最新的在前（用户问“最新的”“最近的”时用）',
        },
        'limit': {'type': 'integer', 'description': '最多几条，默认 10'},
        'display': _listDisplay,
        'childDisplay': _cardsDisplay,
      },
    },
  },
  {
    'name': 'show_thread',
    'description':
        '展开一条消息下面的整个讨论串（原消息加所有回复）。用户说“看这条的讨论”“这条下面说了什么”“第二条的回复”时用；'
        '给消息 id 或屏幕编号。',
    'parameters': {
      'type': 'object',
      'properties': {
        'message': {'type': 'string', 'description': '消息 id'},
        'handle': {'type': 'string', 'description': '屏幕上的编号，如 ② 或 2'},
        'display': _cardDisplay,
        'childDisplay': _cardsDisplay,
      },
    },
  },
  {
    'name': 'show_agent_activity',
    'description':
        '一个 Agent 最近在干什么：它的卡片加最近的活动时间线。用户说“Cody 在干嘛”“它刚才做了什么”“看看 Bo 的活动”时用。',
    'parameters': {
      'type': 'object',
      'properties': {
        'agent': {'type': 'string', 'description': 'Agent 的名字或 id'},
        'limit': {'type': 'integer', 'description': '最近几条，默认 12'},
        'display': _cardDisplay,
      },
      'required': ['agent'],
    },
  },
  {
    'name': 'show_task_history',
    'description':
        '一个任务的变更历史：任务卡加时间线（谁什么时候改了状态、负责人）。用户说“#98 什么时候改的状态”“这个任务的历史”“谁指派的”时用；'
        '给任务编号 number 或 task id。',
    'parameters': {
      'type': 'object',
      'properties': {
        'task': {'type': 'string', 'description': '任务编号（#98 或 98）或任务 id'},
        'channel': {'type': 'string', 'description': '编号重复时的频道名'},
        'limit': {'type': 'integer', 'description': '最近几条，默认 12'},
        'display': _cardDisplay,
      },
      'required': ['task'],
    },
  },
];

final _idFormat = RegExp(r'^[A-Za-z0-9_\-]{1,64}$');

/// One card of a list, in the order it is drawn.
class _Card {
  const _Card({
    required this.entity,
    required this.id,
    required this.label,
    this.note,
  });

  final String entity;
  final String id;
  final String label;

  /// Where it stands, for the model ("待验收 · 2h").
  final String? note;
}

class _ListKind {
  const _ListKind({
    required this.word,
    required this.capability,
    required this.key,
    required this.entity,
    required this.args,
    this.accepts = const {},
    this.order = '按列表原来的顺序',
  });

  /// How the rows are ordered, in the words the model is told.
  final String order;

  /// "任务": what the screen is titled.
  final String word;
  final String capability;

  /// The key of the rows in the capability's result.
  final String key;

  /// What the cards are (`EntityCard.entity`); null when each row decides.
  final String? entity;
  final Map<String, Object?> Function(Map<String, Object?> a) args;

  /// The filters this kind understands (the others are said to be ignored).
  final Set<String> accepts;
}

Map<String, Object?> _only(Map<String, Object?> m) => {
  for (final e in m.entries)
    if (e.value != null) e.key: e.value,
};

final _listKinds = <String, _ListKind>{
  'channels': _ListKind(
    word: '频道',
    capability: 'channels.list',
    key: 'channels',
    entity: 'channel',
    accepts: const {'query', 'unread_only', 'include_archived'},
    order: 'name asc',
    args: (a) => _only({
      'query': a['query'],
      'unreadOnly': a['unread_only'],
      'includeArchived': a['include_archived'],
    }),
  ),
  'dms': _ListKind(
    word: '私信',
    capability: 'dms.list',
    key: 'dms',
    entity: 'channel',
    accepts: const {'query'},
    args: (a) => _only({'query': a['query']}),
  ),
  'tasks': _ListKind(
    word: '任务',
    capability: 'tasks.board',
    key: 'tasks',
    entity: 'task',
    accepts: const {
      'status',
      'channel',
      'assignee',
      'creator',
      'query',
      'mine',
      'relation',
    },
    order: 'updated desc',
    args: (a) => _only({
      'status': a['status'],
      'channel': a['channel'],
      'assignee': a['assignee'],
      'creator': a['creator'],
      // "My tasks": created by me, assigned to me or mentioning me, unless
      // the model names one of them.
      'relation': a['relation'] ?? (a['mine'] == true ? 'any_mine' : null),
      'q': a['query'],
    }),
  ),
  'agents': _ListKind(
    word: 'Agent',
    capability: 'agents.list',
    key: 'agents',
    entity: 'agent',
    accepts: const {'status', 'query'},
    args: (a) => _only({'state': a['status'], 'query': a['query']}),
  ),
  'computers': _ListKind(
    word: '电脑',
    capability: 'computers.list',
    key: 'computers',
    entity: 'computer',
    accepts: const {'status'},
    args: (a) => _only({'status': a['status']}),
  ),
  'members': _ListKind(
    word: '成员',
    capability: 'members.list',
    key: 'members',
    entity: 'member',
    accepts: const {'query', 'role'},
    args: (a) => _only({'query': a['query'], 'role': a['role']}),
  ),
  'saved': _ListKind(
    word: '收藏',
    capability: 'saved.list',
    key: 'saved',
    entity: 'message',
    accepts: const {'query', 'channel'},
    args: (a) => _only({'q': a['query'], 'channel': a['channel']}),
  ),
  'inbox': _ListKind(
    word: '动态',
    capability: 'activity.inbox',
    key: 'items',
    entity: null,
    accepts: const {'query', 'channel', 'unread_only'},
    args: (a) => _only({
      'filter': a['unread_only'] == true ? 'unread' : 'all',
      'q': a['query'],
      'channel': a['channel'],
    }),
  ),
  'mentions': _ListKind(
    word: '提到我的',
    capability: 'activity.mentions',
    key: 'items',
    entity: null,
    accepts: const {'query', 'channel'},
    args: (a) => _only({'q': a['query'], 'channel': a['channel']}),
  ),
};

const _filterNames = {
  'status',
  'channel',
  'assignee',
  'creator',
  'role',
  'query',
  'unread_only',
  'include_archived',
  'mine',
  'relation',
};

/// A word for each task status, for the lines the model reads.
const _taskStatusWords = {
  'in_review': '待验收',
  'in_progress': '进行中',
  'todo': '待办',
  'done': '已完成',
  'closed': '已关闭',
};

/// The most cards one screen of these tools holds (the surface limit is 80
/// nodes, and a person cannot use more at once).
const agentReadMaxCards = 40;

/// Runs the direct read tools. Every tool: fetch through the registry, build
/// a surface of entity cards the app draws from its own data, show it as one
/// layer, and answer the model with a few labels and what to say.
class AgentReadTools {
  AgentReadTools({
    required this.workspace,
    required this.env,
    required this.host,
    AgentCapabilityRegistry? registry,
    AgentCatalog? catalog,
    AgentReferenceTable Function()? references,
    this.compact,
  }) : registry = registry ?? agentStandardCapabilities,
       catalog = catalog ?? agentStandardCatalog,
       _references = references ?? (() => AgentReferenceTable.empty);

  final WorkspaceController workspace;
  final AgentCapabilityEnv env;
  final AgentSurfaceHost host;
  final AgentCapabilityRegistry registry;
  final AgentCatalog catalog;
  final AgentReferenceTable Function() _references;

  /// Whether the screen is a phone's: lists are drawn at `medium` there (a
  /// 360 x 800 screen holds one and a half detail task cards) and at `detail`
  /// on a wide screen. Null is wide.
  final bool Function()? compact;

  /// The level a list is drawn at when the model does not say.
  String get _listLevel => (compact?.call() ?? false) ? 'medium' : 'detail';

  int _surfaces = 0;

  static final Map<String, Map<String, Object?>> _schemas = {
    for (final d in agentReadToolDeclarations)
      '${d['name']}': (d['parameters'] as Map).cast<String, Object?>(),
  };

  /// Runs [name]; null when it is not one of [agentReadToolNames]. [cancelled]
  /// is asked after every wait: a turn that was replaced meanwhile shows
  /// nothing.
  Future<Map<String, Object?>?> run(
    String name,
    Map<String, Object?> args, {
    bool Function()? cancelled,
  }) async {
    if (!agentReadToolNames.contains(name)) return null;
    final checked = checkAgentArgs(_schemas[name]!, args);
    if (!checked.ok) {
      return {
        'error': '参数不对：${checked.problems.join('；')}',
        'problems': checked.problems,
      };
    }
    final bad = _displayProblems(name, checked.args);
    if (bad.isNotEmpty) {
      return {'error': '参数不对：${bad.take(4).join('；')}', 'problems': bad};
    }
    bool stale() => cancelled?.call() ?? false;
    _drawn = null;
    try {
      final result = switch (name) {
        'show_list' => await _list(checked.args, stale),
        'show_item' => await _item(checked.args, stale),
        'search_messages' => await _search(checked.args, stale),
        'show_thread' => await _thread(checked.args, stale),
        'show_agent_activity' => await _activity(checked.args, stale),
        _ => await _history(checked.args, stale),
      };
      if (result.containsKey('error') || stale()) return result;
      final refs = _references();
      final drawn = _drawn;
      return {
        ...result,
        // To change how it looks later: update_component on these.
        if (drawn != null) ...{'surface_id': drawn.id, 'root': drawn.root.id},
        if (!refs.isEmpty) 'refs': refs.contextText(),
      };
    } on AgentCapabilityError catch (e) {
      return e.toJson();
    }
  }

  // ---- reading ---------------------------------------------------------

  Future<Map<String, Object?>> _read(
    String id,
    Map<String, Object?> args,
  ) async {
    final capability = registry[id];
    if (capability == null) throw AgentCapabilityError('没有这项能力：$id');
    final checked = checkAgentArgs(capability.paramsSchema, args);
    if (!checked.ok) {
      throw AgentCapabilityError('参数不对：${checked.problems.join('；')}');
    }
    return capability.run(workspace, checked.args, env);
  }

  // ---- drawing ---------------------------------------------------------

  /// A display the model wrote, as a map; null when it said nothing.
  static Map<String, Object?>? _spec(Object? v) =>
      v is Map && v.isNotEmpty ? v.cast<String, Object?>() : null;

  /// What is wrong with the `display` and `childDisplay` the model gave, by
  /// the catalog's own checks: the same words an `update_component` would be
  /// refused with.
  List<String> _displayProblems(String name, Map<String, Object?> a) {
    final problems = <String>[];
    final display = _spec(a['display']);
    final children = _spec(a['childDisplay']);
    final listy = name == 'show_list' || name == 'search_messages';
    void check(String component, Map<String, Object?> props) {
      final item = catalog.item(component);
      if (item != null) problems.addAll(catalog.checkProps(item, props, '参数'));
    }

    if (display != null) {
      if (listy) {
        check(AgentComponents.section, {'title': 'x', 'display': display});
      } else {
        final kind = switch (name) {
          'show_item' => '${a['kind']}',
          'show_thread' => 'message',
          'show_agent_activity' => 'agent',
          _ => 'task',
        };
        check(AgentEntityComponents.entity, {
          'entity': kind,
          'id': 'x',
          'display': display,
        });
        problems.addAll(DisplaySpec.problems(display, kind, '参数.display'));
      }
    }
    if (children != null) {
      check(AgentComponents.column, {'childDisplay': children});
    }
    return problems;
  }

  Map<String, Object?> _card(
    String entity,
    String id, {
    bool high = false,
    Map<String, Object?>? display,
  }) => {
    'component': AgentEntityComponents.entity,
    'entity': entity,
    'id': id,
    if (high) 'emphasis': 'high',
    'display': ?display,
  };

  /// A group of cards. Not folded (the person asked to see them); [display]
  /// is the group's own look. The cards' look is the screen's `childDisplay`
  /// (see [_show]), so one change to the screen reaches every group.
  Map<String, Object?> _section(
    String title,
    List<Map<String, Object?>> children, {
    Map<String, Object?>? display,
  }) => {
    'component': AgentComponents.section,
    'title': title.length > 40 ? title.substring(0, 40) : title,
    'density': 'detail',
    'display': ?display,
    'children': children,
  };

  /// The group of a list tool: the model's `display` is the group's.
  Map<String, Object?> _group(
    String title,
    List<Map<String, Object?>> children,
    Map<String, Object?> a,
  ) => _section(title, children, display: _spec(a['display']));

  /// The surface drawn by the call being run (null before it draws).
  AgentSurfaceDraft? _drawn;

  /// Puts [children] on the screen as one new layer. Null when the surface
  /// was refused (never for a valid id).
  Map<String, Object?>? _show(
    String title,
    List<Map<String, Object?>> children, [
    Map<String, Object?>? childDisplay,
    String level = 'detail',
  ]) {
    final base = {'level': level};
    final parsed = catalog.parse({
      'title': title.length > 60 ? title.substring(0, 60) : title,
      'root': {
        'component': AgentComponents.column,
        'density': 'detail',
        // Everything is drawn at [level] unless the model says otherwise;
        // what it says is the screen's, so `update_component` on the root changes
        // every card at once.
        'childDisplay': childDisplay == null
            ? base
            : mergeDisplayJson(base, childDisplay),
        'children': children,
      },
    });
    if (!parsed.ok) {
      return {'error': '这块界面没能显示：${parsed.problems.take(3).join('；')}'};
    }
    final spec = parsed.spec!;
    final probe = AgentSurfaceDraft(
      id: 'r${++_surfaces}',
      title: spec.title,
      summary: spec.summary,
      root: spec.root,
    );
    final draft = AgentSurfaceDraft(
      id: probe.id,
      title: spec.title,
      summary: spec.summary,
      root: probe.named(spec.root),
    )..ended = true;
    _drawn = draft;
    host.begin(draft);
    return null;
  }

  // ---- show_list -------------------------------------------------------

  Future<Map<String, Object?>> _list(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    final kind = _listKinds['${a['kind']}']!;
    final given = {
      for (final f in _filterNames)
        if (a[f] != null) f,
    };
    final ignored = given.difference(kind.accepts);
    final capability = registry[kind.capability];
    if (capability == null) return {'error': '这个版本没有 ${kind.word} 的读取能力'};
    final props = (capability.paramsSchema['properties'] as Map?) ?? const {};
    int cap(String key, int dflt) {
      final max = ((props[key] as Map?)?['maximum'] as int?) ?? dflt;
      return max < dflt ? max : dflt;
    }

    final ask = {
      ...kind.args(a),
      if (props.containsKey('limit'))
        'limit': ((a['limit'] as int?) ?? 30).clamp(
          1,
          cap('limit', agentReadMaxCards),
        ),
      if (props.containsKey('offset') && a['offset'] != null)
        'offset': a['offset'],
    };
    final result = await _read(kind.capability, ask);
    if (stale()) return const {};
    final rows = [
      for (final r in (result[kind.key] as List? ?? const []))
        if (r is Map) r.cast<String, Object?>(),
    ];
    final cards = <_Card>[];
    final seen = <String>{};
    for (final r in rows) {
      final ref = _rowRef(kind, r);
      if (ref == null || !seen.add('${ref.entity}:${ref.id}')) continue;
      cards.add(
        _Card(
          entity: ref.entity,
          id: ref.id,
          label: _label(r),
          note: kind.entity == 'task' ? _taskNote(r) : null,
        ),
      );
      if (cards.length >= agentReadMaxCards) break;
    }
    final total = (result['total'] as num?)?.toInt() ?? rows.length;
    final title =
        '${kind.word} · ${cards.length}'
        '${total > cards.length ? ' / $total' : ''}';
    if (cards.isEmpty) {
      final shown = _show(title, [
        {
          'component': AgentEntityComponents.callout,
          'text': '没有符合条件的${kind.word}',
        },
      ]);
      return shown ??
          {
            'ok': true,
            'kind': a['kind'],
            'shown': 0,
            'say': '没有符合条件的${kind.word}，如实说一句',
          };
    }
    // One group, in the order of the result: what is said (handle ①, ②, ...)
    // is what is drawn, card for card. Nothing regroups it by status.
    final children = <Map<String, Object?>>[
      _group(title, [for (final c in cards) _card(c.entity, c.id)], a),
    ];
    if (total > cards.length) {
      children.add({
        'component': AgentEntityComponents.callout,
        'text': '还有 ${total - cards.length} 个没显示',
      });
    }
    final level = _listLevel;
    final refused = _show(title, children, _spec(a['childDisplay']), level);
    if (refused != null) return refused;
    return {
      'ok': true,
      'kind': a['kind'],
      'shown': cards.length,
      'total': total,
      'order': (result['order'] as String?) ?? kind.order,
      'items': _numbered(cards),
      if (ignored.isNotEmpty) 'ignoredFilters': ignored.toList(),
      'screen':
          '已展开在屏幕上，每项一张卡片（${level == 'medium' ? '一行标题加一行说明，用户要看细节再说“详细一点”' : '完整'}）；'
          'items 就是屏幕上从上到下的顺序，编号 ① ② … 可以指',
      'say': '只说一句话（一共几个，要紧或最新的一个，说它的编号）；之后提到哪一项就说它的编号；不要念列表，不要再调用别的工具',
    };
  }

  /// The result's view of the cards, in the order they are drawn, each with
  /// the handle the screen gives it (the nth card is ①, ②, ...).
  static List<Map<String, Object?>> _numbered(List<_Card> cards) => [
    for (final (i, c) in cards.indexed)
      {
        'n': i + 1,
        'handle': agentHandle(i + 1),
        'id': c.id,
        'label': c.label,
        'note': ?c.note,
      },
  ];

  /// "待验收 · 2 小时前": where a task stands and when it last moved.
  static String _taskNote(Map<String, Object?> r) {
    final status = '${r['status']}';
    return [
      _taskStatusWords[status] ?? status,
      if (r['updated'] != null) '${r['updated']}',
    ].join(' · ');
  }

  /// The card a row is: its kind and id; null when it has no usable id.
  ({String entity, String id})? _rowRef(
    _ListKind kind,
    Map<String, Object?> r,
  ) {
    String? entity = kind.entity;
    String? id = r['id'] is String ? r['id'] as String : null;
    if (entity == null) {
      // The Activity inbox: a thread is its parent message, else the channel.
      if (r['kind'] == 'thread' && r['parentMessageId'] is String) {
        entity = 'message';
        id = r['parentMessageId'] as String;
      } else {
        entity = 'channel';
        id = r['channelId'] is String ? r['channelId'] as String : null;
      }
    }
    if (id == null || !_idFormat.hasMatch(id)) return null;
    return (entity: entity, id: id);
  }

  static String _label(Map<String, Object?> r) {
    final number = r['number'];
    final title = r['title'] ?? r['name'] ?? r['filename'] ?? r['text'];
    final from = r['from'];
    final text = '${title ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
    final short = text.length > 24 ? '${text.substring(0, 24)}…' : text;
    return [
      if (number != null) '#$number',
      if (title == null && from != null) '$from',
      short,
    ].where((s) => s.isNotEmpty).join(' ');
  }

  // ---- show_item -------------------------------------------------------

  static const _detail = {
    'channel': ('channels.detail', 'channel', 'channel'),
    'task': ('tasks.detail', 'task', 'task'),
    'agent': ('agents.detail', 'agent', 'agent'),
    'computer': ('computers.detail', 'computer', 'computer'),
    'member': ('members.profile', 'member', 'member'),
  };

  Future<Map<String, Object?>> _item(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    final kind = '${a['kind']}';
    var id = a['id'] as String?;
    final handle = a['handle'] as String?;
    if (id == null && handle != null) {
      final ref = _references().byHandle(handle);
      if (ref == null || ref.id == null) {
        return {'error': '屏幕上没有 $handle 这个编号：问用户是哪一个'};
      }
      if (ref.type != kind) {
        return {
          'error':
              '$handle 是${AgentEntityTypes.labels[ref.type] ?? ref.type}，不是 $kind',
        };
      }
      id = ref.id;
    }
    if (id == null) {
      final spec = _detail[kind];
      final name = a['name'] as String?;
      final number = a['number'];
      if (spec == null || (name == null && number == null)) {
        return {'error': '要给 id、handle 或名字（任务给 number）'};
      }
      final read = await _read(spec.$1, {
        if (kind == 'task') ...{
          'number': number,
          'channel': a['channel'],
        } else
          spec.$2: name,
      });
      if (stale()) return const {};
      final row = read[spec.$3];
      id = row is Map && row['id'] is String ? row['id'] as String : null;
      if (id == null) return {'error': '没找到这个$kind'};
    }
    if (!_idFormat.hasMatch(id)) return {'error': 'id 不对：要取自读取工具的结果'};
    if (stale()) return const {};
    final refused = _show(_titleOf(kind), [
      _card(kind, id, high: true, display: _spec(a['display'])),
    ]);
    if (refused != null) return refused;
    return {
      'ok': true,
      'kind': kind,
      'id': id,
      'screen': '卡片已在屏幕上',
      'say': '只说一句话；细节在卡片上，不要念',
    };
  }

  static String _titleOf(String kind) => AgentEntityTypes.labels[kind] ?? kind;

  // ---- search_messages -------------------------------------------------

  Future<Map<String, Object?>> _search(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    final since = a['since'] as String?;
    final result = await _read('messages.search', {
      'q': a['q'],
      'channel': a['channel'],
      'sender': a['sender'],
      if (since != null)
        if (const {'today', '7d', '30d'}.contains(since))
          'within': since
        else
          'after': since,
      'sort': a['sort'],
      'limit': ((a['limit'] as int?) ?? 10).clamp(1, 20),
    });
    if (stale()) return const {};
    final rows = [
      for (final r in (result['messages'] as List? ?? const []))
        if (r is Map &&
            r['id'] is String &&
            _idFormat.hasMatch(r['id'] as String))
          r.cast<String, Object?>(),
    ];
    final q = a['q'] as String?;
    final title = q == null || q.isEmpty
        ? '消息 · ${rows.length}'
        : '搜“$q” · ${rows.length}';
    if (rows.isEmpty) {
      _show(title, [
        {'component': AgentEntityComponents.callout, 'text': '没有找到符合的消息'},
      ]);
      return {'ok': true, 'shown': 0, 'say': '没有找到，如实说一句，可以建议换个关键词'};
    }
    final level = _listLevel;
    final refused = _show(
      title,
      [
        _group(title, [
          for (final r in rows) _card('message', r['id']! as String),
        ], a),
        if (result['hasMore'] == true)
          {'component': AgentEntityComponents.callout, 'text': '还有更多结果'},
      ],
      _spec(a['childDisplay']),
      level,
    );
    if (refused != null) return refused;
    final recent = a['sort'] == 'recent';
    return {
      'ok': true,
      'shown': rows.length,
      'order': recent ? 'newest first' : 'relevance',
      'items': [
        for (final (i, r) in rows.indexed)
          {
            'n': i + 1,
            'handle': agentHandle(i + 1),
            'id': r['id'],
            'label': _clipText('${r['from'] ?? ''}：${r['text'] ?? ''}', 60),
            if (r['time'] != null) 'note': '${r['time']}',
          },
      ],
      'screen': '消息卡片已在屏幕上，items 就是从上到下的顺序，编号 ① ② … 可以指',
      'say': '只说一句话（找到几条，${recent ? '最新的' : '最相关的'}是谁说的，说它的编号）；不要念消息内容',
    };
  }

  // ---- show_thread -----------------------------------------------------

  Future<Map<String, Object?>> _thread(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    var id = a['message'] as String?;
    final handle = a['handle'] as String?;
    if (id == null && handle != null) {
      final ref = _references().byHandle(handle);
      if (ref == null || ref.id == null) {
        return {'error': '屏幕上没有 $handle 这个编号：问用户是哪一个'};
      }
      id = ref.id;
    }
    if (id == null) return {'error': '要给 message（消息 id）或 handle（屏幕编号）'};
    final parent = await messageById(workspace, id);
    String? threadId = parent.string('threadChannelId').isEmpty
        ? null
        : parent.string('threadChannelId');
    threadId ??= parent.string('threadId').isEmpty
        ? null
        : parent.string('threadId');
    if (threadId == null) {
      try {
        final info = await workspace.query(
          '/channels/${parent.channelId}/threads/${parent.id}',
        );
        final found = info is Map ? info['threadChannelId'] : null;
        if (found is String && found.isNotEmpty) threadId = found;
      } on Object {
        // No thread under it.
      }
    }
    if (stale()) return const {};
    final replies = threadId == null
        ? const <Map<String, Object?>>[]
        : [
            for (final r
                in ((await _read('threads.messages', {
                          'threadId': threadId,
                          'limit': 30,
                        }))['messages']
                        as List? ??
                    const []))
              if (r is Map &&
                  r['id'] is String &&
                  _idFormat.hasMatch(r['id'] as String))
                r.cast<String, Object?>(),
          ];
    if (stale()) return const {};
    if (!_idFormat.hasMatch(parent.id)) return {'error': '消息 id 不对'};
    final refused = _show('讨论 · ${replies.length} 条回复', [
      _card('message', parent.id, high: true, display: _spec(a['display'])),
      if (replies.isNotEmpty)
        _section('回复 · ${replies.length}', [
          for (final r in replies) _card('message', r['id']! as String),
        ])
      else
        {'component': AgentEntityComponents.callout, 'text': '这条消息下面还没有回复'},
    ], _spec(a['childDisplay']));
    if (refused != null) return refused;
    return {
      'ok': true,
      'replies': replies.length,
      'screen': '原消息和全部回复已在屏幕上',
      'say': '只说一句话（几条回复，最后是谁说的）；不要念内容',
    };
  }

  // ---- show_agent_activity --------------------------------------------

  Future<Map<String, Object?>> _activity(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    final result = await _read('agents.activity_log', {
      'agent': a['agent'],
      'limit': ((a['limit'] as int?) ?? 12).clamp(1, 12),
    });
    if (stale()) return const {};
    final agentId = result['agentId'];
    final entries = [
      for (final e in (result['entries'] as List? ?? const []))
        if (e is Map) e.cast<String, Object?>(),
    ];
    final items = [
      for (final e in entries)
        {
          'time': _clipText('${e['time'] ?? ''}', 20),
          'title': _clipText(
            [
              if (e['tool'] != null) '${e['tool']}',
              if (e['activity'] != null) '${e['activity']}',
              if (e['detail'] != null) '${e['detail']}',
            ].join(' · '),
            80,
          ),
        },
    ].where((i) => i['title']!.isNotEmpty).toList();
    final shown = items.length > 12 ? items.sublist(items.length - 12) : items;
    final refused = _show('${result['agent'] ?? a['agent']} 最近在做什么', [
      if (agentId is String && _idFormat.hasMatch(agentId))
        _card('agent', agentId, high: true, display: _spec(a['display'])),
      if (shown.isEmpty)
        {'component': AgentEntityComponents.callout, 'text': '最近没有活动记录'}
      else
        {'component': AgentEntityComponents.timeline, 'items': shown},
    ]);
    if (refused != null) return refused;
    return {
      'ok': true,
      'agent': result['agent'],
      'entries': shown.length,
      'last': shown.isEmpty ? null : shown.last['title'],
      'screen': 'Agent 卡片和活动时间线已在屏幕上',
      'say': '只说一句话（它现在在做什么）；不要念时间线',
    };
  }

  // ---- show_task_history ----------------------------------------------

  Future<Map<String, Object?>> _history(
    Map<String, Object?> a,
    bool Function() stale,
  ) async {
    final raw = '${a['task']}'.trim();
    final number = int.tryParse(raw.replaceAll(RegExp(r'^#'), ''));
    final result = await _read('tasks.history', {
      if (number != null) 'number': number else 'taskId': raw,
      'channel': a['channel'],
      'limit': ((a['limit'] as int?) ?? 12).clamp(1, 12),
    });
    if (stale()) return const {};
    final taskId = result['taskId'];
    final events = [
      for (final e in (result['events'] as List? ?? const []))
        if (e is Map) e.cast<String, Object?>(),
    ];
    final items = [
      for (final e in events)
        {
          'time': _clipText('${e['time'] ?? ''}', 20),
          'title': _clipText(_eventWords(e), 80),
        },
    ];
    final refused = _show('任务历史', [
      if (taskId is String && _idFormat.hasMatch(taskId))
        _card('task', taskId, high: true, display: _spec(a['display'])),
      if (items.isEmpty)
        {'component': AgentEntityComponents.callout, 'text': '这个任务还没有变更记录'}
      else
        {'component': AgentEntityComponents.timeline, 'items': items},
    ]);
    if (refused != null) return refused;
    return {
      'ok': true,
      'events': items.length,
      'last': items.isEmpty ? null : items.last['title'],
      'screen': '任务卡和变更时间线已在屏幕上',
      'say': '只说一句话（最近一次变更是谁、改了什么）；不要念时间线',
    };
  }

  static String _eventWords(Map<String, Object?> e) {
    final by = e['by'] == null ? '' : '${e['by']} ';
    final type = '${e['type'] ?? ''}'.replaceAll('_', ' ');
    final from = e['from'], to = e['to'], status = e['status'];
    final changes = e['changes'];
    return [
      '$by$type'.trim(),
      if (from != null && to != null)
        '$from → $to'
      else if (status != null)
        '$status'
      else if (to != null)
        '$to'
      else if (changes is List && changes.isNotEmpty)
        changes.join('、'),
    ].join('：');
  }

  static String _clipText(String s, int max) {
    final one = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return one.length <= max ? one : '${one.substring(0, max - 1)}…';
  }
}
