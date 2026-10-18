import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// The orb's conversation with the model: text turns, tools dispatched
/// through the registry, and the voice gestures (long-press talks, a tap hangs
/// up while connecting, live or speaking).

OrbTool fakeTool(
  String name,
  Future<Map<String, Object?>> Function(
    Map<String, Object?> args,
    OrbToolContext ctx,
  )
  handler,
) => OrbTool(
  declaration: {
    'name': name,
    'description': '测试工具',
    'parameters': {
      'type': 'object',
      'properties': {
        'target': {'type': 'string'},
      },
    },
  },
  handler: handler,
);

void main() {
  late OrbFixture f;

  Future<void> fixture(
    WidgetTester t, {
    List<OrbTool> tools = const [],
    String? apiKey = 'test-key',
  }) async {
    f = OrbFixture(t)..apiKey = apiKey;
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump(tools: tools);
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> openLayer(WidgetTester t) => f.openLayer();

  /// Shows (or hides again) what was said and done: the layer keeps it
  /// behind 对话记录.
  Future<void> toggleHistory(WidgetTester t) async {
    await t.tap(find.byKey(const ValueKey('orb-layer-history')));
    await t.pump();
  }

  Future<void> settleSession(WidgetTester t) async {
    for (var i = 0; i < 4; i++) {
      await t.pump();
    }
  }

  Future<void> connected(WidgetTester t) async {
    f.sessions.last.connectGate.complete();
    await settleSession(t);
  }

  group('where the person is', () {
    testWidgets('in a call a move tells the model the new page, once, '
        'without asking it to answer', (t) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await settleSession(t);
      await connected(t);
      final s = f.sessions.single;
      final before = s.contexts.length;
      f.w.setSection('tasks');
      await t.pump(const Duration(milliseconds: 600));
      // The same place again says nothing new.
      f.w.notifyListeners();
      await t.pump(const Duration(milliseconds: 600));
      expect(s.contexts.length, before + 1);
      expect(s.contexts.last, contains('任务'));
      expect(s.sentTexts, isEmpty, reason: 'no turn is asked for');
    });
  });

  group('text turns', () {
    testWidgets('typed text goes to the model and the reply shows', (t) async {
      await fixture(t);
      await openLayer(t);
      expect(find.text('说点什么，或者长按球直接对话'), findsOneWidget);

      await t.enterText(find.byKey(const ValueKey('orb-input')), '看看动态里什么要我处理');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      // The input is cleared and the person's turn is in the transcript.
      await toggleHistory(t);
      expect(find.text('看看动态里什么要我处理'), findsOneWidget);
      await toggleHistory(t);
      await connected(t);
      expect(f.sessions, hasLength(1));
      expect(f.sessions.single.sentTexts, ['看看动态里什么要我处理']);
      // Where the person is goes along, silently (eval C5: in a discussion
      // "大家意见是什么" went to the Activity, the model did not know).
      expect(f.sessions.single.contexts, hasLength(1));
      expect(f.sessions.single.contexts.single, contains('用户现在在'));

      f.sessions.single.onOutputText!('Cody 在等你批准第 10 步。');
      await t.pump();
      expect(find.text('Cody 在等你批准第 10 步。'), findsOneWidget);
      // The reply streams in chunks into one line.
      f.sessions.single.onOutputText!('要我回复吗？');
      await t.pump();
      expect(find.text('Cody 在等你批准第 10 步。要我回复吗？'), findsOneWidget);
      f.sessions.single.onTurnComplete!();
      await t.pump();
    });

    // Eval A3/C4 on the G100: the model asked "要发吗？" without calling the
    // action tool; no card was up, so the user's "确认" could not send and
    // they had to confirm twice. The app tells the model to put the card up.
    testWidgets('asking to confirm with no card up makes the app tell the '
        'model, once per turn of the person', (t) async {
      await fixture(t);
      await openLayer(t);
      await t.enterText(find.byKey(const ValueKey('orb-input')), '回复他说可以合');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      await connected(t);
      final s = f.sessions.single;
      s.onOutputText!('你要回复 Cody：可以合。要发吗？');
      s.onTurnComplete!();
      await t.pump();
      expect(s.sentTexts.where((x) => x.contains('确认卡')), hasLength(1));
      // The same turn of the person: not again.
      s.onOutputText!('要发吗？');
      s.onTurnComplete!();
      await t.pump();
      expect(s.sentTexts.where((x) => x.contains('确认卡')), hasLength(1));
    });

    testWidgets('an answer that asks nothing is left alone', (t) async {
      await fixture(t);
      await openLayer(t);
      await t.enterText(find.byKey(const ValueKey('orb-input')), '读一下动态');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      await connected(t);
      final s = f.sessions.single;
      s.onOutputText!('Alice 问你周五能不能来评审。');
      s.onTurnComplete!();
      await t.pump();
      expect(s.sentTexts, ['读一下动态']);
    });

    testWidgets('the session knows the tools, the persona and the channels', (
      t,
    ) async {
      await fixture(
        t,
        tools: [
          fakeTool('fake_open', (a, c) async => {'ok': true}),
        ],
      );
      await openLayer(t);
      await t.enterText(find.byKey(const ValueKey('orb-input')), '你好');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      await connected(t);
      final s = f.sessions.single;
      final names = [for (final d in s.tools) d['name']];
      expect(names, containsAll(['orb_layer', 'fake_open']));
      expect(s.systemPrompt, contains('raft-flutter'));
      expect(s.systemPrompt, contains('没听清'));
      expect(s.systemPrompt, contains('loading'));
    });
  });

  group('without a voice key', () {
    testWidgets('typed text says there is no key and sends nothing', (t) async {
      await fixture(t, apiKey: null);
      await openLayer(t);
      await t.enterText(find.byKey(const ValueKey('orb-input')), '你好');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      expect(f.sessions, isEmpty);
      // The note stays on the layer; the person's words are in the record.
      expect(find.textContaining('还没有语音 Key'), findsOneWidget);
      await toggleHistory(t);
      expect(find.text('你好'), findsOneWidget);
    });

    testWidgets('a long-press opens the layer with the same note', (t) async {
      await fixture(t, apiKey: null);
      await t.longPress(OrbFixture.orbFinder);
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(f.sessions, isEmpty);
      expect(f.controller.layerOpen, isTrue);
      expect(find.textContaining('还没有语音 Key'), findsOneWidget);
    });
  });

  group('tools', () {
    testWidgets('a tool call dispatches to the registry and the result goes '
        'back; the activity line shows', (t) async {
      OrbToolContext? seen;
      Map<String, Object?>? seenArgs;
      await fixture(
        t,
        tools: [
          fakeTool('fake_open', (args, ctx) async {
            seen = ctx;
            seenArgs = args;
            return {
              'route': '/c/c1',
              'title': '#raft-flutter',
              'activity': '已打开 #raft-flutter',
            };
          }),
        ],
      );
      await openLayer(t);
      await t.enterText(
        find.byKey(const ValueKey('orb-input')),
        '去 raft-flutter',
      );
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settleSession(t);
      await connected(t);

      late Map<String, Object?> result;
      unawaited(
        f.sessions.single
            .onToolCall('fake_open', {'target': 'raft-flutter'})
            .then((r) => result = r),
      );
      await settleSession(t);
      expect(seenArgs, {'target': 'raft-flutter'});
      expect(seen!.workspace, same(f.w));
      expect(seen!.operating, same(f.controller.operating));
      expect(seen!.navigatorContext.mounted, isTrue);
      expect(result['title'], '#raft-flutter');
      await toggleHistory(t);
      expect(find.text('已打开 #raft-flutter'), findsOneWidget);
    });

    testWidgets('an unknown tool and a throwing tool answer with an error', (
      t,
    ) async {
      await fixture(
        t,
        tools: [fakeTool('boom', (a, c) async => throw StateError('x'))],
      );
      expect(
        await f.controller.dispatch('nope', const {}),
        containsPair('error', isA<String>()),
      );
      expect(
        await f.controller.dispatch('boom', const {}),
        containsPair('error', isA<String>()),
      );
    });

    testWidgets('orb_layer opens and closes the layer', (t) async {
      await fixture(t);
      expect(f.controller.layerOpen, isFalse);
      final shown = f.controller.dispatch('orb_layer', const {'open': true});
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect((await shown)['ok'], isTrue);
      expect(f.controller.layerOpen, isTrue);
      final hidden = f.controller.dispatch('orb_layer', const {'open': false});
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect((await hidden)['ok'], isTrue);
      expect(f.controller.layerOpen, isFalse);
      expect(find.byKey(const ValueKey('orb-layer')), findsNothing);
    });

    testWidgets('a touch on the page cancels the tool in flight', (t) async {
      final gate = Completer<void>();
      var sawCancel = false;
      await fixture(
        t,
        tools: [
          fakeTool('fake_nav', (args, ctx) async {
            ctx.operating.value = true;
            await gate.future;
            sawCancel = !ctx.operating.value;
            return sawCancel ? {'cancelled': true} : {'ok': true};
          }),
        ],
      );
      final call = f.controller.dispatch('fake_nav', {'target': '动态'});
      await t.pump();
      expect(f.controller.operating.value, isTrue);
      // The default pill label comes from the tool call's own words.
      expect(find.text('打开了 动态'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('page-content')));
      await t.pump();
      gate.complete();
      expect(await call, {'cancelled': true});
      expect(sawCancel, isTrue);
    });
  });

  group('voice gestures', () {
    testWidgets('a long-press starts a live voice session', (t) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.sessions, hasLength(1));
      expect(f.controller.voice.state, AgentMicState.connecting);
      expect(f.audio.micStarts, 1);
      expect(f.warmed, [f.w], reason: 'briefed while the call connects');
      // The layer did not open: a long-press talks.
      expect(f.controller.layerOpen, isFalse);
      await connected(t);
      expect(f.controller.voice.state, AgentMicState.live);
    });

    testWidgets('a tap hangs up while connecting', (t) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.controller.voice.state, AgentMicState.connecting);
      await t.tap(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.controller.voice.state, AgentMicState.idle);
      expect(f.sessions.single.closes, 1);
      expect(f.audio.micStops, f.audio.micStarts);
      expect(f.controller.layerOpen, isFalse);
      // The connection in flight finishes late and must not revive.
      await connected(t);
      expect(f.controller.voice.state, AgentMicState.idle);
    });

    testWidgets('a tap hangs up while live', (t) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await connected(t);
      expect(f.controller.voice.state, AgentMicState.live);
      await t.tap(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.controller.voice.state, AgentMicState.idle);
      expect(f.sessions.single.closes, 1);
      expect(f.controller.layerOpen, isFalse);
    });

    testWidgets('a tap hangs up while the model speaks', (t) async {
      await fixture(t);
      await t.longPress(OrbFixture.orbFinder);
      await connected(t);
      f.sessions.single.onAudio!(Uint8List(8));
      await t.pump();
      expect(f.controller.state.name, 'speaking');
      await t.tap(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.controller.voice.state, AgentMicState.idle);
      expect(f.controller.state.name, 'idle');
      expect(f.sessions.single.closes, 1);
      expect(f.controller.layerOpen, isFalse);
    });

    testWidgets('the same taps hang up from the docked orb in the layer', (
      t,
    ) async {
      await fixture(t);
      await openLayer(t);
      await t.longPress(OrbFixture.orbFinder);
      await connected(t);
      expect(f.controller.voice.state, AgentMicState.live);
      await t.tap(OrbFixture.orbFinder);
      await settleSession(t);
      expect(f.controller.voice.state, AgentMicState.idle);
      // The layer stays open: only the call ended.
      expect(f.controller.layerOpen, isTrue);
    });

    testWidgets('what the person says shows in the transcript', (t) async {
      await fixture(t);
      await openLayer(t);
      await t.longPress(OrbFixture.orbFinder);
      await connected(t);
      f.sessions.single.onInputText!('看看动态');
      f.sessions.single.onInputText!('里什么要我处理');
      await t.pump();
      await toggleHistory(t);
      expect(find.text('看看动态里什么要我处理'), findsOneWidget);
    });
  });
}
