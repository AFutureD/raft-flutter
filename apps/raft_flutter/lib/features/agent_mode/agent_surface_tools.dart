import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_catalog.dart';
import 'agent_mode_data.dart';
import 'agent_surface.dart';

/// What the model has read this session. A generated screen may only show
/// facts that appear here: that is how "the model never invents" is enforced
/// rather than asked for.
class AgentFacts {
  final _agents = <String, AgentRuntimeInfo>{};
  final _tasks =
      <int, List<({String status, String? claimer, String? channel})>>{};
  final _said = <({String who, String text})>[];

  bool get hasAgents => _agents.isNotEmpty;

  void learnAgents(Iterable<AgentRuntimeInfo> agents) {
    _agents
      ..clear()
      ..addEntries([for (final a in agents) MapEntry(a.name.toLowerCase(), a)]);
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
        case AgentComponents.statusCard:
          final name = n.string('name') ?? '';
          final known = _agents[name.toLowerCase()];
          if (!hasAgents) {
            problems.add('还没有读过 Agent 状态：先调用 list_agents 再显示 AgentStatusCard');
          } else if (known == null) {
            problems.add('AgentStatusCard "$name" 不在 list_agents 的结果里');
          } else if (known.state.name != n.string('state')) {
            problems.add(
              'AgentStatusCard "$name" 的 state 是 ${known.state.name}，不是 ${n.string('state')}',
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

/// Shows a validated surface as a new layer; returns what the screen is now.
typedef ShowSurface = Map<String, Object?> Function(AgentSurfaceSpec spec);

/// The read tools and the `show_surface` UI tool of the generative screens.
/// Reads go through [AgentModeData] (the same endpoints the rest of agent
/// mode uses); every fact they return is remembered in [facts] and checked
/// again when a surface claims it.
class AgentGroundedTools {
  AgentGroundedTools({
    required this.data,
    required this.show,
    AgentCatalog? catalog,
    this.onRejected,
  }) : catalog = catalog ?? agentStandardCatalog;

  final AgentModeData data;
  final AgentCatalog catalog;
  final ShowSurface show;
  final AgentFacts facts = AgentFacts();

  /// A surface was refused (for the small error caption on screen).
  final void Function(List<String> problems)? onRejected;

  static const names = {
    'list_agents',
    'get_task',
    'search_tasks',
    'show_surface',
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

  /// Runs [name] when it is one of [names]; null for any other tool.
  Future<Map<String, Object?>?> run(
    String name,
    Map<String, Object?> args,
  ) async {
    switch (name) {
      case 'list_agents':
        final agents = await data.agents();
        facts.learnAgents(agents);
        int count(AgentWorkState s) => agents.where((a) => a.state == s).length;
        return {
          'total': agents.length,
          'counts': {for (final s in AgentWorkState.values) s.name: count(s)},
          'agents': [for (final a in agents.take(40)) a.toJson()],
        };
      case 'get_task':
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
        final parsed = catalog.parse(args['surface']);
        final problems = parsed.ok
            ? facts.check(parsed.spec!.root)
            : parsed.problems;
        if (problems.isNotEmpty) {
          onRejected?.call(problems);
          return {
            'error': '这块界面没有显示。按 problems 改正后再调用一次 show_surface。',
            'problems': problems.take(8).toList(),
          };
        }
        return {'ok': true, ...show(parsed.spec!)};
    }
    return null;
  }
}
