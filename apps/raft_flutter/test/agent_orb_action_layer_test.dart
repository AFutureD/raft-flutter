import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';

import 'agent_orb_briefing_cards_test.dart' show briefing, needsYou;
import 'agent_orb_driving_test.dart' show replyItem;
import 'support/orb_action_world.dart';

/// The confirm card in the orb's layer: who, where and the exact words, with
/// big 确认 / 取消 buttons. Nothing is written until the person presses one or
/// says it; afterwards the layer says it is done, or the error. While driving
/// the card is the only card, and what must wait for parking says so.
void main() {
  late ActionOrbFixture f;

  /// A test over the fixture; the orb goes first, then its workspace.
  void orbTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (t) async {
      f = ActionOrbFixture(t);
      await f.setUp();
      await f.pump();
      await t.pump(const Duration(milliseconds: 300));
      await body(t);
      await t.pumpWidget(const SizedBox());
      await f.tearDown();
    });
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
    await t.pump(const Duration(milliseconds: 500));
  }

  Future<Map<String, Object?>> call(
    WidgetTester t,
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final done = f.controller.dispatch(name, args);
    var finished = false;
    unawaited(done.whenComplete(() => finished = true));
    for (var i = 0; i < 60 && !finished; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await settle(t);
    return done;
  }

  final card = find.byKey(const ValueKey('orb-confirm-card'));
  final yes = find.byKey(const ValueKey('orb-confirm-yes'));
  final no = find.byKey(const ValueKey('orb-confirm-cancel'));
  final outcome = find.byKey(const ValueKey('orb-action-outcome'));
  final drivingCard = find.byKey(const ValueKey('orb-driving-card'));

  const reply = {'channel': 'general', 'text': '可以合'};

  Future<void> inCall(WidgetTester t) async {
    await f.startCall();
  }

  group('the card', () {
    orbTest('shows who, where and the exact words, and writes nothing', (
      t,
    ) async {
      await inCall(t);
      await f.openLayerInCall();
      final r = await call(t, 'send_message', reply);
      expect(r['status'], 'needs_confirmation');
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('发到')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('#general')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('可以合')),
        findsOneWidget,
      );
      expect(yes, findsOneWidget);
      expect(no, findsOneWidget);
      expect(find.text('确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(f.world.sent, isEmpty);
    });

    orbTest('the buttons are big', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      expect(t.getSize(yes).height, greaterThanOrEqualTo(64));
      expect(t.getSize(no).height, greaterThanOrEqualTo(64));
      expect(t.getSize(yes).width, greaterThan(120));
    });

    orbTest('a request while the layer is closed opens it', (t) async {
      await inCall(t);
      expect(f.controller.layerOpen, isFalse);
      await call(t, 'send_message', reply);
      expect(f.controller.layerOpen, isTrue);
      expect(card, findsOneWidget);
    });

    orbTest('each action is on the card: reply, react, task, hand over, '
        'nudge', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      final asks = <(String, Map<String, Object?>, String)>[
        ('reply_in_thread', {'message': 'm-1', 'text': '可以'}, 'Cody'),
        ('react', {'message': 'm-1', 'emoji': '👍'}, '👍'),
        ('set_task_status', {'task': '12', 'status': 'done'}, '已完成'),
        ('assign_task', {'task': '12', 'assignee': 'Ada'}, 'Ada'),
        ('nudge_task', {'task': '12'}, 'Cody'),
      ];
      for (final (tool, args, shown) in asks) {
        await call(t, tool, args);
        expect(card, findsOneWidget, reason: tool);
        expect(
          find.descendant(of: card, matching: find.textContaining(shown)),
          findsWidgets,
          reason: tool,
        );
      }
      expect(f.world.sent, isEmpty);
      expect(f.world.commands, isEmpty);
      expect(f.world.toggles, isEmpty);
    });
  });

  group('pressing the buttons', () {
    orbTest('确认 writes once, the layer says done and the model is told', (
      t,
    ) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      await t.tap(yes);
      await settle(t);
      expect(f.world.sent, hasLength(1));
      expect(f.world.sent.single.text, '可以合');
      expect(card, findsNothing);
      expect(
        find.descendant(of: outcome, matching: find.text('已发送')),
        findsOneWidget,
      );
      final told = f.sessions.single.sentTexts;
      expect(told, hasLength(1));
      expect(told.single, contains('用户点了确认'));
      // The model then relaying the same confirm writes nothing more.
      final again = await call(t, 'confirm');
      expect(f.world.sent, hasLength(1));
      expect(again['already'], isTrue);
    });

    orbTest('取消 writes nothing, the layer says so and the model is '
        'told', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      await t.tap(no);
      await settle(t);
      expect(f.world.sent, isEmpty);
      expect(card, findsNothing);
      expect(
        find.descendant(of: outcome, matching: find.text('已取消')),
        findsOneWidget,
      );
      expect(f.sessions.single.sentTexts.single, contains('取消'));
      await call(t, 'confirm');
      expect(f.world.sent, isEmpty);
    });

    orbTest('a failed write shows the reason, not "done"', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      f.world.sendAccepted = false;
      await call(t, 'send_message', reply);
      await t.tap(yes);
      await settle(t);
      expect(f.world.sent, hasLength(1), reason: 'the attempt');
      expect(find.text('已发送'), findsNothing);
      expect(outcome, findsOneWidget);
      expect(f.sessions.single.sentTexts.single, contains('没有成功'));
    });

    orbTest('the result goes after a few seconds', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      await t.tap(yes);
      await settle(t);
      expect(outcome, findsOneWidget);
      await t.pump(const Duration(seconds: 9));
      expect(outcome, findsNothing);
    });
  });

  group('saying it', () {
    orbTest('spoken yes, then the model relays it: written once', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      // Without a word from the person the model's confirm does nothing.
      final early = await call(t, 'confirm');
      expect(early['error'], 'needs_user_confirmation');
      expect(f.world.sent, isEmpty);
      expect(card, findsOneWidget);

      f.sessions.single.onInputText!('发吧');
      await t.pump();
      final done = await call(t, 'confirm');
      expect(done['status'], 'done');
      expect(f.world.sent, hasLength(1));
      expect(card, findsNothing);
      expect(
        find.descendant(of: outcome, matching: find.text('已发送')),
        findsOneWidget,
      );
      await call(t, 'confirm');
      expect(f.world.sent, hasLength(1));
    });

    orbTest('typed 确认 counts the same', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      await t.enterText(find.byKey(const ValueKey('orb-input')), '确认');
      await t.tap(find.byKey(const ValueKey('orb-send')));
      await settle(t);
      await call(t, 'confirm');
      expect(f.world.sent, hasLength(1));
    });

    orbTest('spoken no takes the card down and writes nothing', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', reply);
      f.sessions.single.onInputText!('算了，不发了');
      await t.pump();
      expect(card, findsNothing);
      await call(t, 'confirm');
      expect(f.world.sent, isEmpty);
    });
  });

  group('a sensitive operation', () {
    orbTest('is confirmed twice, by the buttons, and the card says which '
        'press it is', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      final r = await call(t, 'act', {
        'capability': 'agents.stop',
        'args': {'agent': 'Cody'},
      });
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect(find.textContaining('敏感操作'), findsOneWidget);
      expect(find.textContaining('第 1/2 次'), findsOneWidget);
      // Words do not count, so no "heard you" mark either.
      f.sessions.single.onInputText!('确认');
      await t.pump();
      expect(find.byKey(const ValueKey('orb-confirm-heard')), findsNothing);
      await t.tap(yes);
      await settle(t);
      expect(f.world.commands, isEmpty);
      expect(find.textContaining('第 2/2 次'), findsOneWidget);
      expect(f.sessions.single.sentTexts.last, contains('再点一次'));
      await t.tap(yes);
      await settle(t);
      expect(f.world.commands.single.$2, '/agents/a-cody/stop');
      expect(card, findsNothing);
    });

    orbTest('is not done while driving', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'set_driving_mode', {'on': true});
      final r = await call(t, 'act', {
        'capability': 'agents.stop',
        'args': {'agent': 'Cody'},
      });
      expect(r['refused'], isTrue);
      expect(card, findsNothing);
      expect(find.textContaining('停车后再做'), findsWidgets);
    });
  });

  group('one at a time', () {
    orbTest('a new request replaces the card', (t) async {
      await inCall(t);
      await f.openLayerInCall();
      await call(t, 'send_message', {'channel': 'general', 'text': '第一句'});
      await call(t, 'send_message', {'channel': 'general', 'text': '第二句'});
      expect(card, findsOneWidget);
      expect(find.text('第一句'), findsNothing);
      expect(find.text('第二句'), findsOneWidget);
      await t.tap(yes);
      await settle(t);
      expect(f.world.sent.map((s) => s.text), ['第二句']);
    });
  });

  group('while driving', () {
    Future<void> drive(WidgetTester t) async {
      await inCall(t);
      f.controller.showBriefing(
        briefing(needs: [needsYou(), replyItem('Alice 问你周五有没有空')]),
      );
      await settle(t);
      await call(t, 'set_driving_mode', {'on': true});
    }

    orbTest('the card is the one big card: it takes the place of the '
        'driving card', (t) async {
      await drive(t);
      expect(drivingCard, findsOneWidget);
      await call(t, 'send_message', reply);
      expect(card, findsOneWidget);
      expect(drivingCard, findsNothing);
      expect(find.byKey(const ValueKey('orb-driving-next')), findsNothing);
      expect(t.getSize(yes).height, greaterThanOrEqualTo(64));
      expect(f.world.sent, isEmpty);
      // Confirming brings the driving card back, under the result.
      await t.tap(yes);
      await settle(t);
      expect(f.world.sent, hasLength(1));
      expect(card, findsNothing);
      expect(drivingCard, findsOneWidget);
      expect(
        find.descendant(of: outcome, matching: find.text('已发送')),
        findsOneWidget,
      );
    });

    orbTest('marking a task done is refused, and the layer says park '
        'first', (t) async {
      await drive(t);
      final r = await call(t, 'set_task_status', {
        'task': '12',
        'status': 'done',
      });
      expect(r['refused'], isTrue);
      expect(r['error'], '停车后再做');
      expect(card, findsNothing);
      expect(drivingCard, findsOneWidget);
      expect(
        find.descendant(of: outcome, matching: find.textContaining('停车后再做')),
        findsOneWidget,
      );
      expect(f.world.commands, isEmpty);
    });

    orbTest('a reply is fine while driving; leaving driving allows the '
        'task change', (t) async {
      await drive(t);
      await call(t, 'set_driving_mode', {'on': false});
      final r = await call(t, 'set_task_status', {
        'task': '12',
        'status': 'done',
      });
      expect(r['status'], 'needs_confirmation');
      expect(card, findsOneWidget);
    });
  });

  group('what the model is given', () {
    orbTest('the reads, the actions and confirm are tools', (t) async {
      await inCall(t);
      final names = [for (final d in f.sessions.single.tools) d['name']];
      expect(
        names,
        containsAll([
          'list_tasks',
          'task_detail',
          'send_message',
          'reply_in_thread',
          'react',
          'set_task_status',
          'assign_task',
          'snooze_item',
          'nudge_task',
          'confirm',
          'cancel_action',
        ]),
      );
    });

    orbTest('the prompt has the 【动作】 rules', (t) async {
      await inCall(t);
      final prompt = f.sessions.single.systemPrompt;
      expect(prompt, contains('【动作】'));
      expect(prompt, contains('复述'));
      expect(prompt, contains('confirm'));
      expect(prompt, contains('find'));
      expect(prompt, contains('停车后再做'));
    });

    test('the prompt says the same without a session', () {
      final prompt = orbSystemPrompt(channels: '');
      expect(prompt, contains('【动作】'));
    });

    orbTest('a task read goes through the orb and has no id', (t) async {
      final r = await call(t, 'list_tasks', {'status': 'in_review'});
      expect(r['total'], 1);
      expect(r.toString(), isNot(contains('t4')));
      expect(r.toString(), isNot(contains('ch-general')));
    });
  });
}
