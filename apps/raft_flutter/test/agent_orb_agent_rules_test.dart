import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_steering.dart';
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

  /// What the stand-in `navigate` answers (a test sets it).
  Map<String, Object?>? navigateResult;

  /// Answers given first, in order, before [navigateResult].
  final navigateQueue = <Map<String, Object?>>[];

  OrbTool navigateStub([Map<String, Object?>? result]) => OrbTool(
    declaration: const {'name': 'navigate'},
    handler: (args, ctx) async {
      navigated.add(args);
      if (navigateQueue.isNotEmpty) return navigateQueue.removeAt(0);
      return navigateResult ??
          result ??
          {'route': '/s/s1/task/136', 'title': '#136 重构第 10 步', 'page': 'task'};
    },
  );

  AgentSteering? lastSteering;

  void orbTest(
    String name,
    Future<void> Function(WidgetTester t) body, {
    List<OrbTool> tools = const [],
  }) {
    testWidgets(name, (t) async {
      gemini = FakeGemini();
      navigated.clear();
      navigateResult = null;
      navigateQueue.clear();
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
            }) {
              lastSteering = steering;
              return GeminiAgentSession(
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
            };
      await f.setUp();
      await f.pump(tools: tools);
      await t.pump(const Duration(milliseconds: 300));
      await body(t);
      await t.pumpWidget(const SizedBox());
      await f.tearDown();
    });
  }

  String jsonEncodeParts(Map content) => [
    for (final p in (content['parts'] as List))
      if ((p as Map)['text'] is String) '${p['text']}',
  ].join('\n');

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

  orbTest('the voice layer is told what the confirmation has to carry, for '
      'the turn that put the card up only', (t) async {
    gemini.replies.addAll([_call('reply_in_thread', reply), _say('好')]);
    await say(t, '回他可以');
    final info = lastSteering!.confirmation!();
    expect(info, isNotNull);
    expect(info!.missingIn('我替你回复 Cody，说可以，要发吗？'), isEmpty);
    expect(info.missingIn('好的。'), isNotEmpty);
    // The next turn is not about the card.
    await say(t, '这是什么');
    expect(lastSteering!.confirmation!(), isNull);
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
    // (The app also reads the Activity here, and puts "nothing for you" and
    // the waiting task around the model's words.)
    expect(agentLines().single, contains('Cody 在等你。'));
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

  const taskArrived = <String, Object?>{
    'route': '/s/s1/task/136',
    'title': '#136 重构第 10 步',
    'matched': {'kind': 'task', 'id': '#136', 'score': 1.0},
    'page': {
      'page': 'task',
      'task': {
        'number': 136,
        'title': '重构第 10 步',
        'status': 'in_review',
        'assignee': 'Cody',
      },
    },
  };

  Map<String, Object?> channelArrived({num score = 1.0, bool needs = true}) => {
    'route': '/s/s1/channel/ch-general',
    'title': '#general',
    'matched': {'kind': 'channel', 'id': 'ch-general', 'score': score},
    'briefing': {
      'scope': 'conversation:ch-general',
      'needsYou': [
        if (needs)
          {
            'id': 'x',
            'who': 'Cody',
            'title': 'Cody 问你：周五上线可以吗？',
            'since': '已等 5 分钟',
          },
      ],
    },
  };

  orbTest('"打开 task 136" is the app\'s own: navigate, and the task in a '
      'sentence, no model call', (t) async {
    await say(t, '打开 task 136');
    expect(gemini.requests, isEmpty);
    expect(navigated, [
      {'task_number': 136},
    ]);
    expect(agentLines(), ['任务 #136「重构第 10 步」在等你验收，由 Cody 负责。']);
    expect(orb().fastPath, 'open');
  }, tools: [navigateStub(taskArrived)]);

  orbTest('"去 general": arrival and what needs the user, or nothing', (
    t,
  ) async {
    await say(t, '去 general');
    expect(gemini.requests, isEmpty);
    expect(navigated, [
      {'channel_id': 'ch-general'},
    ]);
    expect(
      agentLines().single,
      '到了#general。有 1 件事在等你：Cody 问你：周五上线可以吗，已经等了 5 分钟。',
    );
  }, tools: [navigateStub(channelArrived())]);

  orbTest('arrival with nothing for the user says so', (t) async {
    await say(t, '去 general');
    expect(agentLines().single, '到了#general。没有要你处理的。');
  }, tools: [navigateStub(channelArrived(needs: false))]);

  orbTest(
    'an arrival that is not clear is the model\'s',
    (t) async {
      gemini.replies.add(_say('这个频道还在加载。'));
      await say(t, '去 general');
      // The app went; it had no sentence for it; the model answers.
      expect(navigated, hasLength(1));
      expect(gemini.requests, hasLength(1));
      expect(agentLines(), ['这个频道还在加载。']);
    },
    tools: [
      navigateStub({'title': '#general', 'briefingNote': '没读出来'}),
    ],
  );

  orbTest('the app\'s navigate gave no sentence, the model\'s does: told from '
      'what it brought, no answer step', (t) async {
    navigateQueue.add({'title': '#general', 'briefingNote': '没读出来'});
    gemini.replies.add(_call('navigate', {'channel_id': 'ch-general'}));
    await say(t, '去 general');
    expect(navigated, hasLength(2));
    expect(gemini.requests, hasLength(1));
    expect(
      agentLines().single,
      '到了#general。有 1 件事在等你：Cody 问你：周五上线可以吗，已经等了 5 分钟。',
    );
  }, tools: [navigateStub(channelArrived())]);

  orbTest('but not when the place is a guess, or a question was asked', (
    t,
  ) async {
    gemini.replies.addAll([
      _call('navigate', {'target': 'genral'}),
      _say('是 general 吗？'),
      _call('navigate', {'channel_id': 'ch-general'}),
      _say('Cody 问周五上线。'),
    ]);
    // A fuzzy match: the model may ask.
    navigateResult = channelArrived(score: .8);
    await say(t, '去 genral');
    expect(agentLines().last, '是 general 吗？');
    // A question beside the order.
    navigateResult = channelArrived();
    await say(t, '去 general 有什么新的');
    expect(agentLines().last, startsWith('Cody 问周五上线。'));
    expect(gemini.requests, hasLength(4));
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

      // "下一个" is the app's own: the next task, and the plain action for it.
      final before = gemini.requests.length;
      await say(t, '下一个');
      expect(gemini.requests, hasLength(before), reason: 'no model call');
      expect(agentLines().last, startsWith('第 2 个任务：#13「戊」'));
      expect(orb().fastPath, 'next');

      // The model is told where the pass is, and has next_task.
      gemini.replies.add(_say('嗯'));
      await say(t, '这是什么');
      final last = gemini.requests.last;
      final system =
          ((last['systemInstruction'] as Map)['parts'] as List).single['text']
              as String;
      expect(system, contains('【任务队列】'));
      expect(system, contains('#13「戊」'));
      expect(system, contains('next_task'));
      expect(system, contains('【逐个处理任务】'));

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

  group('commands the app does without the model', () {
    OrbBriefItem item(String who, String title) => OrbBriefItem(
      id: 'msg:$who',
      title: title,
      who: who,
      where: '#general',
      since: '已等 5 分钟',
      link: '/s/s1/channel/ch-general',
      sourceIds: const [],
      reason: OrbReason.mentionAsk,
      why: '点名你',
    );

    Future<void> cards(WidgetTester t) async {
      orb().showBriefing(
        OrbBriefing(
          scope: OrbBriefScope.activity,
          overview: '',
          needsYou: [
            item('Cody', 'Cody 问你：上线吗？'),
            item('Alice', 'Alice 问你：开会吗？'),
          ],
          progress: const [],
          routineCount: 3,
        ),
      );
      await orb().setDriving(true);
      await t.pump(const Duration(milliseconds: 300));
    }

    orbTest('下一件, 上一件 and the end of the cards: no model call', (t) async {
      await cards(t);
      await say(t, '下一件');
      expect(agentLines().last, '第 2 件，共 2 件：Alice 问你：开会吗，已经等了 5 分钟。');
      expect(orb().fastPath, 'next');
      expect(orb().drivingIndex, 1);
      await say(t, '上一件');
      expect(agentLines().last, '第 1 件，共 2 件：Cody 问你：上线吗，已经等了 5 分钟。');
      expect(orb().drivingIndex, 0);
      await say(t, '下一件');
      await say(t, '下一件');
      expect(agentLines().last, '就这些。其余 3 条是常规进度。');
      expect(orb().drivingDone, isTrue);
      expect(gemini.requests, isEmpty);
    });

    orbTest('停车了 leaves driving mode; 开始驾驶模式 enters it', (t) async {
      await cards(t);
      await say(t, '停车了');
      expect(agentLines().last, '好，退出驾驶模式。');
      expect(orb().driving, isFalse);
      expect(orb().fastPath, 'park');
      await say(t, '开始驾驶模式');
      expect(agentLines().last, '好，驾驶模式。');
      expect(orb().driving, isTrue);
      expect(gemini.requests, isEmpty);
    });

    orbTest('anything else is the model\'s, and clears the mark', (t) async {
      await cards(t);
      await say(t, '下一件');
      expect(orb().fastPath, 'next');
      gemini.replies.add(_say('第二件是 Alice 问开会。'));
      await say(t, '这一件是谁的');
      expect(orb().fastPath, isNull);
      expect(gemini.requests, hasLength(1));
    });

    orbTest('not while a card waits for the user\'s answer', (t) async {
      toCody();
      await cards(t);
      gemini.replies.addAll([
        _call('reply', {'text': '可以'}),
        _say('在'),
      ]);
      await say(t, '回他可以');
      expect(orb().actions.pending, isNotNull);
      await say(t, '下一件');
      expect(orb().fastPath, isNull);
      expect(gemini.requests, hasLength(2));
    });
  });

  group('the fast path does what the model path did', () {
    OrbBriefItem item(String who, String title) => OrbBriefItem(
      id: 'msg:$who',
      title: title,
      who: who,
      where: '#general',
      since: '已等 5 分钟',
      link: '/s/s1/channel/ch-general',
      sourceIds: const [],
      reason: OrbReason.mentionAsk,
      why: '点名你',
    );

    final deck = [
      item('Cody', 'Cody 问你：上线吗？'),
      item('Alice', '周五能来评审吗？'),
      item('Grok', 'Grok 问你：接口确认吗？'),
    ];

    /// `get_briefing` as the real one does with show: the deck is laid out.
    OrbTool getBriefing({
      List<OrbBriefItem>? items,
      Map<String, Object?>? raw,
    }) => OrbTool(
      declaration: const {'name': 'get_briefing'},
      handler: (args, ctx) async {
        if (raw != null) return raw;
        final b = OrbBriefing(
          scope: OrbBriefScope.activity,
          overview: '',
          needsYou: items ?? deck,
          progress: const [],
          routineCount: 3,
        );
        if (args['show'] == true) orb().showBriefing(b);
        return b.toJson();
      },
    );

    orbTest('D1: 开始驾驶模式 lays out the cards and says the first', (t) async {
      await say(t, '开始驾驶模式');
      expect(gemini.requests, isEmpty);
      expect(orb().driving, isTrue);
      // The deck is up, the first card is a message.
      expect(orb().drivingItems.map((i) => i.who), ['Cody', 'Alice', 'Grok']);
      expect(orb().drivingIndex, 0);
      expect(agentLines().single, '好，驾驶模式。第 1 件，共 3 件：Cody 问你：上线吗，已经等了 5 分钟。');
      expect(orb().fastPath, 'drive');
    }, tools: [getBriefing()]);

    orbTest('D2: 下一件 after it names the card now shown, and who', (t) async {
      await say(t, '开始驾驶模式');
      await say(t, '下一件');
      expect(orb().drivingIndex, 1);
      // The title of this one does not name the sender: the sentence does.
      expect(agentLines().last, '第 2 件，共 3 件：Alice：周五能来评审吗，已经等了 5 分钟。');
      await say(t, '下一件');
      expect(agentLines().last, contains('Grok'));
    }, tools: [getBriefing()]);

    orbTest('nothing for the user: said so, and the routine count', (t) async {
      await say(t, '开始驾驶模式');
      expect(agentLines().single, '好，驾驶模式。没有要你处理的。其余 3 条是常规进度。');
    }, tools: [getBriefing(items: const [])]);

    orbTest(
      'a briefing that did not read: driving mode, and no claim',
      (t) async {
        await say(t, '开始驾驶模式');
        expect(orb().driving, isTrue);
        expect(agentLines().single, '好，驾驶模式。');
      },
      tools: [
        getBriefing(raw: {'error': '简报没读出来'}),
      ],
    );

    orbTest(
      'C1: "看看 Cody 私信" is a look, not an order: the model answers '
      'after its navigate, and "到了主页" is never said',
      (t) async {
        gemini.replies.addAll([
          _call('navigate', {'page': 'home', 'target': 'Ada', 'kind': 'dm'}),
          _say('Ada 在等你，要回她吗？'),
        ]);
        await say(t, '看看 Ada 私信');
        expect(gemini.requests, hasLength(2));
        expect(agentLines().last, contains('Ada'));
        expect(agentLines().last, isNot(contains('到了主页')));
      },
      tools: [
        navigateStub({
          'title': '主页',
          'matched': {'kind': 'page', 'id': 'home', 'score': 1.0},
          'page': {'page': 'other'},
        }),
      ],
    );

    orbTest(
      '"打开 Ada 私信": the DM in a sentence: who, what, answer?',
      (t) async {
        await say(t, '打开 Ada 私信');
        expect(navigated, [
          {'dm_id': 'dm-1'},
        ]);
        expect(agentLines().single, 'Ada 问你：周五评审吗，已经等了 15 分钟。要回吗？');
      },
      tools: [
        navigateStub({
          'title': 'Ada',
          'matched': {'kind': 'dm', 'id': 'dm-1', 'score': 1.0},
          'briefing': {
            'needsYou': [
              {'who': 'Ada', 'title': 'Ada 问你：周五评审吗？', 'since': '已等 15 分钟'},
            ],
          },
        }),
      ],
    );

    orbTest(
      'a model\'s navigate to somewhere else than the words name is '
      'not told as "arrived"',
      (t) async {
        gemini.replies.addAll([
          _call('navigate', {'page': 'home'}),
          _say('我在主页。'),
        ]);
        await say(t, '带我去 general');
        // The model went to the home page: not what was asked; no app sentence.
        expect(gemini.requests, hasLength(2));
        expect(agentLines().last, '我在主页。');
      },
      tools: [
        navigateStub({
          'title': '主页',
          'matched': {'kind': 'page', 'id': 'home', 'score': 1.0},
        }),
      ],
    );

    orbTest(
      'B6: a briefing read while the inbox has not come is not kept as '
      'an empty one: the model is not told "nothing"',
      (t) async {
        gemini.replies.addAll([
          _call('get_briefing', {}),
          _say('动态还在加载。'),
          _say('嗯'),
        ]);
        await say(t, '有什么新的');
        await say(t, '再看一眼');
        final c = (gemini.requests.last['contents'] as List).last as Map;
        final text = [
          for (final p in (c['parts'] as List))
            if ((p as Map)['text'] is String) '${p['text']}',
        ].join('\n');
        expect(text, isNot(contains('没有等用户处理')));
      },
      tools: [
        getBriefing(
          raw: {
            'scope': 'activity',
            'needsYou': <Object?>[],
            'progress': <Object?>[],
            'routineCount': 0,
          },
        ),
      ],
    );

    orbTest('an empty briefing shown before the Activity is read is a blank', (
      t,
    ) async {
      orb().showBriefing(
        OrbBriefing(
          scope: OrbBriefScope.activity,
          overview: '',
          needsYou: const [],
          progress: const [],
          routineCount: 0,
        ),
      );
      gemini.replies.add(_say('好'));
      await say(t, '你好');
      final c = (gemini.requests.single['contents'] as List).last as Map;
      expect(jsonEncodeParts(c), isNot(contains('没有等用户处理')));
    });
  });

  group('what the agent is told before each ask', () {
    OrbBriefItem item(String who, String title, String since) => OrbBriefItem(
      id: 'msg:$who',
      title: title,
      who: who,
      where: '#general',
      since: since,
      link: '/s/s1/channel/ch-general',
      sourceIds: const [],
      reason: OrbReason.mentionAsk,
      why: '点名你',
    );

    OrbBriefing briefing(List<OrbBriefItem> items, {int routine = 0}) =>
        OrbBriefing(
          scope: OrbBriefScope.activity,
          overview: '',
          needsYou: items,
          progress: const [],
          routineCount: routine,
        );

    List<String> context(int request) {
      final c = (gemini.requests[request]['contents'] as List).last as Map;
      return [
        for (final p in (c['parts'] as List))
          if ((p as Map)['text'] is String) '${p['text']}',
      ];
    }

    orbTest('the page and what needs the user, with the key facts, ride with '
        'the words; the answer can be one call', (t) async {
      orb().showBriefing(
        briefing([item('Cody', 'Cody 问你：第 10 步可以合入吗？', '已等 20 分钟')]),
      );
      gemini.replies.add(_say('Cody 在等你。'));
      await say(t, '什么需要我处理');

      expect(gemini.requests, hasLength(1), reason: 'no read first');
      final c = context(0).join('\n');
      expect(c, contains('用户现在在'));
      expect(c, contains('等用户处理的事'));
      expect(c, contains('Cody 问你：第 10 步可以合入吗？（已等 20 分钟）'));
      expect(c, contains('要点：Cody、第 10 步、合入、等了 20 分钟'));
      expect(c, contains('什么需要我处理'));
      // And the answer is still held to the facts: the app adds the rest.
      expect(agentLines().single, 'Cody 在等你。他在问第 10 步能不能合入，已经等了 20 分钟。');
    });

    orbTest('no needs-you item known is said so; nothing known, nothing '
        'claimed', (t) async {
      gemini.replies.addAll([_say('好'), _say('嗯')]);
      await say(t, '你好');
      expect(context(0).join(), isNot(contains('等用户处理')));
      expect(context(0).join(), isNot(contains('没有等用户处理')));
      // Not read is said as not read, never as empty.
      expect(context(0).join(), contains('动态页还没有读到内容'));
      orb().showBriefing(briefing(const [], routine: 2));
      await say(t, '再说一句');
      expect(context(1).join('\n'), contains('现在没有等用户处理的消息'));
    });

    orbTest('"nothing" from an Activity that was not read is "loading", '
        'without waiting for it', (t) async {
      gemini.replies.add(_say('什么都没有。'));
      await say(t, '有什么新的');
      expect(agentLines().single, '动态还在加载，稍后再看。');
      expect(gemini.requests, hasLength(1));
    });

    orbTest('a card that waits and the driving card are in it', (t) async {
      toCody();
      gemini.replies.addAll([
        _call('reply', {'text': '可以'}),
        _say('嗯'),
      ]);
      await say(t, '回他可以');
      gemini.replies.add(_say('好'));
      await say(t, '这是什么');
      final c = (gemini.requests.last['contents'] as List).last as Map;
      final texts = [
        for (final p in (c['parts'] as List))
          if ((p as Map)['text'] is String) '${p['text']}',
      ].join('\n');
      expect(texts, contains('屏幕上有一张等用户确认的卡'));
      expect(texts, contains('回复 Cody'));
    });

    orbTest('short: at most about 1500 characters', (t) async {
      orb().showBriefing(
        briefing([
          for (var i = 0; i < 6; i++)
            item('P$i', '很长的事 ${'字' * 400}', '已等 $i 分钟'),
        ]),
      );
      gemini.replies.add(_say('好'));
      await say(t, '你好');
      final c = context(0).where((x) => x.contains('等用户处理的事')).single;
      expect(c.length, lessThan(1700));
    });
  });

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
