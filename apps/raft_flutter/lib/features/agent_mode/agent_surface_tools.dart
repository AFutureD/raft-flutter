import 'dart:async';
import 'dart:convert';

import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_catalog.dart';
import 'agent_mode_data.dart';
import 'agent_surface.dart';
import 'agent_surface_stream.dart';

/// What the model has read this session. A generated screen may only show
/// facts that appear here: that is how "the model never invents" is enforced
/// rather than asked for.
class AgentFacts {
  /// What may be said about an agent: its reading now and, while a fresher
  /// read is on its way, the one before (a card made from either is true).
  final _agents = <String, List<AgentRuntimeInfo>>{};
  final _tasks =
      <int, List<({String status, String? claimer, String? channel})>>{};
  final _said = <({String who, String text})>[];

  bool get hasAgents => _agents.isNotEmpty;

  void learnAgents(
    Iterable<AgentRuntimeInfo> agents, {
    bool keepPrevious = false,
  }) {
    final before = {for (final e in _agents.entries) e.key: e.value.last};
    _agents.clear();
    for (final a in agents) {
      final key = a.name.toLowerCase();
      _agents[key] = [if (keepPrevious && before[key] != null) before[key]!, a];
    }
  }

  void learnTaskRows(Iterable<Map<String, dynamic>> rows) {
    for (final t in rows) {
      final n = t['taskNumber'];
      if (n is! int) continue;
      _note(
        n,
        '${t['status'] ?? ''}',
        _s(t['claimedByName'] ?? t['owner']),
        _s(t['channelName'] ?? t['channel']),
      );
      _hear(_s(t['claimedByName'] ?? t['owner']) ?? '', '${t['title'] ?? ''}');
    }
  }

  void learnTask(AgentTaskDetail t) {
    _note(t.number, t.status, t.claimer, t.channelName);
    for (final l in t.thread) {
      _hear(l.who, l.text);
    }
    _hear(t.claimer ?? t.creator ?? '', t.description);
  }

  /// Messages read from a channel.
  void learnMessage(String who, String text) => _hear(who, text);

  void _note(int n, String status, String? claimer, String? channel) =>
      (_tasks[n] ??= []).add((
        status: status,
        claimer: claimer,
        channel: channel,
      ));

  void _hear(String who, String text) {
    if (text.trim().isNotEmpty) _said.add((who: who, text: _norm(text)));
  }

  static String? _s(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  static String _norm(String s) =>
      AgentHeadlines.plain(s, max: 100000).toLowerCase();

  static String _quoted(String s) =>
      _norm(s).replaceFirst(RegExp(r'(…|\.\.\.)$'), '').trim();

  /// Why [node] shows something the model did not read; empty when it is
  /// grounded.
  List<String> check(SurfaceNode root) {
    final problems = <String>[];
    for (final n in root.walk()) {
      switch (n.component) {
        case AgentComponents.actionRow:
          problems.add(
            'ActionRow（通过 / 打开讨论 / 稍后）只出现在展开的详情里，不能自己放；要展开某一条请调用 expand_item',
          );
        case AgentComponents.statusCard:
          final name = n.string('name') ?? '';
          final known = _agents[name.toLowerCase()];
          if (!hasAgents) {
            problems.add('还没有读过 Agent 状态：先调用 list_agents 再显示 AgentStatusCard');
          } else if (known == null) {
            problems.add('AgentStatusCard "$name" 不在 list_agents 的结果里');
          } else if (!known.any((a) => a.state.name == n.string('state'))) {
            problems.add(
              'AgentStatusCard "$name" 的 state 是 ${known.last.state.name}，不是 ${n.string('state')}',
            );
          }
        case AgentComponents.statusGroup:
          final want = n.string('state');
          for (final c in n.children) {
            if (want != null && c.string('state') != want) {
              problems.add(
                'AgentStatusGroup "${n.string('title')}" 是 $want，里面的 "${c.string('name')}" 是 ${c.string('state')}',
              );
            }
          }
        case AgentComponents.taskCard:
          final number = n.integer('number');
          final facts = number == null ? null : _tasks[number];
          if (number == null) {
            problems.add('TaskCard 需要 number（取自 get_task / search_tasks）');
          } else if (facts == null) {
            problems.add('任务 #$number 还没读过：先调用 get_task');
          } else {
            final status = n.string('status');
            if (!facts.any((f) => f.status == status)) {
              problems.add(
                '任务 #$number 的 status 是 ${facts.map((f) => f.status).toSet().join('/')}，不是 $status',
              );
            }
            final who = n.string('assignee');
            if (who != null && !facts.any((f) => f.claimer == who)) {
              problems.add('任务 #$number 的负责人不是 "$who"');
            }
          }
          final quote = n.object('quote');
          if (quote != null) {
            problems.addAll(
              _checkQuote(
                '${quote['who'] ?? ''}',
                '${quote['text'] ?? ''}',
                'TaskCard.quote',
              ),
            );
          }
        case AgentComponents.messageQuote:
          problems.addAll(
            _checkQuote(
              n.string('author') ?? '',
              n.string('text') ?? '',
              'MessageQuote',
            ),
          );
      }
    }
    return problems;
  }

  /// What [child] must also satisfy because of the group it is put in.
  List<String> checkChild(SurfaceNode? parent, SurfaceNode child) {
    if (parent == null ||
        parent.component != AgentComponents.statusGroup ||
        child.component != AgentComponents.statusCard) {
      return const [];
    }
    final want = parent.string('state');
    if (want == null || child.string('state') == want) return const [];
    return [
      'AgentStatusGroup "${parent.string('title')}" 是 $want，里面的 "${child.string('name')}" 是 ${child.string('state')}',
    ];
  }

  List<String> _checkQuote(String who, String text, String where) {
    final want = _quoted(text);
    if (want.isEmpty) return const [];
    final hit = _said.any(
      (m) =>
          m.text.contains(want) &&
          (who.isEmpty || m.who.isEmpty || m.who == who),
    );
    return hit
        ? const []
        : [
            '$where 的“${text.length > 24 ? '${text.substring(0, 24)}…' : text}”不是读到的原话（作者 ${who.isEmpty ? '未写' : who}）',
          ];
  }
}

/// What the screen offers the surface tools: a new layer, a changed one.
class AgentSurfaceHost {
  const AgentSurfaceHost({
    required this.begin,
    required this.changed,
    required this.isOpen,
    this.ended,
  });

  /// The draft becomes the front layer (replacing the same screen asked
  /// again); returns what the screen is now.
  final Map<String, Object?> Function(AgentSurfaceDraft draft) begin;

  /// The draft changed; [added] is the id of the component just appended.
  /// Returns extra fields for the tool result (the item's number).
  final Map<String, Object?> Function(AgentSurfaceDraft draft, {String? added})
  changed;

  /// The draft's layer is still on the stack.
  final bool Function(AgentSurfaceDraft draft) isOpen;

  /// The model finished the surface.
  final void Function(AgentSurfaceDraft draft)? ended;
}

/// The read tools and the surface tools of the generative screens.
///
/// A screen is composed in pieces (`begin_surface`, `add_component`,
/// `update_component`, `end_surface`); `show_surface` sends a whole tree in
/// one call. Reads go through [AgentModeData] (the same endpoints the rest of
/// agent mode uses); every fact they return is remembered in [facts] and
/// checked again for each component that claims it, so a component that shows
/// something not read is refused alone and the others stay.
class AgentGroundedTools {
  AgentGroundedTools({
    required this.data,
    required this.host,
    AgentCatalog? catalog,
    this.onRejected,
  }) : catalog = catalog ?? agentStandardCatalog;

  final AgentModeData data;
  final AgentCatalog catalog;
  final AgentSurfaceHost host;
  final AgentFacts facts = AgentFacts();

  /// A surface or component was refused (for the small caption on screen).
  final void Function(List<String> problems)? onRejected;

  /// The surfaces being composed, by id.
  final drafts = <String, AgentSurfaceDraft>{};

  /// The last `list_agents` refresh (null when the answer was already fresh),
  /// for callers that want to wait for the patches.
  Future<void>? agentsRefresh;

  /// Components the app patched from a fresher agent read, most recent first
  /// (`surface/component`).
  final patched = <String>[];

  String? _lastRead;
  List<AgentRuntimeInfo>? _fresh;

  /// The reading `list_agents` answered from the cache, by name: what the
  /// cards the model made from it say, until the fresh read corrects them.
  Map<String, AgentRuntimeInfo>? _cachedBase;
  int _surfaces = 0;

  static const names = {
    'list_agents',
    'get_task',
    'search_tasks',
    'show_surface',
    ...uiNames,
  };

  /// The surface tools that only change the screen: answered at once, and
  /// declared non-blocking to a model that speaks while it composes.
  static const uiNames = {
    'begin_surface',
    'add_component',
    'update_component',
    'end_surface',
  };

  /// The compact form of a task row the model reads.
  static Map<String, Object?> taskRow(Map<String, dynamic> t) => {
    'number': t['taskNumber'],
    'title': AgentHeadlines.plain('${t['title'] ?? ''}', max: 120),
    'status': t['status'],
    'owner': t['claimedByName'],
    'channel': t['channelName'],
  };

  static int? _number(Object? v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.replaceAll(RegExp(r'[^\d]'), ''));
    return null;
  }

  /// A JSON text (or an already decoded value) as a value.
  static Object? _json(Object? raw) {
    if (raw is! String) return raw;
    final fenced = RegExp(r'^```(?:json)?\s*([\s\S]*?)\s*```$')
        .firstMatch(raw.trim());
    try {
      return jsonDecode(fenced == null ? raw.trim() : fenced[1]!);
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> _agentsResult(List<AgentRuntimeInfo> agents) {
    int count(AgentWorkState s) => agents.where((a) => a.state == s).length;
    return {
      'total': agents.length,
      'counts': {for (final s in AgentWorkState.values) s.name: count(s)},
      'agents': [for (final a in agents.take(40)) a.toJson()],
    };
  }

  /// Runs [name] when it is one of [names]; null for any other tool. The
  /// surface tools change the screen before their first await.
  Future<Map<String, Object?>?> run(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case 'list_agents':
        _lastRead = 'list_agents';
        _fresh = null;
        _cachedBase = null;
        final cached = data.cachedAgents();
        if (cached != null && cached.isNotEmpty) {
          // Answer from what the app already has; the fresh read follows and
          // corrects only the agents that changed, on the surfaces that
          // came from this read.
          facts.learnAgents(cached);
          _cachedBase = {for (final a in cached) a.name.toLowerCase(): a};
          agentsRefresh = _refreshAgents();
          return {..._agentsResult(cached), 'source': 'cache'};
        }
        agentsRefresh = null;
        final agents = await data.agents();
        facts.learnAgents(agents);
        _fresh = agents;
        return _agentsResult(agents);
      case 'get_task':
        _lastRead = name;
        final number = _number(args['number']);
        if (number == null) return {'error': '需要任务编号 number'};
        final found = await data.tasksNumbered(
          number,
          channel: args['channel'] as String?,
        );
        if (found.isEmpty) return {'error': '没有找到任务 #$number'};
        if (found.length > 1) {
          return {
            'error': '多个频道都有任务 #$number，请带上 channel 再问',
            'channels': [for (final t in found) t.channelName],
          };
        }
        facts.learnTask(found.single);
        return {'task': found.single.toJson()};
      case 'search_tasks':
        _lastRead = name;
        final rows = await data.searchTasks(
          '${args['query'] ?? ''}',
          status: args['status'] as String?,
        );
        facts.learnTaskRows(rows);
        return {
          'count': rows.length,
          'tasks': [for (final t in rows.take(12)) taskRow(t)],
        };
      case 'show_surface':
        return _showSurface(args);
      case 'begin_surface':
        return _begin(args);
      case 'add_component':
        return _add(args);
      case 'update_component':
        return _update(args);
      case 'end_surface':
        return _end(args);
    }
    return null;
  }

  Map<String, Object?> _refused(
    String what,
    List<String> problems, {
    bool keep = false,
  }) {
    onRejected?.call(problems);
    return {
      'error': keep ? what : '$what按 problems 改正后再调用一次。',
      'problems': problems.take(8).toList(),
    };
  }

  /// A whole tree in one call: checked whole (one bad component refuses the
  /// screen), then shown as a surface that is already complete.
  Map<String, Object?> _showSurface(Map<String, Object?> args) {
    final parsed = catalog.parse(args['surface']);
    final problems = parsed.ok
        ? facts.check(parsed.spec!.root)
        : parsed.problems;
    if (problems.isNotEmpty) {
      return _refused('这块界面没有显示。', problems);
    }
    final spec = parsed.spec!;
    final draft = AgentSurfaceDraft(
      id: 's${++_surfaces}',
      title: spec.title,
      summary: spec.summary,
      root: spec.root,
      source: _lastRead,
    );
    final root = draft.named(spec.root);
    final whole = AgentSurfaceDraft(
      id: draft.id,
      title: spec.title,
      summary: spec.summary,
      root: root,
      source: _lastRead,
    )..ended = true;
    drafts[whole.id] = whole;
    return {'ok': true, ...host.begin(whole)};
  }

  Map<String, Object?> _begin(Map<String, Object?> args) {
    final title = args['title'];
    final summary = args['summary'];
    final problems = <String>[];
    if (title is! String || title.trim().isEmpty) {
      problems.add('title 必须是非空字符串');
    } else if (title.length > 60) {
      problems.add('title 太长（最多 60 个字）');
    }
    if (summary != null && (summary is! String || summary.length > 200)) {
      problems.add('summary 必须是不超过 200 字的字符串');
    }
    final id = args['surface_id'] ?? args['id'] ?? 's${_surfaces + 1}';
    if (id is! String || !RegExp(r'^[A-Za-z0-9_\-]{1,40}$').hasMatch(id)) {
      problems.add('id 必须是 1 到 40 位的字母、数字、下划线或短横线');
    }
    if (problems.isNotEmpty) return _refused('这一屏没有开始。', problems);
    _surfaces++;

    final dropped = <String>[];
    final layout = args['layout'] == null
        ? <String, Object?>{'component': AgentComponents.column}
        : _json(args['layout']);
    final shell = AgentSurfaceDraft(
      id: id as String,
      title: (title as String).trim(),
      summary: summary is String && summary.trim().isNotEmpty
          ? summary.trim()
          : null,
      root: const SurfaceNode(AgentComponents.column, {}),
      source: _lastRead,
    );
    final root = catalog.salvage(
      layout,
      problems: dropped,
      budget: SurfaceBudget(AgentSurfaceDraft.maxNodes),
      path: 'layout',
      ground: (node, parent) => [
        ...facts.check(node),
        ...facts.checkChild(parent, node),
      ],
    );
    if (root == null) {
      return _refused('这一屏没有开始：layout 的根组件不合格。', dropped);
    }
    final duplicates = shell.clashes(root);
    if (duplicates.isNotEmpty) {
      return _refused('这一屏没有开始：组件 id 重复：${duplicates.join('、')}。', dropped);
    }
    final named = shell.named(
      root.id == null ? root.copyWith(id: 'root') : root,
    );
    final draft = AgentSurfaceDraft(
      id: shell.id,
      title: shell.title,
      summary: shell.summary,
      root: named,
      source: _lastRead,
    );
    drafts[draft.id] = draft;
    if (dropped.isNotEmpty) onRejected?.call(dropped);
    host.begin(draft);
    return {
      'ok': true,
      'surface_id': draft.id,
      'root': draft.root.id,
      // The ids to add components under.
      'containers': [
        for (final n in draft.root.walk())
          if (catalog.item(n.component)?.container ?? false)
            {'id': n.id, 'component': n.component, 'title': ?n.string('title')},
      ],
      if (dropped.isNotEmpty) 'rejected': dropped.take(6).toList(),
    };
  }

  AgentSurfaceDraft? _draftOf(Map<String, Object?> args, List<String> out) {
    final id = args['surface_id'] ?? args['id'];
    final draft = id is String
        ? drafts[id]
        : drafts.values.where(host.isOpen).lastOrNull;
    if (draft == null) {
      out.add('没有这一屏：先调用 begin_surface');
      return null;
    }
    if (!host.isOpen(draft)) {
      out.add('这一屏已经关闭（用户返回或换了别的屏），不要再往里加');
      return null;
    }
    return draft;
  }

  Map<String, Object?> _add(Map<String, Object?> args) {
    final out = <String>[];
    final draft = _draftOf(args, out);
    if (draft == null) {
      return {'error': out.first};
    }
    final parentId = args['parent_id'] ?? draft.root.id;
    final parent = parentId is String ? draft.find(parentId) : null;
    final parentItem = parent == null ? null : catalog.item(parent.component);
    if (parent == null) {
      return _refused('这个组件没有加上。', ['parent_id "$parentId" 不在这一屏里']);
    }
    if (parentItem == null || !parentItem.container) {
      return _refused('这个组件没有加上。', [
        '${parent.component} "${parent.id}" 不能放子组件，换一个容器',
      ]);
    }
    final raw = _json(args['component']);
    final problems = <String>[];
    final node = catalog.salvage(
      raw,
      problems: problems,
      budget: draft.budget,
      path: 'component',
      depth: (draft.pathOf(parent.id!)?.split('.').length ?? 1) + 1,
      parent: parent,
      ground: (n, p) => [...facts.check(n), ...facts.checkChild(p, n)],
    );
    if (node != null) {
      final only = parentItem.childNames;
      if (only != null && !only.contains(node.component)) {
        problems.add(
          '${parent.component} "${parent.id}" 里只能放：${only.join('、')}，不能放 ${node.component}',
        );
      }
      final clashes = draft.clashes(node);
      if (clashes.isNotEmpty) {
        problems.add('组件 id 已存在：${clashes.join('、')}');
      }
    }
    if (node == null ||
        problems.any((p) => p.contains('里只能放') || p.contains('id 已存在'))) {
      return _refused(
        '这个组件没有显示，其余的不受影响。',
        problems.isEmpty ? ['component 不是合法的组件'] : problems,
        keep: true,
      );
    }
    final named = draft.named(node);
    draft.add(parent.id!, named);
    if (problems.isNotEmpty) onRejected?.call(problems);
    _reconcile(draft);
    final extra = host.changed(draft, added: named.id);
    return {
      'ok': true,
      'id': named.id,
      ...extra,
      if (problems.isNotEmpty) 'rejected': problems.take(6).toList(),
    };
  }

  Map<String, Object?> _update(Map<String, Object?> args) {
    final out = <String>[];
    final draft = _draftOf(args, out);
    if (draft == null) return {'error': out.first};
    final id = args['id'] ?? args['component_id'];
    final node = id is String ? draft.find(id) : null;
    if (node == null) {
      return _refused('没有改。', ['组件 "$id" 不在这一屏里']);
    }
    final raw = _json(args['props']);
    if (raw is! Map) {
      return _refused('没有改。', ['props 必须是 {字段: 新值} 的 JSON 对象']);
    }
    final props = raw.cast<String, Object?>();
    final item = catalog.item(node.component)!;
    final problems = <String>[];
    for (final key in props.keys) {
      if (!item.properties.containsKey(key)) {
        problems.add(
          '${node.component} 没有字段 "$key"（可用：${item.properties.keys.join('、')}；加子组件用 add_component）',
        );
      }
    }
    final merged = {...node.props};
    for (final e in props.entries) {
      if (e.value == null) {
        merged.remove(e.key);
      } else {
        merged[e.key] = e.value;
      }
    }
    if (problems.isEmpty) {
      problems.addAll(catalog.checkProps(item, merged, '<${node.component}>'));
    }
    if (problems.isEmpty) {
      final shallow = SurfaceNode(node.component, merged);
      problems
        ..addAll(facts.check(shallow))
        ..addAll(facts.checkChild(draft.parentOf(node.id!), shallow));
    }
    if (problems.isNotEmpty) return _refused('没有改。', problems);
    draft.patch(node.id!, props);
    host.changed(draft);
    return {'ok': true};
  }

  Map<String, Object?> _end(Map<String, Object?> args) {
    final out = <String>[];
    final draft = _draftOf(args, out);
    if (draft == null) return {'error': out.first};
    draft.ended = true;
    host.ended?.call(draft);
    return {'ok': true, 'components': draft.count};
  }

  // ---- list_agents: the cached answer, then only what changed ------------

  Future<void> _refreshAgents() async {
    final List<AgentRuntimeInfo> fresh;
    try {
      fresh = await data.agents();
    } on Object {
      return;
    }
    if (_lastRead != 'list_agents') return;
    facts.learnAgents(fresh, keepPrevious: true);
    _fresh = fresh;
    for (final draft in drafts.values) {
      if (host.isOpen(draft)) _reconcile(draft);
    }
  }

  static const _stateWords = {
    '在忙': AgentWorkState.busy,
    '卡住': AgentWorkState.blocked,
    '卡住了': AgentWorkState.blocked,
    '空闲': AgentWorkState.idle,
    '离线': AgentWorkState.offline,
  };

  /// Brings the agent cards of a surface made from the cached `list_agents`
  /// in line with the fresh read: only a card whose agent changed is
  /// touched, in place (`update_component`), and only in the fields that
  /// still say what the cache said (words the model chose are left alone); a
  /// card whose state changed moves to the group of its new state when there
  /// is one, and the numbers follow.
  void _reconcile(AgentSurfaceDraft draft) {
    final fresh = _fresh;
    final base = _cachedBase;
    if (fresh == null || base == null || draft.source != 'list_agents') return;
    final byName = {for (final a in fresh) a.name.toLowerCase(): a};
    var changed = false;
    var statesMoved = false;
    for (final node in draft.root.walk().toList()) {
      if (node.component != AgentComponents.statusCard) continue;
      final key = node.string('name')?.toLowerCase();
      final a = byName[key];
      final was = base[key];
      if (a == null || was == null) continue;
      final patch = <String, Object?>{};
      void follow(String field, String? shown, String? before, String? now) {
        if (before != now && shown == before) patch[field] = now;
      }

      follow('state', node.string('state'), was.state.name, a.state.name);
      follow('activity', node.string('activity'), was.activity, a.activity);
      follow('since', node.string('since'), was.since, a.since);
      follow('channel', node.string('channel'), was.channel, a.channel);
      // The fresh reading is what a later card is compared with.
      if (patch.isEmpty) continue;
      final parent = draft.parentOf(node.id!);
      final group = parent?.string('state');
      if (patch.containsKey('state') &&
          group != null &&
          group != a.state.name) {
        final target = draft.root
            .walk()
            .where(
              (n) =>
                  n.component == AgentComponents.statusGroup &&
                  n.string('state') == a.state.name,
            )
            .firstOrNull;
        if (target != null) {
          final moved = node.copyWith(
            props: {
              ...node.props,
              for (final e in patch.entries)
                if (e.value != null) e.key: e.value,
            },
          );
          draft.remove(node.id!);
          draft.add(target.id!, moved);
          patched.insert(0, '${draft.id}/${node.id}');
          changed = statesMoved = true;
          continue;
        }
      }
      draft.patch(node.id!, patch);
      patched.insert(0, '${draft.id}/${node.id}');
      changed = true;
      if (patch.containsKey('state')) statesMoved = true;
    }
    if (statesMoved) {
      // The numbers above the groups say how many are in each state.
      for (final node in draft.root.walk().toList()) {
        if (node.component != AgentComponents.statRow) continue;
        final stats = [
          for (final s in node.list('stats'))
            if (s is Map) s.cast<String, Object?>(),
        ];
        var any = false;
        final next = [
          for (final s in stats)
            if (_stateWords[s['label']] case final state?)
              () {
                final n = '${fresh.where((a) => a.state == state).length}';
                if (s['value'] != n) any = true;
                return {...s, 'value': n};
              }()
            else
              s,
        ];
        if (any) {
          draft.patch(node.id!, {'stats': next});
          changed = true;
        }
      }
    }
    if (changed) host.changed(draft);
  }
}
