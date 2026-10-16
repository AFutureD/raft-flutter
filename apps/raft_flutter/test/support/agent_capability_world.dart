import 'package:raft_client/raft_client.dart';
import 'package:raft_flutter/data/workspace_controller.dart';

import 'package:raft_flutter/features/agent_mode/agent_surface_tools.dart'
    show AgentFacts;

import '../activity_incremental_refresh_test.dart' show ActivityClient;

/// A fictional workspace for the capability tests: no real names, servers or
/// data. Every read the app's data layer makes is answered from [routes]
/// (path to a function of the query), and recorded in [reads].
class CapabilityWorld extends WorkspaceController {
  CapabilityWorld(super.client);

  final routes = <String, Object? Function(Map<String, dynamic>? query)>{};
  final reads = <String>[];
  final queries = <String, Map<String, dynamic>?>{};

  @override
  Future<void> refreshUnread() async {}

  @override
  Future<dynamic> query(String path, {Map<String, dynamic>? query}) async {
    reads.add(path);
    queries[path] = query;
    final route = routes[path];
    if (route == null) return <String, dynamic>{};
    return route(query);
  }

  @override
  Future<dynamic> sharedQuery(String path, {Map<String, dynamic>? query}) =>
      this.query(path, query: query);
}

final worldNow = DateTime.utc(2026, 10, 15, 12);

String hoursAgo(int h) =>
    worldNow.subtract(Duration(hours: h)).toIso8601String();

Map<String, dynamic> taskRow(
  String id,
  int number,
  String status, {
  String title = 'Task',
  String channel = 'general',
  String? claimedById,
  String? claimedByName,
  String createdById = 'kevin',
  String createdByName = 'Kevin',
  int updated = 2,
  String? thread,
}) => {
  'id': id,
  'taskNumber': number,
  'title': title,
  'description': '',
  'status': status,
  'channelId': 'ch-$channel',
  'channelName': channel,
  'threadChannelId': thread,
  'createdById': createdById,
  'createdByType': 'user',
  'createdByName': createdByName,
  'claimedById': claimedById,
  'claimedByType': claimedById == null ? null : 'agent',
  'claimedByName': claimedByName,
  'updatedAt': hoursAgo(updated),
};

(ActivityClient, CapabilityWorld) capabilityWorld() {
  final client = ActivityClient()
    ..user = RaftRecord({'id': 'kevin', 'displayName': 'Kevin'});
  client.selectServer('s1');
  final w = CapabilityWorld(client)
    ..server = RaftRecord({'id': 's1', 'role': 'owner', 'name': 'Fixture HQ'})
    ..channels = [
      RaftChannel({
        'id': 'ch-general',
        'name': 'general',
        'description': 'Everything',
        'joined': true,
      }),
      RaftChannel({'id': 'ch-design', 'name': 'design', 'joined': true}),
      RaftChannel({
        'id': 'ch-design2',
        'name': 'design-review',
        'joined': true,
      }),
    ]
    ..dms = [
      RaftChannel({
        'id': 'dm-1',
        'type': 'dm',
        'name': 'dm',
        'peerName': 'Ada',
      }),
    ]
    ..unread = {'ch-general': 3, 'ch-design': 1, 'dm-1': 2}
    ..mentions = {'ch-design'};
  w.routes['/agents'] = (_) => [
    {
      'id': 'a-cody',
      'name': 'cody',
      'displayName': 'Cody',
      'status': 'active',
      'runtime': 'codex',
      'model': 'gpt',
      'machineId': 'm1',
      'description': 'Writes code',
    },
    {
      'id': 'a-cindy',
      'name': 'cindy',
      'displayName': 'Cindy',
      'status': 'active',
      'runtime': 'claude',
      'model': 'opus',
    },
  ];
  w.routes['/servers/s1/machines'] = (_) => {
    'machines': [
      {
        'id': 'm1',
        'name': 'Studio',
        'status': 'online',
        'hostname': 'studio.local',
        'os': 'linux',
      },
      {'id': 'm2', 'name': 'Attic', 'status': 'offline'},
    ],
  };
  w.routes['/servers/s1/members'] = (_) => [
    {
      'userId': 'kevin',
      'name': 'kevin',
      'displayName': 'Kevin',
      'role': 'owner',
    },
    {'userId': 'ada', 'name': 'ada', 'displayName': 'Ada', 'role': 'member'},
    {
      'userId': 'ada2',
      'name': 'ada.lee',
      'displayName': 'Ada Lee',
      'role': 'member',
    },
  ];
  return (client, w);
}

/// Gives a test the facts a capability read teaches.
class AgentFactsProbe {
  final facts = AgentFacts();
}
