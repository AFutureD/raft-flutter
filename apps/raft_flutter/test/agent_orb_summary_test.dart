import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;
import 'package:raft_flutter/features/agent_mode/agent_summary.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_orb/orb_summary.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'agent_orb_shell_session_test.dart' show fakeTool;
import 'agent_orb_shell_test.dart' show OrbFixture;

// The orb reuses Agent mode's session summary to the shared agent, but not for
// every short test session, and it says it comes from the orb.

const you = AgentSpeaker.you;
const agent = AgentSpeaker.agent;

AgentToolOutcome outcome(String name, [Map<String, Object?>? result]) =>
    AgentToolOutcome(
      name: name,
      args: const {},
      result: result ?? {'ok': true},
    );

void main() {
  group('worth sending', () {
    test('fewer than two things said is never worth it', () {
      expect(orbSummaryWorthSending(const [], const []), isFalse);
      expect(
        orbSummaryWorthSending(
          [(you, '去 raft-flutter'), (agent, '好的，已经打开了')],
          [outcome('send_message')],
        ),
        isFalse,
        reason: 'one turn, even with an action',
      );
      expect(
        orbSummaryWorthSending([
          (you, '  '),
          (agent, 'x'),
          (you, '你好'),
        ], const []),
        isFalse,
        reason: 'a blank line is not a turn',
      );
    });

    test('only navigation and reading is not worth it', () {
      final talk = [
        (you, '去 raft-flutter'),
        (agent, '到了'),
        (you, '动态里有什么要我处理的'),
        (agent, 'Cody 在等你批准'),
      ];
      expect(
        orbSummaryWorthSending(talk, [
          outcome('navigate'),
          outcome('describe_page'),
          outcome('read_conversation'),
          outcome('get_briefing'),
          outcome('show_orb_sheet'),
          outcome('navigate', {'error': '没找到'}),
        ]),
        isFalse,
      );
    });

    test('a decision or an action makes it worth it', () {
      final talk = [
        (you, '去 raft-flutter'),
        (agent, '到了'),
        (you, '批准第 10 步'),
        (agent, '好'),
      ];
      expect(
        orbSummaryWorthSending(talk, [
          outcome('navigate'),
          outcome('reply_message', {'status': 'needs_user_confirmation'}),
        ]),
        isTrue,
      );
    });

    test('two turns of talk with no tool at all can hold a preference', () {
      expect(
        orbSummaryWorthSending([
          (you, '以后简报先说 Cody 的事'),
          (agent, '记下了'),
          (you, '还有别太啰嗦'),
        ], const []),
        isTrue,
      );
    });
  });

  group('the header', () {
    test('Agent mode keeps its own; the orb says the orb', () async {
      final talk = [(you, '批准第 10 步')];
      final mode = await AgentSessionSummary.build(
        talk,
        const [],
        generate: (s, p) async => null,
      );
      final orb = await AgentSessionSummary.build(
        talk,
        const [],
        generate: (s, p) async => null,
        header: AgentSessionSummary.orbHeader,
      );
      expect(mode, startsWith('【语音对话摘要 · 来自 Agent 模式】'));
      expect(orb, startsWith('【语音对话摘要 · 来自 Agent 悬浮球】'));
      expect(orb, isNot(contains('来自 Agent 模式')));
      expect(orb, contains(AgentSessionSummary.instruction));
    });
  });

  group('the orb session', () {
    late OrbFixture f;
    final sent = <(String, String, int, List<String>)>[];

    Future<void> fixture(
      WidgetTester t, {
      List<OrbTool> tools = const [],
    }) async {
      f = OrbFixture(t);
      await f.setUp();
      sent.clear();
      // Connecting checks the shared agent against the workspace's agents.
      f.client.responses['GET /agents'] = [
        {'id': 'a-cody', 'name': 'Cody', 'displayName': 'Cody'},
      ];
      AgentVoiceSettings.instance
        ..brain = (id: 'a-cody', name: 'Cody')
        ..writeBack = true;
      f.summarySender = (brain, transcript, outcomes, header) async {
        sent.add((
          brain.name,
          header,
          transcript.where((l) => l.$1 == you).length,
          [for (final o in outcomes) o.name],
        ));
        return true;
      };
      addTearDown(f.tearDown);
      await f.pump(tools: tools);
      await t.pump(const Duration(milliseconds: 300));
    }

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 4; i++) {
        await t.pump();
      }
    }

    Future<void> say(WidgetTester t, String text) async {
      unawaited(f.controller.sendText(text));
      await settle(t);
      if (f.sessions.isNotEmpty && !f.sessions.last.connectGate.isCompleted) {
        f.sessions.last.connectGate.complete();
        await settle(t);
      }
      f.sessions.last.onOutputText!('好。');
      f.sessions.last.onTurnComplete!();
      await settle(t);
    }

    Future<void> hangUp(WidgetTester t) async {
      await f.controller.hangUp();
      await settle(t);
    }

    Future<void> call(WidgetTester t, String name) async {
      unawaited(f.sessions.last.onToolCall(name, {'target': 'x'}));
      await settle(t);
    }

    final tools = [
      fakeTool('navigate', (a, c) async => {'title': '动态'}),
      fakeTool('get_briefing', (a, c) async => {'overview': '没有新的'}),
      fakeTool('approve_step', (a, c) async => {'status': 'done'}),
    ];

    testWidgets('a quick "go to X" session sends nothing', (t) async {
      await fixture(t, tools: tools);
      await say(t, '去动态');
      await call(t, 'navigate');
      await hangUp(t);
      expect(sent, isEmpty);
    });

    testWidgets('two turns of only navigating and reading send nothing', (
      t,
    ) async {
      await fixture(t, tools: tools);
      await say(t, '去动态');
      await call(t, 'navigate');
      await say(t, '有什么要我处理的');
      await call(t, 'get_briefing');
      await hangUp(t);
      expect(sent, isEmpty);
    });

    testWidgets('a session with a decision sends one, as from the orb', (
      t,
    ) async {
      await fixture(t, tools: tools);
      await say(t, '去动态');
      await call(t, 'navigate');
      await say(t, '批准第 10 步');
      await call(t, 'approve_step');
      await hangUp(t);
      expect(sent, hasLength(1));
      expect(sent.single.$1, 'Cody');
      expect(sent.single.$2, '【语音对话摘要 · 来自 Agent 悬浮球】');
      expect(sent.single.$3, 2);
      expect(sent.single.$4, ['navigate', 'approve_step']);
    });

    testWidgets('with write-back off nothing is sent', (t) async {
      await fixture(t, tools: tools);
      AgentVoiceSettings.instance.writeBack = false;
      await say(t, '去动态');
      await say(t, '批准第 10 步');
      await call(t, 'approve_step');
      await hangUp(t);
      expect(sent, isEmpty);
      AgentVoiceSettings.instance.writeBack = true;
    });
  });
}
