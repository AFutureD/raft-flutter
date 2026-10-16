import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/features/agent_mode/agent_attention.dart';
import 'package:raft_flutter/features/agent_mode/agent_catalog.dart';
import 'package:raft_flutter/features/agent_mode/agent_consent_tray.dart';
import 'package:raft_flutter/features/agent_mode/agent_frame_view.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_page.dart';
import 'package:raft_flutter/features/agent_mode/agent_scripted_model.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability_standard.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart'
    show AgentToolHandler;
import 'package:raft_ui/raft_ui.dart';

import 'activity_incremental_refresh_test.dart' show ActivityClient;
import 'support/agent_capability_world.dart';

/// Screen parity: the voice model must know everything the person can read on
/// the screen. Each test renders one layer of agent mode, collects every
/// string drawn under it (the way a person reads it) and asserts that each of
/// them is in what the model is given for that screen: the result of the tool
/// that shows (or shows again) the layer, plus the per-turn context line.
///
/// What is left out of the collected strings, and why:
///  - icon glyphs (private-use code points): pictures, not words;
///  - the letter inside an avatar ([HfAvatar]): a picture of the name that is
///    printed next to it;
///  - the number on a row's colour bar: it is the item's own number, which
///    the model has as `n` and as its handle (the test asserts every item of
///    the layer has both);
///  - the chrome around a layer (close, settings, "第 N 层", the voice dock)
///    and the strips of the layers behind it: they are outside the layer.

/// Stands in for the model: runs [script] against the page's own tools.
class _Probe extends AgentScriptedModel {
  _Probe(this.script);
  Future<void> Function(AgentToolHandler call) script;

  @override
  Future<bool> handle(
    String text,
    AgentToolHandler call,
    void Function(String line) say,
  ) async {
    await script(call);
    return true;
  }
}

AgentProgressLine _line(String who, String time, String text) =>
    AgentProgressLine(who: who, time: time, text: text);

class _Data extends AgentModeData {
  _Data(super.w) : super(now: () => worldNow);

  @override
  Future<AgentAttention> attention() async => AgentAttention(
    items: [
      AgentAttentionItem(
        id: 't94',
        taskId: 't94',
        taskNumber: 94,
        priority: AgentPriority.decision,
        headline: 'Cindy 完成了「选型」，等你验收',
        ask: '验收',
        askLine: '验收「选型」',
        action: AgentAction.approve,
        canApprove: true,
        reason: '你派的任务',
        waitValue: 3,
        waitUnit: '小时',
        at: worldNow,
        waiters: const ['Cindy'],
        doer: 'Cindy',
        channelId: 'ch-general',
        channelName: 'general',
        threadTitle: '选型讨论',
        progress: [
          _line('Zed', '09:10', '请看一下返回键'),
          _line('Cindy', '10:32', '已完成并补了测试，等你验收'),
        ],
      ),
      AgentAttentionItem(
        id: 't7',
        taskId: 't7',
        taskNumber: 7,
        priority: AgentPriority.blocked,
        headline: 'Grok 的「返回」5 小时没动，卡住了',
        ask: '解除阻塞',
        reason: '卡住了',
        idle: true,
        waitValue: 5,
        at: worldNow,
        doer: 'Grok',
        channelId: 'ch-design',
        channelName: 'design',
        progress: [_line('Grok', '05:02', '卡在登录态上')],
      ),
      AgentAttentionItem(
        id: 'mention:ch-design2',
        priority: AgentPriority.mention,
        headline: 'Zed 在评审里问你：这个配色可以上线吗',
        ask: '回答',
        action: AgentAction.reply,
        reason: '点名找你',
        waitValue: 40,
        waitUnit: '分钟',
        at: worldNow,
        doer: 'Zed',
        channelId: 'ch-design2',
        channelName: 'design-review',
        progress: [_line('Zed', '11:20', '@Kevin 这个配色可以上线吗')],
      ),
    ],
    team: const [
      AgentTeamItem(
        id: 'tm1',
        headline: 'Bo 在迁移数据',
        channelName: 'general',
        who: 'Bo',
      ),
      AgentTeamItem(
        id: 'tm2',
        headline: 'Aria 在补测试',
        channelName: 'design',
        who: 'Aria',
      ),
    ],
  );

  @override
  Future<List<AgentRuntimeInfo>> agents() async => const [
    AgentRuntimeInfo(
      id: 'a1',
      name: 'Aria',
      state: AgentWorkState.busy,
      activity: '在做 #102「历史上拉」',
      since: '12 分钟前有进展',
      channel: 'seed',
    ),
    AgentRuntimeInfo(
      id: 'a2',
      name: 'Bo',
      state: AgentWorkState.blocked,
      activity: '#7「旧任务」 超过 6 小时没动',
    ),
  ];

  @override
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async => number != 98
      ? const []
      : [
          AgentTaskDetail(
            id: 't98',
            number: 98,
            title: '修复搜索打开频道后无法返回',
            status: 'in_review',
            description: '',
            updated: '2 小时前',
            claimer: 'Aria',
            channelName: 'seed',
            thread: [
              _line('Zed', '09:10', '请看一下返回键'),
              _line('Bo', '09:40', '我这边复现不了了'),
              _line('Aria', '10:32', '已修复并补了测试'),
            ],
          ),
        ];

  @override
  Future<AgentChannelBrief> channel(RaftChannel c, {int windowHours = 6}) async =>
      AgentChannelBrief(
        channel: c,
        windowHours: windowHours,
        tasks: [
          taskRow(
            't11',
            11,
            'in_review',
            title: '补全搜索结果的高亮',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
          taskRow(
            't12',
            12,
            'in_progress',
            title: '整理发布说明',
            claimedById: 'a-cindy',
            claimedByName: 'Cindy',
          ),
        ],
        messages: [
          {
            'id': 'm1',
            'seq': '1',
            'senderName': 'Ada',
            'content': '明天的发布我来盯着',
            'createdAt': hoursAgo(2),
          },
          {
            'id': 'm2',
            'seq': '2',
            'senderName': 'Cody',
            'content': '#11 已经提交，等验收',
            'createdAt': hoursAgo(1),
          },
        ],
      );

  @override
  Future<List<Map<String, dynamic>>> openTasks() async => [
    taskRow(
      't21',
      21,
      'in_review',
      title: '迁移旧数据',
      channel: 'design',
      claimedById: 'a-cody',
      claimedByName: 'Cody',
    ),
    taskRow(
      't22',
      22,
      'in_progress',
      title: '补一份回滚说明',
      channel: 'general',
      claimedById: 'a-cindy',
      claimedByName: 'Cindy',
    ),
  ];
}

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// Every string of a tool result, nested ones included.
String _flatten(Object? v) {
  final out = <String>[];
  void walk(Object? x) {
    if (x is String) {
      out.add(x);
    } else if (x is Map) {
      for (final e in x.entries) {
        out.add('${e.key}');
        walk(e.value);
      }
    } else if (x is Iterable) {
      x.forEach(walk);
    } else if (x != null) {
      out.add('$x');
    }
  }

  walk(v);
  return _norm(out.join('\n'));
}

bool _isIcon(String s) =>
    s.runes.isNotEmpty && s.runes.every((r) => r >= 0xE000 && r <= 0xF8FF);

/// The window's own chrome, which a wide window draws in the header of the
/// front layer: its title and the layer count.
bool _isChrome(String s) => s == 'Agent 模式' || RegExp(r'^第 \d+ 层$').hasMatch(s);

/// The strings drawn under [roots], as a person reads them.
List<String> _shown(WidgetTester t, List<Finder> roots) {
  final out = <String>{};
  for (final root in roots) {
    for (final element in find
        .descendant(of: root, matching: find.byType(RichText))
        .evaluate()) {
      // Pictures, not words: see the header of this file.
      var skip = false;
      element.visitAncestorElements((a) {
        final w = a.widget;
        if (w is HfAvatar ||
            w.key == const ValueKey('hf-row-bar') ||
            w.key == const ValueKey('hf-detail-index')) {
          skip = true;
          return false;
        }
        return true;
      });
      if (skip) continue;
      final text = _norm((element.widget as RichText).text.toPlainText());
      if (text.isEmpty || _isIcon(text) || _isChrome(text)) continue;
      out.add(text);
    }
  }
  return out.toList();
}

void _expectParity(List<String> shown, String seen, String what) {
  expect(shown, isNotEmpty, reason: '$what: nothing was drawn');
  final missing = [
    for (final s in shown)
      if (!seen.contains(s)) s,
  ];
  expect(
    missing,
    isEmpty,
    reason:
        '$what: drawn on the screen but not in what the model is given.\n'
        'model saw: $seen',
  );
}

void main() {
  late ActivityClient client;
  late CapabilityWorld w;

  final registry = AgentCapabilityRegistry([
    AgentCapability(
      id: 'tasks.finish',
      title: '把任务标成完成',
      kind: AgentCapabilityKind.action,
      risk: AgentCapabilityRisk.change,
      paramsSchema: const {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': '任务 id'},
        },
        'required': ['taskId'],
      },
      resultSummary: '任务',
      keywords: const ['完成'],
      preview: (w, args, env) async => AgentActionPreview(
        summary: '把任务 ${args['taskId']} 标记为已完成',
        changes: const ['状态: 等验收 → 已完成'],
      ),
      run: (w, args, env) async => {'status': 'done'},
    ),
    ...agentStandardCapabilities.all,
  ]);

  setUp(() {
    AgentModeData.clearSession();
    FlutterSecureStorage.setMockInitialValues({});
    final world = capabilityWorld();
    client = world.$1;
    w = world.$2;
    w.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_progress')
          taskRow(
            't3',
            9,
            'in_progress',
            title: '丙',
            claimedById: 'a-cody',
            claimedByName: 'Cody',
          ),
      ],
    };
  });
  tearDown(() async {
    w.dispose();
    await client.dispose();
  });

  Future<_Probe> open(WidgetTester t, {Size size = const Size(390, 844)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final probe = _Probe((call) async {});
    await t.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant, dark: false),
        home: AgentModePage(
          controller: w,
          data: _Data(w),
          model: probe,
          registry: registry,
        ),
      ),
    );
    await t.pumpAndSettle();
    return probe;
  }

  /// One typed request whose "model" runs [script]; what its calls returned is
  /// what the model was given.
  Future<void> say(
    WidgetTester t,
    _Probe probe,
    Future<void> Function(AgentToolHandler) script,
  ) async {
    probe.script = script;
    if (find.byKey(const ValueKey('agent-input')).evaluate().isEmpty) {
      await t.tap(find.byKey(const ValueKey('agent-keyboard')));
      await t.pumpAndSettle();
    }
    await t.enterText(find.byKey(const ValueKey('agent-input')), '随便');
    await t.testTextInput.receiveAction(TextInputAction.send);
    await t.pumpAndSettle();
  }

  /// What the model is given when it asks for the screen the way it does
  /// today: the answer of the tool that shows this layer again.
  Future<String> given(
    WidgetTester t,
    _Probe probe,
    String tool, [
    Map<String, Object?> args = const {},
  ]) async {
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      result = await call(tool, args);
    });
    return _flatten(result);
  }

  List<Finder> attentionRoots() => [
    find.byType(AgentAttentionView),
    find.byType(HfDetail),
  ];

  testWidgets('the home layer: channel, assignee, wait, every card', (t) async {
    final probe = await open(t);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'home layer');
    // Every item has its number and its handle.
    for (var n = 1; n <= 3; n++) {
      expect(seen, contains('①②③'.substring(n - 1, n)));
    }
  });

  testWidgets('the home layer with the current item open under its row', (
    t,
  ) async {
    final probe = await open(t);
    await t.tap(find.text('Cindy 完成了「选型」，等你验收'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'home layer + detail');
  });

  testWidgets('the home layer on a wide window: list beside the detail', (
    t,
  ) async {
    final probe = await open(t, size: const Size(1500, 900));
    expect(find.byKey(const ValueKey('attention-detail')), findsOneWidget);
    final seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'wide home layer');
  });

  testWidgets('the team row, closed and open', (t) async {
    final probe = await open(t);
    var seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'team row closed');
    await t.ensureVisible(find.byKey(const ValueKey('attention-team')));
    await t.tap(find.byKey(const ValueKey('attention-team')));
    await t.pumpAndSettle();
    seen = await given(t, probe, 'go_home');
    _expectParity(_shown(t, attentionRoots()), seen, 'team row open');
  });

  testWidgets('a channel layer: its tasks and messages', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('open_channel', {'name': 'general'});
    });
    final seen = await given(t, probe, 'open_channel', {'name': 'general'});
    _expectParity(
      _shown(t, [find.byType(AgentFrameView), find.byType(HfDetail)]),
      seen,
      'channel layer',
    );
  });

  testWidgets('a channel layer with a message made current', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('open_channel', {'name': 'general'});
    });
    await t.tap(find.text('明天的发布我来盯着'));
    await t.pumpAndSettle();
    final seen = await given(t, probe, 'open_channel', {'name': 'general'});
    _expectParity(
      _shown(t, [find.byType(AgentFrameView), find.byType(HfDetail)]),
      seen,
      'channel layer + message detail',
    );
  });

  testWidgets('the tasks layer', (t) async {
    final probe = await open(t);
    await say(t, probe, (call) async {
      await call('show_tasks', {});
    });
    await t.tap(find.text('迁移旧数据'));
    await t.pumpAndSettle();
    final seen = await given(t, probe, 'show_tasks');
    _expectParity(
      _shown(t, [find.byType(AgentFrameView), find.byType(HfDetail)]),
      seen,
      'tasks layer',
    );
  });

  testWidgets('the full detail of a home item', (t) async {
    final probe = await open(t);
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      result = await call('expand_item', {'index': 1});
    });
    expect(find.byType(AgentSurfaceView), findsOneWidget);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      _flatten(result),
      'detail layer of a task',
    );
    // The same for a mention, which has no task card.
    await say(t, probe, (call) async {
      await call('go_back', {});
      result = await call('expand_item', {'index': 3});
    });
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      _flatten(result),
      'detail layer of a mention',
    );
  });

  String surface(List<Object> children) => _json({
    'title': '全景',
    'summary': '一屏看全',
    'root': {
      'component': 'Column',
      'children': children,
    },
  });

  Future<String> showSurface(
    WidgetTester t,
    _Probe probe,
    List<Object> children,
  ) async {
    late Map<String, Object?> result;
    await say(t, probe, (call) async {
      await call('list_agents', {});
      await call('get_task', {'number': 98});
      result = await call('show_surface', {'surface': surface(children)});
    });
    expect(result['error'], isNull, reason: '${result['problems']}');
    // Entity cards are read from the workspace after they are drawn.
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    late Map<String, Object?> again;
    await say(t, probe, (call) async {
      again = await call('show_surface', {'surface': surface(children)});
    });
    return _flatten(again);
  }

  const status = {
    'component': 'AgentStatusCard',
    'name': 'Aria',
    'state': 'busy',
    'activity': '在做 #102「历史上拉」',
    'since': '12 分钟前有进展',
    'channel': 'seed',
  };
  const taskCard = {
    'component': 'TaskCard',
    'number': 98,
    'title': '修复搜索打开频道后无法返回',
    'status': 'in_review',
    'assignee': 'Aria',
    'channel': 'seed',
    'quote': {'who': 'Aria', 'time': '10:32', 'text': '已修复并补了测试'},
    'ask': '验收这个任务',
  };
  const quote = {
    'component': 'MessageQuote',
    'author': 'Bo',
    'time': '09:40',
    'text': '我这边复现不了了',
    'channel': 'seed',
  };

  testWidgets('a surface: status cards, task cards, quotes, stats', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'StatRow',
        'stats': [
          {'label': '在忙', 'value': '1'},
          {'label': '卡住', 'value': '1'},
        ],
      },
      {
        'component': 'AgentStatusGroup',
        'title': '在忙',
        'state': 'busy',
        'density': 'detail',
        'children': [status],
      },
      {
        'component': 'Section',
        'title': '任务和消息',
        'density': 'detail',
        'children': [
          taskCard,
          {
            ...taskCard,
            'display': {'level': 'detail'},
          },
          quote,
        ],
      },
    ]);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'surface');
  });

  testWidgets('a surface: folded groups on a phone', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'AgentStatusGroup',
        'title': '在忙',
        'state': 'busy',
        'children': [status],
      },
      {
        'component': 'Section',
        'title': '任务和消息',
        'children': [taskCard, quote],
      },
    ]);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'folded surface',
    );
  });

  testWidgets('a surface: entity cards of every kind the world holds', (
    t,
  ) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {'component': 'EntityCard', 'entity': 'channel', 'id': 'ch-general'},
      {
        'component': 'EntityCard',
        'entity': 'agent',
        'id': 'a-cody',
        'display': {'level': 'detail'},
      },
      {'component': 'EntityCard', 'entity': 'member', 'id': 'ada'},
      {'component': 'EntityCard', 'entity': 'computer', 'id': 'm1'},
      {
        'component': 'EntityCard',
        'entity': 'task',
        'id': 't3',
        'emphasis': 'high',
      },
      {'component': 'EntityCard', 'entity': 'task', 'id': 'nope'},
    ]);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'entity cards',
    );
  });

  testWidgets('a surface: table, timeline, code, callout', (t) async {
    final probe = await open(t);
    final seen = await showSurface(t, probe, [
      {
        'component': 'Table',
        'columns': ['任务', '负责人'],
        'rows': [
          [
            {'entity': 'task', 'id': 't3'},
            'Cody',
          ],
          ['#9 另一件事', 'Ada'],
        ],
      },
      {
        'component': 'Timeline',
        'items': [
          {'time': '09:10', 'title': '创建任务'},
          {
            'time': '10:32',
            'title': '进入验收',
            'entity': 'channel',
            'id': 'ch-general',
          },
        ],
      },
      {
        'component': 'CodeBlock',
        'format': 'diff',
        'title': 'lib/main.dart',
        'code': '-final a = 1;\n+final a = 2;',
      },
      {'component': 'Callout', 'tone': 'good', 'text': '全量检查通过，可以合。'},
    ]);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'blocks');
  });

  testWidgets('a surface: confirm card, choice and toggle, before and after '
      'the person used them', (t) async {
    final probe = await open(t);
    final blocks = <Object>[
      {
        'component': 'ConfirmCard',
        'title': '把 #98 标记为已完成？',
        'changes': ['状态: 等验收 → 已完成'],
      },
      {
        'component': 'Choice',
        'prompt': '合到哪里？',
        'options': ['integration', 'main'],
      },
      {'component': 'Toggle', 'label': '完成后通知我', 'value': false},
    ];
    var seen = await showSurface(t, probe, blocks);
    _expectParity(_shown(t, [find.byType(AgentSurfaceView)]), seen, 'blocks');
    await t.tap(find.text('main'));
    await t.pumpAndSettle();
    await t.tap(find.text('完成后通知我'));
    await t.pumpAndSettle();
    late Map<String, Object?> again;
    await say(t, probe, (call) async {
      again = await call('show_surface', {'surface': surface(blocks)});
    });
    seen = _flatten(again);
    _expectParity(
      _shown(t, [find.byType(AgentSurfaceView)]),
      seen,
      'blocks after use',
    );
  });

  testWidgets('a confirm card waiting for the person', (t) async {
    final probe = await open(t);
    late Map<String, Object?> previewed, home;
    // Same request: a new one would cancel the preview.
    await say(t, probe, (call) async {
      previewed = await call('act', {
        'capability': 'tasks.finish',
        'args': '{"taskId":"t3"}',
      });
      home = await call('go_home', {});
    });
    expect(previewed['status'], 'needs_confirmation');
    _expectParity(
      _shown(t, [...attentionRoots(), find.byType(AgentConsentTray)]),
      _flatten(home),
      'home layer + confirm card',
    );
  });
}

String _json(Object v) => jsonEncode(v);
