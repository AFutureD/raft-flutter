import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/action_support.dart'
    show messageById;
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart'
    show AgentCapabilityError;
import 'package:raft_flutter/features/agent_orb/actions/orb_actions.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_reply.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_models.dart';
import 'package:raft_flutter/features/agent_orb/briefing/orb_briefing_service.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_data.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenario.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_scenarios.dart';
import 'package:raft_flutter/features/agent_orb/eval/orb_eval_world.dart';
import 'package:raft_flutter/features/agent_orb/nav/orb_nav_tools.dart';
import 'package:raft_flutter/features/agent_orb/orb_tool.dart';
import 'package:raft_flutter/features/workspace_view.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/app_services_fixture.dart';

/// "回复他说可以": the app finds the message. Over the evaluation's fixture
/// workspace, the way the scenarios have it.

OrbEvalScenario scenario(String id) =>
    orbEvalScenarios.firstWhere((s) => s.id == id);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a query names a discussion without the orb\'s thread: prefix', () {
    expect(
      OrbActions.orbQueryArgs({
        'capability': 'threads.messages',
        'args': '{"threadId":"thread:abc-1","limit":5}',
      }),
      {
        'capability': 'threads.messages',
        'args': '{"threadId":"abc-1","limit":5}',
      },
    );
    expect(
      OrbActions.orbQueryArgs({
        'capability': 'threads.messages',
        'args': {'threadId': 'thread:abc-1'},
      })['args'],
      {'threadId': 'abc-1'},
    );
    // Anything else is as it was.
    const other = {'capability': 'channels.list', 'args': '{"name":"x"}'};
    expect(OrbActions.orbQueryArgs(other), other);
    const broken = {'capability': 'x', 'args': '{nope'};
    expect(OrbActions.orbQueryArgs(broken), broken);
  });

  Future<List<OrbBriefItem>> activity(OrbEvalWorld world) async =>
      (await OrbBriefingService(
        world.workspace,
      ).brief(OrbBriefScope.activity, full: true, remember: false)).needsYou;

  test('the driving card is who "他" is: a reply to Cody\'s message, not a '
      'row id and not the first item', () async {
    final world = await OrbEvalWorld.create(scenario('D3').data());
    addTearDown(world.dispose);
    final items = await activity(world);
    expect(items.first.who, 'Cody');
    final plan = await orbResolveReply(
      world.workspace,
      OrbReplyContext(card: items.first, needsYou: () async => items),
      text: '可以',
    );
    expect(plan.tool, 'reply_in_thread');
    expect(plan.args['text'], '可以');
    final m = await messageById(world.workspace, '${plan.args['message']}');
    expect(m.author, 'Cody');
    expect(m.content, contains('第 10 步可以合入吗'));
  });

  test('a card that is a private conversation is answered in it', () async {
    final world = await OrbEvalWorld.create(scenario('D2').data());
    addTearDown(world.dispose);
    final items = await activity(world);
    final alice = items.firstWhere((i) => i.who == 'Alice');
    final plan = await orbResolveReply(
      world.workspace,
      OrbReplyContext(card: alice, needsYou: () async => items),
      text: '能来',
    );
    expect(plan.tool, 'send_message');
    expect(
      world.workspace.dms
          .firstWhere((c) => c.id == plan.args['channel'])
          .peerLabel,
      'Alice',
    );
  });

  test('a name picks that person among what needs the user; no card, no page, '
      'no name: the first thing that needs them', () async {
    final world = await OrbEvalWorld.create(scenario('D3').data());
    addTearDown(world.dispose);
    final items = await activity(world);
    final ctx = OrbReplyContext(needsYou: () async => items);
    final grok = await orbResolveReply(
      world.workspace,
      ctx,
      to: 'Grok',
      text: '看过了',
    );
    expect(grok.tool, 'reply_in_thread');
    expect(
      (await messageById(world.workspace, '${grok.args['message']}')).author,
      'Grok',
    );
    final first = await orbResolveReply(
      world.workspace,
      ctx,
      to: '他',
      text: '好',
    );
    expect(
      (await messageById(world.workspace, '${first.args['message']}')).author,
      'Cody',
    );
  });

  test('#channel is a send to that channel; a person with nothing pending is '
      'a private message; nobody is an error', () async {
    final world = await OrbEvalWorld.create(scenario('D3').data());
    addTearDown(world.dispose);
    final w = world.workspace;
    final none = OrbReplyContext(needsYou: () async => const []);
    final channel = await orbResolveReply(
      w,
      none,
      to: '#raft-flutter',
      text: 'hi',
    );
    expect(channel.tool, 'send_message');
    expect(channel.args, {'channel': 'raft-flutter', 'text': 'hi'});
    final dm = await orbResolveReply(w, none, to: 'Cody', text: 'hi');
    expect(dm.tool, 'send_message');
    expect(
      w.dms.firstWhere((c) => c.id == dm.args['channel']).peerLabel,
      'Cody',
    );
    expect(
      orbResolveReply(w, none, text: 'hi'),
      throwsA(isA<AgentCapabilityError>()),
    );
    expect(
      orbResolveReply(w, none, to: 'Nobody', text: 'hi'),
      throwsA(isA<AgentCapabilityError>()),
    );
  });

  testWidgets('in a channel, "他" is the latest message that mentions the '
      'user, not the latest message', (t) async {
    t.view.physicalSize = const Size(412, 915);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final world = (await t.runAsync(
      () => OrbEvalWorld.create(scenario('A3').data()),
    ))!;
    final w = world.workspace;
    final key = GlobalKey<NavigatorState>();
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: raftTheme(RaftFamily.brutal),
        home: withAppServices(
          WorkspaceView(
            controller: w,
            appearance: RaftAppearance(light: RaftFamily.brutal),
            onAppearance: (_) async {},
            onLogout: () async {},
          ),
        ),
      ),
    );
    await t.pump(const Duration(seconds: 1));
    final ctx = OrbToolContext(
      workspace: w,
      navigatorContext: key.currentState!.overlay!.context,
      operating: ValueNotifier(false),
    );
    addTearDown(ctx.operating.dispose);
    final navigate = orbNavigationTools().firstWhere(
      (e) => e.name == 'navigate',
    );
    Map<String, Object?>? out;
    navigate
        .handler({'channel_id': evalId('raft-flutter')}, ctx)
        .then((v) => out = v);
    for (var i = 0; i < 40 && out == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(out!['title'], '#raft-flutter');

    OrbReplyPlan? plan;
    orbResolveReply(
      w,
      OrbReplyContext(needsYou: () async => const []),
      text: '可以合',
    ).then((p) => plan = p);
    for (var i = 0; i < 20 && plan == null; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(plan!.tool, 'reply_in_thread');
    final row = w.ledger.message(
      evalId('raft-flutter'),
      '${plan!.args['message']}',
    );
    expect(
      row!['senderName'],
      'Cody',
      reason: 'Alice spoke last; Cody asked Sam',
    );

    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(world.dispose);
  });
}
