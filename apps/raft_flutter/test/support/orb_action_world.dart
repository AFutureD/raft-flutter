import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:raft_flutter/data/workspace_entity_directory.dart';
import 'package:raft_flutter/features/agent_mode/agent_mode_data.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_actions.dart';

import '../activity_incremental_refresh_test.dart' show ActivityClient;
import '../agent_orb_shell_test.dart' show FakeAudio, OrbFixture;
import 'agent_capability_world.dart';

/// An orb fixture whose workspace is the capability tests' fictional one: a
/// #general channel, a message from Cody to answer, and two tasks. Every
/// write it makes is recorded on [world] (`sent`, `commands`, `toggles`).
class ActionOrbFixture extends OrbFixture {
  ActionOrbFixture(super.t);

  late CapabilityWorld world;
  var driving = false;

  @override
  Future<void> setUp() async {
    // What OrbFixture.setUp does, with this workspace instead of its own.
    SharedPreferences.setMockInitialValues({});
    AgentOrbPreference.instance.resetForTest();
    client = ActivityClient();
    audio = FakeAudio();
    final made = capabilityWorld(client: client);
    world = made.$2;
    world.ledger.switchServer('s1');
    w = world;
    world.routes['/tasks/server'] = (q) => {
      'tasks': [
        if (q?['status'] == 'in_review')
          {
            ...taskRow(
              't4',
              12,
              'in_review',
              title: '丁',
              claimedById: 'a-cody',
              claimedByName: 'Cody',
            ),
            'messageId': 'm-task-12',
          },
      ],
    };
    world.routes['/tasks/channel/ch-general/number/12'] = (_) => {
      'task': {
        ...taskRow(
          't4',
          12,
          'in_review',
          title: '丁',
          claimedById: 'a-cody',
          claimedByName: 'Cody',
        ),
        'messageId': 'm-task-12',
        'revision': 1,
      },
    };
    world.routes['/channels/ch-general/members'] = (_) => {
      'humans': [
        {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada'},
        {'userId': 'kevin', 'name': 'kevin', 'displayName': 'Kevin'},
      ],
      'agents': [
        {'id': 'a-cody', 'name': 'cody', 'displayName': 'Cody'},
      ],
    };
    world.routes['/messages/context/m-1'] = (_) => {
      'messages': [
        {
          'id': 'm-1',
          'channelId': 'ch-general',
          'content': '周五上线可以吗？',
          'senderName': 'Cody',
          'senderType': 'agent',
          'createdAt': hoursAgo(1),
          'seq': '10',
        },
      ],
    };
    // The directories the operations name people from, read on real time.
    await t.runAsync(() async {
      for (final kind in [
        WorkspaceEntityKind.agents,
        WorkspaceEntityKind.members,
      ]) {
        await world.entityDirectory.refresh(kind);
      }
    });
    actions = OrbActions(
      workspace: world,
      env: AgentCapabilityEnv(data: AgentModeData(world, now: () => worldNow)),
    );
  }
}
