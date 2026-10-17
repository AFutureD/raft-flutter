import 'dart:async';

import 'package:flutter/widgets.dart' show SizedBox;

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_action_prompt.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_tools.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';
import 'package:raft_flutter/features/agent_orb/orb_scope.dart';
import 'package:raft_flutter/features/agent_orb/screen/orb_screen_prompt.dart';

import 'support/orb_action_world.dart';

/// The text agent's three states: the instruction and the tools each one gets,
/// and that the orb picks the state from what is going on.

List<Map<String, Object?>> _declared(Iterable<String> names) => [
  for (final n in names) {'name': n},
];

Set<String> _names(
  OrbMode mode, {
  bool driving = false,
  required Iterable<String> all,
}) => {
  for (final d in orbAgentScope(
    mode: mode,
    driving: driving,
    declarations: _declared(all),
    channels: '',
  ).tools)
    '${d['name']}',
};

void main() {
  late ActionOrbFixture f;

  group('the prompt in sections', () {
    test('the realtime prompt is every section, in order', () {
      final full = orbSystemPrompt(channels: 'a [1]', style: '短一点');
      var at = 0;
      for (final section in [
        orbPromptIdentity,
        orbPromptPersona,
        orbPromptSpeaking,
        orbPromptInApp,
        orbPromptProactive,
        orbPromptFacts,
        orbPromptOperating,
        orbPromptDrivingEnter,
        orbPromptDrivingRules,
        orbActionBasics,
        orbActionConfirm,
        orbActionDriving,
        orbScreenPrompt,
        orbPromptListening,
        '【这次的偏好】短一点',
        'a [1]',
      ]) {
        final i = full.indexOf(section, at);
        expect(i, greaterThanOrEqualTo(at), reason: section.split('\n').first);
        at = i + section.length;
      }
      expect(
        orbActionPrompt,
        '$orbActionBasics$orbActionConfirm$orbActionDriving',
      );
    });

    String prompt(OrbMode mode, {bool driving = false, String? pending}) =>
        orbAgentPrompt(
          mode: mode,
          driving: driving,
          channels: 'a [1]',
          style: '短一点',
          memory: '【记忆】x',
          pending: pending,
        );

    test('each state has the sections it needs and not the others', () {
      final normal = prompt(OrbMode.normal);
      expect(normal, contains(orbPromptProactive));
      expect(normal, contains(orbPromptDiscussionAgent));
      expect(normal, contains(orbScreenPrompt));
      expect(normal, contains(orbActionConfirmAgent));
      expect(normal, isNot(contains(orbPromptDrivingRules)));
      expect(normal, isNot(contains(orbActionConfirm)));

      final driving = prompt(OrbMode.driving, driving: true);
      expect(driving, contains(orbPromptDrivingRules));
      expect(driving, contains(orbActionDriving));
      expect(driving, isNot(contains(orbPromptProactive)));
      expect(driving, isNot(contains(orbPromptDiscussionAgent)));
      expect(driving, isNot(contains(orbScreenPrompt)));

      final confirming = prompt(
        OrbMode.confirming,
        pending: '回复 Cody 的消息：“可以”',
      );
      expect(confirming, contains('【等着确认】'));
      expect(confirming, contains('回复 Cody 的消息：“可以”'));
      expect(confirming, isNot(contains(orbPromptProactive)));
      expect(confirming, isNot(contains(orbScreenPrompt)));
      expect(confirming, isNot(contains(orbActionDriving)));
      expect(
        prompt(OrbMode.confirming, driving: true, pending: 'x'),
        contains(orbActionDriving),
      );
      // Every state keeps the person, the memory and the channels.
      for (final p in [normal, driving, confirming]) {
        expect(p, contains(orbPromptPersona));
        expect(p, contains('【记忆】x'));
        expect(p, contains('【这次的偏好】短一点'));
        expect(p, contains('a [1]'));
      }
    });
  });

  group('the tools of a state', () {
    final all = orbToolModes.keys.toList();

    test('a card waiting wins over driving mode', () {
      expect(orbModeOf(pending: true, driving: true), OrbMode.confirming);
      expect(orbModeOf(pending: false, driving: true), OrbMode.driving);
      expect(orbModeOf(pending: false, driving: false), OrbMode.normal);
    });

    test('normal: the app, without the card and driving tools', () {
      final n = _names(OrbMode.normal, all: all);
      expect(n, containsAll(['navigate', 'screen_action', 'reply', 'undo']));
      expect(n, containsAll(['set_driving_mode', 'describe_page', 'find']));
      expect(n, isNot(contains('confirm')));
      expect(n, isNot(contains('cancel_action')));
      expect(n, isNot(contains('driving_next')));
    });

    test('driving: reads, driving tools and the low-risk actions only', () {
      final d = _names(OrbMode.driving, driving: true, all: all);
      expect(
        d,
        containsAll([
          'driving_next',
          'set_driving_mode',
          'navigate',
          'list_tasks',
          'reply',
          'react',
          'snooze_item',
          'assign_task',
          'nudge_task',
        ]),
      );
      for (final risky in [
        'set_task_status',
        'act',
        'create_task',
        'join_channel',
        'reject_task',
        'screen_action',
        'hide_orb_sheet',
        'confirm',
      ]) {
        expect(d, isNot(contains(risky)), reason: risky);
      }
    });

    test('confirming: answer the card, read, or change the ask', () {
      final c = _names(OrbMode.confirming, all: all);
      expect(c, containsAll(['confirm', 'cancel_action', 'describe_page']));
      expect(c, containsAll(['reply', 'set_task_status']));
      expect(c, isNot(contains('navigate')));
      expect(c, isNot(contains('screen_action')));
      expect(c, isNot(contains('driving_next')));
      // Driving while a card waits: the asks are the low-risk ones again.
      final cd = _names(OrbMode.confirming, driving: true, all: all);
      expect(cd, containsAll(['confirm', 'cancel_action', 'reply']));
      expect(cd, isNot(contains('set_task_status')));
    });

    test(
      'the text agent answers people with reply, not the two it replaces',
      () {
        for (final mode in OrbMode.values) {
          final n = _names(
            mode,
            driving: mode == OrbMode.driving,
            all: [...all, 'reply'],
          );
          expect(n, contains('reply'), reason: '$mode');
          expect(n, isNot(contains('send_message')), reason: '$mode');
          expect(n, isNot(contains('reply_in_thread')), reason: '$mode');
        }
      },
    );

    test('a tool the table does not know is given in every state', () {
      for (final mode in OrbMode.values) {
        expect(
          _names(
            mode,
            all: ['brand_new_tool'],
            driving: mode == OrbMode.driving,
          ),
          {'brand_new_tool'},
        );
      }
    });
  });

  group('the orb', () {
    Future<void> orbTest(
      String name,
      Future<void> Function(WidgetTester t) body, {
      bool agentLayer = true,
    }) async {
      testWidgets(name, (t) async {
        f = ActionOrbFixture(t)..agentLayer = agentLayer;
        await f.setUp();
        await f.pump(tools: [...orbNavigationTools(), ...orbBriefingTools()]);
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
      return done;
    }

    orbTest(
      'every tool of the orb is in a state, and each state is reachable',
      (t) async {
        final names = f.controller.tools.keys.toSet();
        expect(names, contains('reply'));
        for (final n in names) {
          expect(
            orbToolModes,
            contains(n),
            reason: '$n has no place in orbToolModes',
          );
        }
        // The two that `reply` replaces are the realtime model's.
        for (final n in names.difference(orbAgentReplaced)) {
          final reachable = [
            for (final mode in OrbMode.values)
              if (orbToolIn(n, mode, driving: mode == OrbMode.driving)) mode,
          ];
          expect(reachable, isNotEmpty, reason: '$n is in no state');
        }
        // And nothing in the table is a tool that no longer exists.
        expect(names, containsAll(orbToolModes.keys));
      },
    );

    orbTest('the session of the agent layer follows the state', (t) async {
      await f.startCall();
      final steering = f.sessions.single.steering!;
      Set<String> tools() => {
        for (final d in steering.scope().tools) '${d['name']}',
      };

      expect(tools(), contains('screen_action'));
      expect(steering.scope().systemPrompt, contains('【屏幕】'));

      // A card waits: the confirming state, with what it will do.
      final asked = await call(t, 'reply', {'to': '#general', 'text': '可以合'});
      expect(asked['status'], 'needs_confirmation');
      expect(tools(), containsAll(['confirm', 'cancel_action']));
      expect(tools(), isNot(contains('navigate')));
      expect(steering.scope().systemPrompt, contains('【等着确认】'));
      expect(steering.scope().systemPrompt, contains('可以合'));

      // Dropped: back to normal, in the same turn.
      await call(t, 'cancel_action');
      expect(tools(), contains('navigate'));
      expect(tools(), isNot(contains('confirm')));

      await f.controller.setDriving(true);
      await t.pump();
      expect(tools(), contains('driving_next'));
      expect(tools(), isNot(contains('set_task_status')));
      expect(steering.scope().systemPrompt, contains('驾驶中：每次只说一件'));
    });

    orbTest('the realtime session is not steered and has every tool', (
      t,
    ) async {
      await f.startCall();
      final s = f.sessions.single;
      expect(s.steering, isNull);
      expect(s.systemPrompt, contains('【主动】'));
      expect(s.systemPrompt, contains('驾驶中：每次只说一件'));
      expect(s.systemPrompt, contains('【屏幕】'));
      expect({
        for (final d in s.tools) '${d['name']}',
      }, f.controller.tools.keys.toSet());
    }, agentLayer: false);
  });
}
