import 'package:flutter_test/flutter_test.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';
import 'package:raft_flutter/features/chat_agent_presentation.dart';
import 'package:raft_flutter/features/message_reference_directory.dart';

class _Workspace extends WorkspaceController {
  _Workspace(super.client);
  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async =>
      path == '/agents'
      ? [
          {'id': 'older', 'name': 'Older'},
          {'id': 'latest', 'name': 'Latest'},
        ]
      : [];
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 17);
  DateTime call() => now;
}

Future<(ChatAgentPresentation, _Clock)> _fixture() async {
  final client = RaftClient(
    origin: 'https://live-expiry-work.invalid',
    sessionStore: MemorySessionStore(),
  )..user = RaftRecord({'id': 'alice'});
  client.selectServer('s');
  final w = _Workspace(client)
    ..server = RaftRecord({'id': 's', 'role': 'owner'});
  final directory = MessageReferenceDirectory(w);
  await w.entityDirectory.preload();
  expect(directory.loading, isFalse);
  expect(directory.agents.map((row) => row['id']), ['older', 'latest']);
  final clock = _Clock();
  final activity = ChatAgentPresentation(w, directory, clock: clock.call);
  addTearDown(() async {
    activity.dispose();
    directory.dispose();
    w.dispose();
    await client.dispose();
  });
  return (activity, clock);
}

void _signal(ChatAgentPresentation activity, String id) => activity.event(
  RaftEvent('agent:activity', {
    'agentId': id,
    'serverId': 's',
    'activity': 'working',
    'detail': '$id task',
    'serverSeq': '1',
  }),
);

void main() {
  test(
    'expiring older work leaves the displayed latest item unchanged',
    () async {
      final (activity, clock) = await _fixture();
      _signal(activity, 'older');
      clock.now = clock.now.add(const Duration(seconds: 30));
      _signal(activity, 'latest');
      final shown = activity.latest!;
      var changes = 0;
      activity.addListener(() => changes++);
      clock.now = clock.now.add(const Duration(seconds: 61));

      activity.prune();

      expect(activity.items.map((item) => item.agentId), ['latest']);
      expect(activity.latest, same(shown));
      expect(
        changes,
        0,
        reason: 'The bar displays only the unchanged latest work.',
      );
    },
  );

  test(
    'latest expiry clears once and an already empty prune stays silent',
    () async {
      final (activity, clock) = await _fixture();
      _signal(activity, 'latest');
      var changes = 0;
      activity.addListener(() => changes++);
      clock.now = clock.now.add(const Duration(seconds: 91));

      activity.prune();
      expect(activity.latest, isNull);
      expect(changes, 1, reason: 'The visible expired work must disappear.');
      activity.prune();
      expect(changes, 1, reason: 'No second visible change occurred.');
    },
  );
}
