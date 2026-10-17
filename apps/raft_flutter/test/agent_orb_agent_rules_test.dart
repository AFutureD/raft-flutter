import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show SizedBox;
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/gemini_agent.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_controller.dart';

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

  void orbTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (t) async {
      gemini = FakeGemini();
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
      await f.pump();
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
