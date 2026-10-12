// No-wait UI guard for the dialogs and pickers: with the data already local
// the network goes dead and each surface must still be on screen (with its
// content, not just its frame) within a few frames.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_entity_directory.dart';
import 'package:raft_flutter/features/add_members_dialog.dart';
import 'package:raft_flutter/features/agent_runtime_editor.dart';
import 'package:raft_flutter/features/composer_directory.dart';
import 'package:raft_flutter/features/create_agent_dialog.dart';
import 'package:raft_flutter/features/create_task_dialog.dart';
import 'package:raft_flutter/features/forward_messages_dialog.dart';
import 'package:raft_flutter/features/managed_agent_launcher.dart';
import 'package:raft_flutter/features/quick_switcher.dart';
import 'package:raft_flutter/features/source_feedback_view.dart';
import 'package:raft_flutter/features/workspace_menu_invite.dart';
import 'package:raft_ui/raft_ui.dart';

import 'source_feedback_store_test.dart' as feedback;
import 'support/close_support.dart';
import 'support/no_wait_support.dart';

void main() {
  const desktop = Size(1280, 800);

  testWidgets(
    'the forward picker lists the local channels at its first frame',
    (t) async {
      final (w, api) = await mountWorkspace(t, desktop);
      final held = await expectOpensWithoutNetwork(
        t,
        w,
        api,
        open: (c) => forwardMessages(c, w, [RaftMessage(closeRows().first)]),
        surface: find.byKey(const ValueKey('forward-target-c1')),
      );
      expect(held, 0);
    },
  );

  testWidgets('the create task dialog opens with the network dead', (t) async {
    final (w, api) = await mountWorkspace(t, desktop);
    await expectOpensWithoutNetwork(
      t,
      w,
      api,
      open: (c) => CreateTaskDialog.show(c, controller: w, channelId: 'c1'),
      surface: find.byType(CreateTaskDialog),
    );
  });

  testWidgets('add members shows the candidates from the roster and the '
      'directory at its first frame, not "nothing to add"', (t) async {
    final (w, api) = await mountWorkspace(t, desktop);
    final channel = w.channels.firstWhere((c) => c.id == 'c1');
    // The roster the composer already read for the channel (bob is in).
    rememberChannelRoster(
      w,
      channel,
      humans: [
        {'userId': 'bob'},
      ],
      agents: const [],
    );
    expect(cachedChannelRoster(w, 'c1'), isNotNull);
    await expectOpensWithoutNetwork(
      t,
      w,
      api,
      open: (c) => showDialog<void>(
        context: c,
        builder: (_) => AddMembersDialog(
          controller: w,
          channelId: 'c1',
          prefilledHumanIds: const ['bob', 'u2'],
          prefilledAgentIds: const ['a1'],
        ),
      ),
      surface: find.text('Cindy'),
    );
    Finder inDialog(String text) => find.descendant(
      of: find.byType(AddMembersDialog),
      matching: find.text(text),
    );
    expect(inDialog('Dana'), findsOneWidget);
    expect(inDialog('Bob'), findsNothing);
    expect(find.text('Add 2 members'), findsOneWidget);
    expect(find.textContaining('Nothing to add'), findsNothing);
  });

  testWidgets(
    'create agent opens with the directory computers and shows them',
    (t) async {
      final (w, api) = await mountWorkspace(t, desktop);
      api.routes['GET /servers/s1/machines'] = (_) => {
        'machines': [
          {
            'id': 'm1',
            'name': 'Studio Mac',
            'status': 'online',
            'runtimes': ['claude'],
          },
        ],
      };
      await t.runAsync(
        () => w.entityDirectory.refresh(
          WorkspaceEntityKind.computers,
          force: true,
        ),
      );
      await expectOpensWithoutNetwork(
        t,
        w,
        api,
        open: (c) => showManagedAgentForm(c, w),
        surface: find.byType(CreateAgentDialog),
      );
      expect(find.text('Studio Mac'), findsWidgets);
      expect(find.text('Connect a computer first'), findsNothing);
    },
  );

  testWidgets('the invite dialog repaints the last guest gate and join link '
      'on a revisit without waiting', (t) async {
    final (w, api) = await mountWorkspace(t, desktop);
    api.routes['GET /servers/s1/join-links'] = (_) => [
      {'id': 'l1', 'token': 'tok123'},
    ];
    api.routes['GET /billing/subscription'] = (_) => {};
    Future<void> openInvite() async {
      showWorkspaceMenuInvite(t.element(find.byType(Scaffold).first), w);
    }

    await openInvite();
    await frames(t, 20);
    await t.tap(find.text('By link'));
    await frames(t, 4);
    expect(find.textContaining('tok123'), findsWidgets);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t, 10);
    api.hangAll = true;
    await openInvite();
    await frames(t, 4);
    await t.tap(find.text('By link'));
    await frames(t, 4);
    expect(
      find.textContaining('tok123'),
      findsWidgets,
      reason: 'the cached link shows while the revalidation hangs',
    );
    api.hangAll = false;
  });

  testWidgets('the agent runtime editor repaints the last options and '
      'models on a revisit', (t) async {
    final (w, api) = await mountWorkspace(t, desktop);
    // The test holds requests open on a fake clock; a revisit must start its
    // own reads instead of joining the held ones.
    w.client.singleFlightWindow = Duration.zero;
    api.routes['GET /agents/a1/runtime-options'] = (_) => {
      'options': [
        {'runtimeId': 'claude', 'canSelectInThisContext': true},
      ],
    };
    api.routes['GET /servers/s1/machines/m1/runtime-models/claude'] = (_) => {
      'kind': 'live',
      'value': {
        'models': [
          {'id': 'sonnet', 'label': 'Sonnet Live Edition'},
        ],
      },
    };
    const agent = {
      'id': 'a1',
      'name': 'cindy',
      'runtime': 'claude',
      'model': 'sonnet',
      'machineId': 'm1',
      'status': 'inactive',
    };
    Future<void> open() => showAgentRuntimeEditor(
      t.element(find.byType(Scaffold).first),
      controller: w,
      agent: agent,
    );
    // The label only the machine's live answer carries.
    final live = find.text('Sonnet Live Edition');
    api.hangAll = true;
    open();
    await frames(t, 4);
    expect(find.byType(AgentRuntimeEditor), findsOneWidget);
    expect(live, findsNothing, reason: 'a cold first visit has no live copy');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t, 10);
    api.hangAll = false;
    open();
    await frames(t, 20);
    expect(live, findsWidgets);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await frames(t, 10);
    api.hangAll = true;
    open();
    await frames(t, 4);
    expect(find.byType(AgentRuntimeEditor), findsOneWidget);
    expect(live, findsWidgets, reason: 'the revisit paints the last models');
    api.hangAll = false;
  });

  testWidgets('feedback shows the previous inbox page on a revisit', (t) async {
    final (w, api) = await mountWorkspace(t, desktop);
    api.routes['GET /product-feedback/tickets'] = (_) =>
        feedback.page([feedback.ticket(feedback.first)]);
    Future<void> mount() async {
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant),
          home: Scaffold(body: SourceFeedbackView(controller: w)),
        ),
      );
    }

    final row = find.byKey(const ValueKey('feedback-ticket-${feedback.first}'));
    await mount();
    await frames(t, 20);
    expect(row, findsOneWidget);
    await t.pumpWidget(const SizedBox());
    api.hangAll = true;
    await mount();
    await frames(t, 3);
    expect(row, findsOneWidget, reason: 'the revisit must not show a skeleton');
    api.hangAll = false;
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the quick switcher opens at once from the local lists', (
    t,
  ) async {
    final (_, api) = await mountWorkspace(t, desktop);
    api.hangAll = true;
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyK);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await frames(t, 4);
    expect(find.byType(QuickSwitcher), findsOneWidget);
    api.hangAll = false;
  });
}
