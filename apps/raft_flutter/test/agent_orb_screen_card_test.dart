import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen.dart';

import 'support/orb_action_world.dart';

/// A press on the screen whose name has consequences goes through the orb's
/// own confirm card (the capability layer's pending action): the card says
/// what will be pressed, and nothing is pressed until the person agrees.
void main() {
  late ActionOrbFixture f;
  var sent = 0;

  void orbTest(String name, Future<void> Function(WidgetTester t) body) {
    testWidgets(name, (t) async {
      sent = 0;
      f = ActionOrbFixture(t);
      await f.setUp();
      await f.pump();
      await t.pump(const Duration(milliseconds: 300));
      await body(t);
      await t.pumpWidget(const SizedBox());
      await f.tearDown();
    });
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
    await t.pump(const Duration(milliseconds: 500));
    return done;
  }

  /// A dialog with a button that sends, read the way a tool reads it.
  Future<String> sendButton(WidgetTester t) async {
    unawaited(
      showDialog<void>(
        context: f.navKey.currentState!.overlay!.context,
        builder: (_) => AlertDialog(
          title: const Text('回复 Cody'),
          actions: [
            TextButton(onPressed: () => sent++, child: const Text('发送')),
          ],
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 500));
    Map<String, Object?>? seen;
    unawaited(
      OrbScreen.of(f.w)
          .contract(f.navKey.currentState!.overlay!.context)
          .then((v) => seen = v),
    );
    for (var i = 0; i < 20 && seen == null; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    final actions = (seen!['actions']! as List).cast<Map>();
    return actions.firstWhere((a) => '${a['label']}' == '发送')['id']! as String;
  }

  final card = find.byKey(const ValueKey('orb-confirm-card'));
  final yes = find.byKey(const ValueKey('orb-confirm-yes'));
  final no = find.byKey(const ValueKey('orb-confirm-cancel'));

  group('screen_action on a risky control', () {
    orbTest('shows the card first; the button is pressed when agreed', (
      t,
    ) async {
      await f.startCall();
      final id = await sendButton(t);
      final r = await call(t, 'screen_action', {'id': id, 'action': 'tap'});
      expect(r['status'], 'needs_confirmation', reason: '$r');
      expect('${(r['preview'] as Map)['summary']}', contains('发送'));
      expect(sent, 0);
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.textContaining('发送')),
        findsWidgets,
      );

      await t.tap(yes);
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(sent, 1, reason: 'the page behind the layer got the press');
      expect(f.actions!.pending, isNull);
    });

    orbTest('cancel presses nothing', (t) async {
      await f.startCall();
      final id = await sendButton(t);
      await call(t, 'screen_action', {'id': id, 'action': 'tap'});
      expect(card, findsOneWidget);
      await t.tap(no);
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(sent, 0);
    });

    orbTest('the model\'s confirm after the person said yes presses it', (
      t,
    ) async {
      await f.startCall();
      final id = await sendButton(t);
      await call(t, 'screen_action', {'id': id, 'action': 'tap'});
      // The model\'s own say-so is not agreement.
      final blind = await call(t, 'confirm');
      expect(blind['error'], 'needs_user_confirmation');
      expect(sent, 0);
      f.sessions.single.onInputText!('发吧');
      await t.pump(const Duration(milliseconds: 100));
      final done = await call(t, 'confirm');
      expect(done['status'], 'done', reason: '$done');
      expect(sent, 1);
    });

    orbTest('while driving it waits for parking', (t) async {
      await f.startCall();
      final id = await sendButton(t);
      await f.controller.setDriving(true);
      await t.pump(const Duration(milliseconds: 400));
      final r = await call(t, 'screen_action', {'id': id, 'action': 'tap'});
      expect(r['refused'], isTrue, reason: '$r');
      expect(sent, 0);
    });
  });
}
