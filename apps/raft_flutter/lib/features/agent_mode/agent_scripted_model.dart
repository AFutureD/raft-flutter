import 'dart:convert';

import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_catalog.dart';
import 'agent_detail.dart';
import 'agent_mode_data.dart' show agentOrdinal;
import 'gemini_live.dart' show AgentToolHandler;

/// A stand-in for the voice model that needs no network: it recognises the
/// two demo questions and answers them the way the real model is told to,
/// by calling the same tools in the same order (read, then `show_surface`
/// built only from what the read returned, then one spoken sentence).
///
/// Used by the offline demo and by tests; the page treats it as the model.
class AgentScriptedModel {
  const AgentScriptedModel();

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

  Future<void> _show(
    AgentToolHandler call,
    Map<String, Object?> surface,
    void Function(String) say,
  ) async {
    final result = await call('show_surface', {'surface': jsonEncode(surface)});
    if (result['error'] != null) {
      say(
        '这块界面没能显示：${(result['problems'] as List?)?.join('；') ?? result['error']}',
      );
    }
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
    final groups = <Object?>[];
    for (final state in const ['busy', 'blocked', 'idle', 'offline']) {
      final of = [
        for (final a in agents)
          if (a['state'] == state) a,
      ];
      if (of.isEmpty) continue;
      groups.add({
        'component': AgentComponents.statusGroup,
        'title': titles[state],
        'state': state,
        if (expand != null && titles[state]!.contains(expand))
          'density': 'detail',
        'children': [
          for (final a in of)
            {
              'component': AgentComponents.statusCard,
              'name': a['name'],
              'state': a['state'],
              'activity': a['activity'],
              'since': ?a['since'],
              'channel': ?a['channel'],
            },
        ],
      });
    }
    final counts =
        (read['counts'] as Map?)?.cast<String, Object?>() ?? const {};
    final parts = [
      for (final s in const ['busy', 'blocked', 'idle', 'offline'])
        if (counts[s] is int && (counts[s] as int) > 0)
          '${counts[s]} 个${titles[s]}',
    ];
    final summary = '${agents.length} 个 Agent：${parts.join('，')}。';
    await _show(call, {
      'title': '现在所有 Agent 在做什么',
      'summary': summary,
      'root': {
        'component': AgentComponents.column,
        'children': [
          // Numbers first, then one row per group; a phone folds the groups.
          {
            'component': AgentComponents.statRow,
            'stats': [
              for (final s in const ['busy', 'blocked', 'idle', 'offline'])
                if (counts[s] is int && (counts[s] as int) > 0)
                  {'label': titles[s], 'value': '${counts[s]}'},
            ],
          },
          ...groups,
        ],
      },
    }, say);
    if (expand != null) {
      say('$expand那组展开了。');
      return;
    }
    final blocked = agents
        .where((a) => a['state'] == 'blocked')
        .map((a) => a['name']);
    say(
      '$summary${blocked.isEmpty ? '' : '${blocked.join('、')} 卡住了。'}'
      '要不要展开？',
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
    await _show(call, {
      'title': '任务 #$number',
      'root': {
        'component': AgentComponents.column,
        'children': [
          {
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
          if (thread.length > 1)
            {
              'component': AgentComponents.section,
              'title': '最近讨论',
              'children': [
                for (final l in thread.sublist(
                  thread.length > 4 ? thread.length - 4 : 0,
                  thread.length - 1,
                ))
                  {
                    'component': AgentComponents.messageQuote,
                    'author': l['who'],
                    'time': l['time'],
                    'text': l['text'],
                  },
              ],
            },
        ],
      },
    }, say);
    final label = agentTaskStatusLabels[status] ?? status;
    say(
      '任务 #$number 现在$label'
      '${claimer == null ? '' : '，由 $claimer 负责'}。'
      '${last == null ? '' : '最后一条是 ${last['who']} 说的。'}',
    );
  }
}
