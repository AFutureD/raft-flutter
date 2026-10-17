import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/personal_presentation.dart';
import 'package:raft_flutter/data/search_memory.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/chat_agent_presentation.dart';
import 'package:raft_flutter/features/live_agent_activity_bar.dart';
import 'package:raft_flutter/features/message_reference_directory.dart';
import 'package:raft_ui/raft_ui.dart';

class _Workspace extends WorkspaceController {
  _Workspace(super.client);

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async =>
      path == '/agents'
      ? [
          {'id': 'older', 'name': 'Older', 'avatarUrl': 'pixel:cat'},
          {'id': 'latest', 'name': 'Latest', 'avatarUrl': 'pixel:cat'},
        ]
      : [];
}

class _Storage implements SearchMemoryStorage {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) async {}
}

Future<ChatAgentPresentation> _fixture(DateTime Function() clock) async {
  final client = RaftClient(
    origin: 'https://live-expiry-render.invalid',
    sessionStore: MemorySessionStore(),
  )..user = RaftRecord({'id': 'alice'});
  client.selectServer('s');
  final w = _Workspace(client)
    ..server = RaftRecord({'id': 's', 'role': 'owner'});
  final directory = MessageReferenceDirectory(w);
  await w.entityDirectory.preload();
  final activity = ChatAgentPresentation(w, directory, clock: clock);
  addTearDown(() async {
    activity.dispose();
    directory.dispose();
    w.dispose();
    await client.dispose();
  });
  return activity;
}

void _signal(
  ChatAgentPresentation activity,
  String id, {
  String kind = 'working',
  int? timestamp,
}) => activity.event(
  RaftEvent('agent:activity', {
    'agentId': id,
    'serverId': 's',
    'activity': kind,
    'detail': '$id task',
    'timestamp': ?timestamp,
  }),
);

void main() {
  for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
    testWidgets('expiry rebuilds only the changed live bar ($family)', (
      t,
    ) async {
      final start = t.binding.clock.now();
      final activity = await _fixture(
        () => DateTime.utc(
          2026,
          10,
          17,
        ).add(t.binding.clock.now().difference(start)),
      );
      final store = PersonalPresentationStore(storage: _Storage());
      await store.bind(activity.w.client.origin, 'alice');
      addTearDown(store.dispose);
      _signal(activity, 'older');
      await t.pump(const Duration(seconds: 30));
      _signal(activity, 'latest');
      var builds = 0, notifications = 0;
      activity.addListener(() => notifications++);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(family),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: activity,
              builder: (context, _) {
                builds++;
                return NativeLiveAgentActivityBar(
                  activities: activity,
                  presentation: store,
                  origin: activity.w.client.origin,
                );
              },
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final settledBuilds = builds;
      expect(find.text('latest task'), findsOneWidget);

      // Let the real expiry Timer run, with the injected clock following the
      // widget test's clock. An older row expires, while the bar stays put.
      await t.pump(const Duration(seconds: 61));
      expect(activity.items.map((item) => item.agentId), ['latest']);
      expect(notifications, 0);
      expect(builds, settledBuilds);
      expect(find.text('latest task'), findsOneWidget);

      await t.pump(const Duration(seconds: 30));
      expect(activity.items, isEmpty);
      expect(notifications, 1);
      expect(builds, settledBuilds + 1);
      expect(find.byType(RaftLiveAgentActivityBar), findsNothing);

      activity.prune();
      activity.prune();
      await t.pump();
      expect(notifications, 1);
      expect(builds, settledBuilds + 1);
      await t.pumpWidget(const SizedBox.shrink());
    });
  }

  test(
    'an already expired late signal does not invent a visible expiry',
    () async {
      final now = DateTime.utc(2026, 10, 17);
      final activity = await _fixture(() => now);
      _signal(activity, 'latest');
      _signal(
        activity,
        'older',
        timestamp: now
            .subtract(const Duration(seconds: 91))
            .millisecondsSinceEpoch,
      );
      expect(activity.items.first.agentId, 'older');
      expect(activity.latest!.agentId, 'latest');
      var changes = 0;
      activity.addListener(() => changes++);

      activity.prune();

      expect(activity.items.map((item) => item.agentId), ['latest']);
      expect(changes, 0);
    },
  );

  test('terminal work clears before a later empty prune', () async {
    final activity = await _fixture(() => DateTime.utc(2026, 10, 17));
    _signal(activity, 'latest');
    var changes = 0;
    activity.addListener(() => changes++);
    _signal(activity, 'latest', kind: 'online');
    expect(activity.latest, isNull);
    expect(changes, 1);

    activity.prune();

    expect(changes, 1);
  });

  test('authority clearing cannot be published again by expiry', () async {
    final activity = await _fixture(() => DateTime.utc(2026, 10, 17));
    _signal(activity, 'latest');
    activity.w.server = RaftRecord({'id': 's', 'role': 'guest'});
    activity.w.notifyListeners();
    expect(activity.latest, isNull);
    var changes = 0;
    activity.addListener(() => changes++);

    activity.prune();

    expect(changes, 0);
  });
}
