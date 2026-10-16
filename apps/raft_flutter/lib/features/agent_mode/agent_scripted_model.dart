import 'dart:convert';

import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_catalog.dart';
import 'agent_detail.dart';
import 'agent_mode_data.dart' show agentOrdinal;
import 'gemini_live.dart' show AgentToolHandler;

/// A stand-in for the voice model that needs no network: it recognises the
/// two demo questions and answers them the way the real model is told to,
/// by calling the same tools in the same order: read, `begin_surface` with the
/// skeleton, one sentence spoken at once, then `add_component` for each item
/// (built only from what the read returned) a moment apart, `end_surface`.
///
/// Used by the offline demo and by tests; the page treats it as the model.
class AgentScriptedModel {
  const AgentScriptedModel({
    this.streamDelay = const Duration(milliseconds: 240),
  });

  /// The pause between two pieces of a screen it composes, so the offline
  /// demo visibly streams like the voice model does (zero in tests that do
  /// not look at the stream).
  final Duration streamDelay;

  Future<void> _pause() async {
    if (streamDelay > Duration.zero) await Future<void>.delayed(streamDelay);
  }

  /// Handles [text] and returns true, or returns false when it is not one of
  /// the scripted questions (the page then falls back to its local intents).
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String line) say,
  ) async {
    if (RegExp(r'下一批|还有吗|再看看别的').hasMatch(text)) {
      final r = await call('next_batch', const {});
      say(r['error'] != null ? '${r['error']}' : '现在是${r['showing']}。');
      return true;
    }
    // "讲讲第一条" / "展开第 2 条" / "详细说说这个": the home card in full.
    final wantsMore = RegExp(r'讲讲|展开|详细|详情|细说|说说').hasMatch(text);
    final group = RegExp(r'在忙|卡住|空闲|离线').firstMatch(text)?[0];
    if (wantsMore && group != null && agentOrdinal(text) == null) {
      await _agents(call, say, expand: group);
      return true;
    }
    if (wantsMore &&
        (agentOrdinal(text) != null || RegExp(r'这个|这条|这件').hasMatch(text))) {
      final n = agentOrdinal(text);
      final r = await call('expand_item', {'index': ?n});
      final item = (r['item'] as Map?)?.cast<String, Object?>();
      say(item == null ? '${r['error'] ?? '展开不了'}' : explainAttention(item));
      return true;
    }
    // "把 #98 标记为已完成": the preview of the demo capability, the person
    // confirms it on its card (the demo registers `demo.finish`).
    final finish = RegExp(r'把\s*#?\s*(\d+).*(?:完成|通过)').firstMatch(text);
    if (finish != null) {
      final r = await call('act', {
        'capability': 'demo.finish',
        'args': jsonEncode({'number': int.parse(finish[1]!)}),
      });
      say(
        r['error'] != null
            ? '${r['error']}'
            : '要把 #${finish[1]} 标记为已完成吗？点确认，或者说“对”。',
      );
      return true;
    }
    final task = RegExp(
      r'(?:任务|task)\s*#?\s*(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (task != null) {
      await _task(int.parse(task[1]!), call, say);
      return true;
    }
    if (RegExp(r'agent', caseSensitive: false).hasMatch(text) &&
        RegExp(r'干什么|做什么|在忙|状态|都在|情况').hasMatch(text)) {
      await _agents(call, say);
      return true;
    }
    return false;
  }

  /// Streams a screen: the skeleton at once, [speak] while the pieces
  /// follow, each in [parts] under its parent.
  Future<void> _stream(
    AgentToolHandler call, {
    required String id,
    required String title,
    String? summary,
    required Map<String, Object?> layout,
    required List<({String parent, Map<String, Object?> component})> parts,
    required void Function(String) say,
    void Function()? speak,
  }) async {
    final begun = await call('begin_surface', {
      'surface_id': id,
      'title': title,
      'summary': ?summary,
      'layout': jsonEncode(layout),
    });
    if (begun['error'] != null) {
      say(
        '这块界面没能显示：${(begun['problems'] as List?)?.join('；') ?? begun['error']}',
      );
      return;
    }
    speak?.call();
    for (final part in parts) {
      await _pause();
      final added = await call('add_component', {
        'surface_id': id,
        'parent_id': part.parent,
        'component': jsonEncode(part.component),
      });
      if (added['error'] != null) {
        say(
          '这块界面没能显示：${(added['problems'] as List?)?.join('；') ?? added['error']}',
        );
      }
    }
    await call('end_surface', {'surface_id': id});
  }

  /// [expand] is the label word of a group ("在忙") to show in full.
  Future<void> _agents(
    AgentToolHandler call,
    void Function(String) say, {
    String? expand,
  }) async {
    final read = await call('list_agents', const {});
    final agents = [
      for (final a in (read['agents'] as List? ?? const []))
        (a as Map).cast<String, Object?>(),
    ];
    if (agents.isEmpty) {
      say('现在读不到 Agent 的状态。');
      return;
    }
    const titles = {
      'busy': '在忙',
      'blocked': '卡住了',
      'idle': '空闲',
      'offline': '离线',
    };
    final counts =
        (read['counts'] as Map?)?.cast<String, Object?>() ?? const {};
    final groups = <Object?>[];
    final parts = <({String parent, Map<String, Object?> component})>[];
    for (final state in const ['busy', 'blocked', 'idle', 'offline']) {
      final of = [
        for (final a in agents)
          if (a['state'] == state) a,
      ];
      if (of.isEmpty) continue;
      // The skeleton has the group and its title; its cards follow.
      groups.add({
        'component': AgentComponents.statusGroup,
        'id': 'g-$state',
        'title': titles[state],
        'state': state,
        if (expand != null && titles[state]!.contains(expand))
          'density': 'detail',
      });
      for (final a in of) {
        parts.add((
          parent: 'g-$state',
          component: {
            'component': AgentComponents.statusCard,
            'name': a['name'],
            'state': a['state'],
            'activity': a['activity'],
            'since': ?a['since'],
            'channel': ?a['channel'],
          },
        ));
      }
    }
    final summaryParts = [
      for (final s in const ['busy', 'blocked', 'idle', 'offline'])
        if (counts[s] is int && (counts[s] as int) > 0)
          '${counts[s]} 个${titles[s]}',
    ];
    final summary = '${agents.length} 个 Agent：${summaryParts.join('，')}。';
    final blocked = agents
        .where((a) => a['state'] == 'blocked')
        .map((a) => a['name']);
    await _stream(
      call,
      id: 'agents',
      title: '现在所有 Agent 在做什么',
      summary: summary,
      layout: {
        'component': AgentComponents.column,
        'id': 'root',
        'children': [
          // Numbers first, then the groups with their titles; a phone folds
          // the groups once they have cards.
          {
            'component': AgentComponents.statRow,
            'id': 'counts',
            'stats': [
              for (final s in const ['busy', 'blocked', 'idle', 'offline'])
                if (counts[s] is int && (counts[s] as int) > 0)
                  {'label': titles[s], 'value': '${counts[s]}'},
            ],
          },
          ...groups,
        ],
      },
      parts: parts,
      say: say,
      // Speaks while the cards arrive.
      speak: () => say(
        expand != null
            ? '$expand那组展开了。'
            : '$summary${blocked.isEmpty ? '' : '${blocked.join('、')} 卡住了。'}'
                  '要不要展开？',
      ),
    );
  }

  Future<void> _task(
    int number,
    AgentToolHandler call,
    void Function(String) say,
  ) async {
    final read = await call('get_task', {'number': number});
    final task = (read['task'] as Map?)?.cast<String, Object?>();
    if (task == null) {
      say('${read['error'] ?? '没找到任务 #$number'}');
      return;
    }
    final thread = [
      for (final l in (task['thread'] as List? ?? const []))
        (l as Map).cast<String, Object?>(),
    ];
    final last = thread.isEmpty ? null : thread.last;
    final status = '${task['status']}';
    final claimer = task['claimer'] as String?;
    final label = agentTaskStatusLabels[status] ?? status;
    await _stream(
      call,
      id: 'task-$number',
      title: '任务 #$number',
      layout: {'component': AgentComponents.column, 'id': 'root'},
      parts: [
        (
          parent: 'root',
          component: {
            'component': AgentComponents.taskCard,
            'title': task['title'],
            'status': status,
            'number': number,
            'assignee': ?claimer,
            'channel': ?task['channel'],
            if (last != null)
              'quote': {
                'who': last['who'],
                'time': last['time'],
                'text': last['text'],
              },
            if (status == 'in_review') 'ask': '验收这个任务',
          },
        ),
        if (thread.length > 1) ...[
          (
            parent: 'root',
            component: {
              'component': AgentComponents.section,
              'id': 'discussion',
              'title': '最近讨论',
            },
          ),
          for (final l in thread.sublist(
            thread.length > 4 ? thread.length - 4 : 0,
            thread.length - 1,
          ))
            (
              parent: 'discussion',
              component: {
                'component': AgentComponents.messageQuote,
                'author': l['who'],
                'time': l['time'],
                'text': l['text'],
              },
            ),
        ],
      ],
      say: say,
      speak: () => say(
        '任务 #$number 现在$label'
        '${claimer == null ? '' : '，由 $claimer 负责'}。'
        '${last == null ? '' : '最后一条是 ${last['who']} 说的。'}',
      ),
    );
  }
}
