import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/gemini_agent.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_reply.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/orb_controller.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'support/agent_capability_world.dart' show hoursAgo, taskRow;
import 'support/orb_action_world.dart';

/// The app's own rules in the agent layer, end to end: the orb on the text
/// agent (a fake Gemini transport), the real action tools. The card is worded
/// by the app from the preview; a plain yes or no is run in code; a tap on the
/// card is said by the app; what the model gets wrong in a question is put
/// right inside the turn.

Map<String, Object?> _call(String name, Map<String, Object?> args) => {
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {
            'functionCall': {'name': name, 'args': args},
          },
        ],
      },
    },
  ],
};

Map<String, Object?> _say(String text) => {
  'candidates': [
    {
      'content': {
        'role': 'model',
        'parts': [
          {'text': text},
        ],
      },
    },
  ],
};

/// The model: replies in order; what it was asked is kept.
class FakeGemini {
  final replies = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];

  Future<({int status, String body})> call(
    Uri uri,
    String key,
    Map<String, Object?>? body,
  ) async {
    if (body == null) {
      return (
        status: 200,
        body: jsonEncode({
          'models': [
            {
              'name': 'models/gemini-3-flash-lite-preview',
              'supportedGenerationMethods': ['generateContent'],
            },
          ],
        }),
      );
    }
    requests.add(jsonDecode(jsonEncode(body)) as Map<String, Object?>);
    return (status: 200, body: jsonEncode(replies.removeAt(0)));
  }
}

void main() {
  late ActionOrbFixture f;
  late FakeGemini gemini;

  final navigated = <Map<String, Object?>>[];

  OrbTool navigateStub() => OrbTool(
    declaration: const {'name': 'navigate'},
    handler: (args, ctx) async {
      navigated.add(args);
      return {
        'route': '/s/s1/task/136',
        'title': '#136 重构第 10 步',
        'page': 'task',
      };
    },
  );

  void orbTest(
    String name,
    Future<void> Function(WidgetTester t) body, {
    List<OrbTool> tools = const [],
  }) {
    testWidgets(name, (t) async {
      gemini = FakeGemini();
      navigated.clear();
      f = ActionOrbFixture(t)
        ..agentLayer = true
        ..sessionFactory =
            ({
              required provider,
              required apiKey,
              required systemPrompt,
              required tools,
              required onToolCall,
              required voice,
              reasoning = AgentReasoning.low,
              onAudio,
              onInputText,
              onOutputText,
              onTurnComplete,
              onInterrupted,
              onClosed,
              playbackPending,
              steering,
            }) => GeminiAgentSession(
              apiKey: 'test-key',
              systemPrompt: systemPrompt,
              tools: tools,
              steering: steering,
              transport: gemini.call,
              retryDelay: Duration.zero,
              onToolCall: onToolCall,
              onOutputText: onOutputText,
              onTurnComplete: onTurnComplete,
              onClosed: onClosed,
            );
      await f.setUp();
      await f.pump(tools: tools);
      await t.pump(const Duration(milliseconds: 300));
      await body(t);
      await t.pumpWidget(const SizedBox());
      await f.tearDown();
    });
  }

  OrbController orb() => f.controller;

  /// Types [line] and lets the turn run.
  Future<void> say(WidgetTester t, String line) async {
    unawaited(orb().sendText(line));
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  List<String> agentLines() => [
    for (final e in orb().entries)
      if (e.kind == OrbEntryKind.agent) e.text,
  ];

  const reply = {'message': 'm-1', 'text': '可以'};

  orbTest('the card is worded by the app, and the model is not asked again', (
    t,
  ) async {
    gemini.replies.add(_call('reply_in_thread', reply));
    await say(t, '回他可以');

    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
    expect(orb().actions.pending, isNotNull);
    expect(gemini.requests, hasLength(1));
    expect(f.world.sent, isEmpty);
    // The first request had the whole app; the card is up for the next.
    List<String> tools(Map<String, Object?> r) => [
      for (final d
          in ((r['tools'] as List).single as Map)['functionDeclarations']
              as List)
        '${(d as Map)['name']}',
    ];
    expect(tools(gemini.requests.single), contains('screen_action'));
    expect(tools(gemini.requests.single), isNot(contains('confirm')));
  });

  void toCody() {
    orb().actions.replyContext = () => OrbReplyContext(
      needsYou: () async => const [
        OrbBriefItem(
          id: 'msg:m-1',
          title: 'Cody 问你：周五上线可以吗？',
          who: 'Cody',
          where: '#general',
          since: '已等 5 分钟',
          link: '/s/s1/channel/ch-general',
          sourceIds: ['msg:m-1', 'm-1'],
          channelId: 'ch-general',
          reason: OrbReason.mentionAsk,
          why: '点名你',
        ),
      ],
    );
  }

  orbTest('a reply nobody asked for ("什么需要我处理") is not shown as a card', (
    t,
  ) async {
    toCody();
    gemini.replies.addAll([
      _call('reply', {'text': '可以合入'}),
      _say('Cody 在等你。'),
    ]);
    await say(t, '什么需要我处理');
    final blocked =
        (((gemini.requests[1]['contents'] as List).last as Map)['parts']
                    as List)
                .single['functionResponse']['response']
            as Map;
    expect(blocked['error'], contains('用户没有让你回复'));
    expect(orb().actions.pending, isNull);
    expect(agentLines(), ['Cody 在等你。']);
  });

  orbTest('a card is up: a reply that changes it needs no verb of its own', (
    t,
  ) async {
    toCody();
    gemini.replies.addAll([
      _call('reply', {'text': '可以'}),
      _call('reply', {'text': '改成这样'}),
    ]);
    await say(t, '回他可以');
    await say(t, '改成这样');
    expect(agentLines().last, '回复 Cody：改成这样，要发吗？');
  });

  orbTest('words the person gave: an invented reply is sent back with no '
      'card, and the right one is shown', (t) async {
    toCody();
    gemini.replies.addAll([
      _call('reply', {'text': '马上看'}),
      _call('reply', {'text': '可以'}),
    ]);
    await say(t, '回他可以');

    expect(gemini.requests, hasLength(2));
    final answer =
        (((gemini.requests[1]['contents'] as List).last as Map)['parts']
                    as List)
                .single['functionResponse']['response']
            as Map;
    expect(answer['error'], contains('回复的内容不是用户说的'));
    expect(answer['error'], contains('“可以”'));
    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
  });

  orbTest('still not the person\'s words: the app puts them in itself', (
    t,
  ) async {
    toCody();
    gemini.replies.addAll([
      _call('reply', {'text': '马上看'}),
      _call('reply', {'text': '收到'}),
    ]);
    await say(t, '回他可以');
    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
    await say(t, '确认');
    expect(f.world.sent.single.text, '可以');
  });

  orbTest('no words given ("回他一下"): the model\'s are used', (t) async {
    toCody();
    gemini.replies.add(_call('reply', {'text': '稍等'}));
    await say(t, '回他一下');
    expect(gemini.requests, hasLength(1));
    expect(agentLines(), ['回复 Cody：稍等，要发吗？']);
  });

  orbTest('a name the App knows, then 说: the words are what follows', (
    t,
  ) async {
    toCody();
    gemini.replies.addAll([
      _call('reply', {'text': '马上看'}),
      _call('reply', {'text': '收到'}),
    ]);
    await say(t, '回复 Cody 说可以');
    // Held to "可以", not to "Cody 说可以".
    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
  });

  orbTest('a name nobody knows: not guessed at, the model\'s text is shown', (
    t,
  ) async {
    toCody();
    gemini.replies.add(_call('reply', {'text': '可以'}));
    await say(t, '回复小明说可以');
    expect(gemini.requests, hasLength(1));
    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
  });

  orbTest('two people to answer: the guard is off, nothing is filled in', (
    t,
  ) async {
    toCody();
    gemini.replies.add(_call('reply', {'text': '明天见'}));
    await say(t, '回他可以，再跟 Alice 说明天见');
    expect(gemini.requests, hasLength(1));
    expect(agentLines().single, contains('明天见'));
    expect(agentLines().single, isNot(contains('可以')));
  });

  orbTest('the person said what to reply and the model reached for snooze: '
      'not run; the app asks for the reply itself', (t) async {
    toCody();
    gemini.replies.addAll([
      _call('snooze_item', {'item': 'msg:m-1', 'when': 'later'}),
      _say('好的。'),
    ]);
    await say(t, '回他“晚上看”');

    final blocked =
        (((gemini.requests[1]['contents'] as List).last as Map)['parts']
                    as List)
                .single['functionResponse']['response']
            as Map;
    expect(blocked['error'], contains('用 reply'));
    expect(blocked['error'], contains('“晚上看”'));
    expect(agentLines(), ['回复 Cody：晚上看，要发吗？']);
    await say(t, '确认');
    expect(f.world.sent.single.text, '晚上看');
  });

  orbTest('the same, and the model then replies itself: its call is used', (
    t,
  ) async {
    toCody();
    gemini.replies.addAll([
      _call('snooze_item', {'item': 'msg:m-1'}),
      _call('reply', {'text': '晚上看'}),
    ]);
    await say(t, '回他“晚上看”');
    expect(gemini.requests, hasLength(2));
    expect(agentLines(), ['回复 Cody：晚上看，要发吗？']);
  });

  orbTest('a write is not blocked when no words were given', (t) async {
    toCody();
    gemini.replies.add(_call('react', {'message': 'm-1', 'emoji': '👍'}));
    await say(t, '给他点个赞');
    expect(agentLines().single, contains('👍'));
  });

  orbTest('"打开 task 136": the model read, the app opened the task and the '
      'model answers from it', (t) async {
    gemini.replies.addAll([
      _call('task_detail', {'number': 136}),
      _say('任务 136 在等验收。'),
      _say('到了任务 136，Cody 做的，等你验收。'),
    ]);
    await say(t, '打开 task 136');

    expect(navigated, [
      {'task_number': 136},
    ]);
    expect(gemini.requests, hasLength(3));
    final note = jsonEncode((gemini.requests.last['contents'] as List).last);
    expect(note, contains('打开 task 136'));
    expect(note, contains('已经替你调用 navigate'));
    expect(agentLines(), ['到了任务 136，Cody 做的，等你验收。']);
  }, tools: [navigateStub()]);

  orbTest('"打开 task 136": when the model navigates itself, the app does '
      'nothing more', (t) async {
    gemini.replies.addAll([
      _call('navigate', {'task_number': 136}),
      _say('到了任务 136。'),
    ]);
    await say(t, '打开 task 136');
    expect(navigated, hasLength(1));
    expect(gemini.requests, hasLength(2));
  }, tools: [navigateStub()]);

  orbTest(
    'something that is not an order to open one place is not '
    'opened for the model',
    (t) async {
      gemini.replies.addAll([_call('describe_page', {}), _say('这是动态。')]);
      await say(t, '打开动态，什么需要我处理');
      expect(navigated, isEmpty);
      await say(t, '任务 136 怎么样了');
      expect(navigated, isEmpty);
    },
    tools: [
      navigateStub(),
      OrbTool(
        declaration: const {'name': 'describe_page'},
        handler: (args, ctx) async => {
          'page': 'activity',
          'loading': false,
          'items': <Object?>[],
        },
      ),
    ],
  );

  orbTest('send_message and reply_in_thread are held to the words too', (
    t,
  ) async {
    gemini.replies.addAll([
      _call('send_message', {'channel': 'general', 'text': '随便'}),
      _call('send_message', {'channel': 'general', 'text': '随便'}),
    ]);
    await say(t, '跟他说我马上到');
    expect(agentLines().single, contains('我马上到'));
  });

  orbTest('reply with nobody named is the person the app finds, and the card '
      'says who', (t) async {
    orb().actions.replyContext = () => OrbReplyContext(
      needsYou: () async => const [
        OrbBriefItem(
          id: 'msg:m-1',
          title: 'Cody 问你：周五上线可以吗？',
          who: 'Cody',
          where: '#general',
          since: '已等 5 分钟',
          link: '/s/s1/channel/ch-general',
          sourceIds: ['msg:m-1', 'm-1'],
          channelId: 'ch-general',
          reason: OrbReason.mentionAsk,
          why: '点名你',
        ),
      ],
    );
    gemini.replies.add(_call('reply', {'text': '可以'}));
    await say(t, '回复他说可以');

    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
    await say(t, '确认');
    expect(f.world.sent.single.text, '可以');
    expect(agentLines().last, '已回复。');
    // The model's tools: `reply`, not the two it replaces.
    final names = [
      for (final d
          in ((gemini.requests.first['tools'] as List).single
                  as Map)['functionDeclarations']
              as List)
        '${(d as Map)['name']}',
    ];
    expect(names, contains('reply'));
    expect(names, isNot(contains('send_message')));
    expect(names, isNot(contains('reply_in_thread')));
  });

  orbTest('no words after a tool: asked once more, then the app says what '
      'the tool found', (t) async {
    gemini.replies.addAll([_call('list_tasks', {}), _say(''), _say('')]);
    await say(t, '看看任务');

    expect(gemini.requests, hasLength(3), reason: 'asked once more');
    expect(agentLines(), hasLength(1));
    expect(agentLines().single, startsWith('共 1 个任务'));
    expect(agentLines().single, contains('丁'));
  });

  orbTest('no words after a tool, then words after the nudge: the model\'s '
      'words are said', (t) async {
    gemini.replies.addAll([
      _call('list_tasks', {}),
      _say(''),
      _say('丁，Cody 负责。'),
    ]);
    await say(t, '看看任务');
    expect(agentLines(), ['丁，Cody 负责。']);
  });

  group('"全部处理掉" while driving', () {
    // #12 and #13 are stuck, #14 waits for the user's review (the user made
    // it): the first two can be worked on in the car, the third waits.
    void tasks() {
      f.world.routes['/tasks/server'] = (q) => {
        'tasks': [
          if (q?['status'] == 'in_progress') ...[
            {
              ...taskRow(
                't12',
                12,
                'in_progress',
                title: '丁',
                claimedById: 'a-cody',
                claimedByName: 'Cody',
              ),
              'updatedAt': hoursAgo(200),
              'messageId': 'm-task-12',
            },
            {
              ...taskRow(
                't13',
                13,
                'in_progress',
                title: '戊',
                claimedById: 'a-bajie',
                claimedByName: '八戒',
              ),
              'updatedAt': hoursAgo(100),
            },
          ],
          if (q?['status'] == 'in_review')
            {
              ...taskRow(
                't14',
                14,
                'in_review',
                title: '己',
                claimedById: 'a-cody',
                claimedByName: 'Cody',
              ),
              'updatedAt': hoursAgo(300),
            },
        ],
      };
    }

    orbTest('the app holds the queue: the first task to work on, the review '
        'left for parking, and "下一个" goes on', (t) async {
      tasks();
      await orb().setDriving(true);
      await t.pump(const Duration(milliseconds: 300));
      gemini.replies.addAll([
        _call('list_tasks', {'stale': true}),
        _call('nudge_task', {'task': '12'}),
      ]);
      await say(t, '全部处理掉');

      // One card, for the first task that can be worked on, and the app says
      // what waits for parking before it.
      final line = agentLines().single;
      expect(line, startsWith('「己」在等你验收，要停车后再验收。'));
      expect(line, endsWith('要催吗？'));
      expect(orb().actions.pending, isNotNull);
      // The list the model read has the queue.
      final list = (gemini.requests[1]['contents'] as List).last as Map;
      final answer =
          ((list['parts'] as List).single
                  as Map)['functionResponse']['response']
              as Map;
      expect((answer['queue'] as Map)['current']['number'], 12);
      expect((answer['queue'] as Map)['waitForParking'], ['己']);

      // After the yes: what is left.
      await say(t, '确认');
      expect(f.world.sent, hasLength(1));
      expect(agentLines().last, '已催 Cody。还有 1 个，说“下一个”继续。');

      // The model is told where the pass is, and has next_task.
      gemini.replies.add(_say('嗯'));
      await say(t, '下一个');
      final last = gemini.requests.last;
      final system =
          ((last['systemInstruction'] as Map)['parts'] as List).single['text']
              as String;
      expect(system, contains('【任务队列】'));
      expect(system, contains('#12「丁」'));
      expect(system, contains('next_task'));
      expect(system, contains('【逐个处理任务】'));

      final next = await orb().dispatch('next_task', const {});
      expect(next['done'], isFalse);
      expect((next['current'] as Map)['number'], 13);
      expect(next['index'], 2);
      final done = await orb().dispatch('next_task', const {});
      expect(done['done'], isTrue);
      await orb().setDriving(false);
    });

    orbTest('the model read the tasks and proposed nothing: the app proposes '
        'the nudge for the one the queue is on', (t) async {
      tasks();
      await orb().setDriving(true);
      await t.pump(const Duration(milliseconds: 300));
      gemini.replies.addAll([
        _call('list_tasks', {'stale': true}),
        _say('这个等你停车后再做。'),
      ]);
      await say(t, '全部处理掉');

      expect(gemini.requests, hasLength(2));
      final line = agentLines().single;
      expect(line, startsWith('「己」在等你验收，要停车后再验收。'));
      expect(line, endsWith('要催吗？'));
      expect(orb().actions.pending, isNotNull);
      await say(t, '确认');
      expect(f.world.sent, hasLength(1));
      expect(agentLines().last, '已催 Cody。还有 1 个，说“下一个”继续。');
      await orb().setDriving(false);
    });

    orbTest('a nudge whose words carry a task title with 发布 is not '
        'refused as a release', (t) async {
      tasks();
      await orb().setDriving(true);
      await t.pump(const Duration(milliseconds: 300));
      gemini.replies.add(
        _call('nudge_task', {'task': '12', 'text': '整理发布说明现在到哪了？'}),
      );
      await say(t, '催一下丁');
      expect(orb().actions.pending, isNotNull);
      expect(agentLines().single, contains('要催吗？'));
      await orb().setDriving(false);
    });

    orbTest('a plain request that is not "处理掉" is left to the model', (
      t,
    ) async {
      tasks();
      await orb().setDriving(true);
      await t.pump(const Duration(milliseconds: 300));
      gemini.replies.addAll([
        _call('list_tasks', {'stale': true}),
        _say('己，Cody 负责。丁，Cody 负责。戊，八戒 负责。'),
      ]);
      await say(t, '看看那些任务');
      expect(orb().actions.pending, isNull);
      expect(agentLines().single, '己，Cody 负责。丁，Cody 负责。戊，八戒 负责。');
      await orb().setDriving(false);
    });

    orbTest('next_task is for driving only', (t) async {
      final r = await orb().dispatch('next_task', const {});
      expect(r['error'], isNotNull);
    });
  });

  orbTest(
    '"读一下动态" read out as one item: sent back, then the app reads the list',
    (t) async {
      gemini.replies.addAll([
        _call('describe_page', {}),
        _say('Alice 问你周五能不能来评审。'),
        _say('Alice 问评审。'),
      ]);
      await say(t, '读一下动态');

      expect(gemini.requests, hasLength(3), reason: 'sent back once');
      expect(agentLines().single, startsWith('共 2 条：Alice，@Alice'));
      expect(agentLines().single, contains('Cody，#raft-flutter'));
    },
    tools: [
      OrbTool(
        declaration: const {'name': 'describe_page'},
        handler: (args, ctx) async => {
          'page': 'activity',
          'loading': false,
          'items': [
            {'n': 1, 'who': 'Alice', 'where': '@Alice', 'preview': '周五能来评审吗？'},
            {
              'n': 2,
              'who': 'Cody',
              'where': '#raft-flutter',
              'preview': '可以合入吗？',
            },
          ],
        },
      ),
    ],
  );

  orbTest('a plain 确认 runs confirm in code and the app says the result', (
    t,
  ) async {
    gemini.replies.add(_call('reply_in_thread', reply));
    await say(t, '回他可以');
    await say(t, '确认');

    expect(gemini.requests, hasLength(1), reason: 'no model call for a yes');
    expect(f.world.sent, hasLength(1));
    expect(f.world.sent.single.text, '可以');
    expect(agentLines(), ['回复 Cody：可以，要发吗？', '已回复。']);
    expect(orb().actions.pending, isNull);
  });

  orbTest('a spoken yes is not enough in a typed word that is longer', (
    t,
  ) async {
    gemini.replies.addAll([_call('reply_in_thread', reply), _say('好，我改一下')]);
    await say(t, '回他可以');
    await say(t, '好，加上谢谢');

    // The model got it: it is not a plain yes. Nothing was written.
    expect(gemini.requests, hasLength(2));
    expect(f.world.sent, isEmpty);
    expect(agentLines().last, '好，我改一下');
    // And it saw the card state: only the confirming tools and instruction.
    final second = gemini.requests.last;
    final system =
        ((second['systemInstruction'] as Map)['parts'] as List).single['text']
            as String;
    expect(system, contains('【等着确认】'));
  });

  orbTest('a plain 取消 cancels in code and the app says so', (t) async {
    gemini.replies.add(_call('reply_in_thread', reply));
    await say(t, '回他可以');
    await say(t, '算了');

    expect(gemini.requests, hasLength(1));
    expect(f.world.sent, isEmpty);
    expect(orb().actions.pending, isNull);
    expect(agentLines().last, '好，已取消。');
  });

  orbTest('a tap on 确认 is said by the app, with no model turn', (t) async {
    gemini.replies.add(_call('reply_in_thread', reply));
    await say(t, '回他可以');
    await orb().actions.confirmTapped();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(gemini.requests, hasLength(1));
    expect(f.world.sent, hasLength(1));
    expect(agentLines().last, '已回复。');
  });

  orbTest('a tap on 取消 is said by the app too', (t) async {
    gemini.replies.add(_call('reply_in_thread', reply));
    await say(t, '回他可以');
    await orb().actions.cancelTapped();
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    expect(gemini.requests, hasLength(1));
    expect(agentLines().last, '好，已取消。');
  });

  orbTest('asking 要发吗 with no card is put right inside the turn', (t) async {
    gemini.replies.addAll([
      _say('回复 Cody：可以，要发吗？'),
      _call('reply_in_thread', reply),
    ]);
    await say(t, '回他可以');

    // The first words never reached the person; the card did.
    expect(agentLines(), ['回复 Cody：可以，要发吗？']);
    expect(orb().actions.pending, isNotNull);
    expect(gemini.requests, hasLength(2));
    final note = (gemini.requests.last['contents'] as List).last as Map;
    expect(jsonEncode(note), contains('动作工具'));
  });

  orbTest('a sensitive card is not confirmed by a spoken yes', (t) async {
    gemini.replies.addAll([
      _call('act', {
        'capability': 'agents.stop',
        'args': {'agent': 'Cody'},
      }),
      _call('confirm', {}),
    ]);
    await say(t, '把 Cody 停掉');
    expect(orb().actions.pending?.sensitive, isTrue);
    expect(agentLines().single, contains('点屏幕上的确认'));

    await say(t, '确认');
    // Words do not count: the model was asked, it called confirm, and the
    // app's words say it takes the button.
    expect(f.world.commands, isEmpty);
    expect(agentLines().last, contains('确认'));
    expect(orb().actions.pending, isNotNull);
  });
}
