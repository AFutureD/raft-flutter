import 'package:raft_client/raft_client.dart';

class IncomingShareTarget {
  const IncomingShareTarget(
    this.label, {
    this.channel,
    this.userId,
    this.agentId,
  });
  final String label;
  final RaftChannel? channel;
  final String? userId, agentId;
  bool get requiresJoin => channel != null && !channel!.joined;
  String get key => channel?.id ?? 'user:$userId:agent:$agentId';
}

bool acceptsSharedDraft(RaftChannel channel) =>
    channel.joined &&
    !channel.archived &&
    channel.type != 'thread' &&
    channel.json['readOnly'] != true;

/// Server directory reads do not select that server or create conversations.
Future<List<IncomingShareTarget>> incomingShareTargets(
  RaftClient client,
  RaftRecord server,
) async {
  final results = await Future.wait([
    client.getForServer(server.id, '/channels'),
    client.getForServer(server.id, '/channels/dm'),
  ]);
  final channels = [
    for (final result in results)
      if (result is List)
        for (final row in result.whereType<Map>())
          RaftChannel(Map<String, dynamic>.from(row)),
  ];
  final targets = <IncomingShareTarget>[
    for (final c in channels.where(
      (c) =>
          acceptsSharedDraft(c) ||
          !c.joined &&
              !c.archived &&
              c.type == 'channel' &&
              c.json['readOnly'] != true &&
              raftCan(server.string('role'), 'joinPublicChannels'),
    ))
      IncomingShareTarget(
        c.type == 'dm'
            ? '@${c.json['peerDisplayName'] ?? c.json['peerName'] ?? c.name}'
            : '#${c.name}',
        channel: c,
      ),
  ];
  Future<void> peers(String path, bool agent) async {
    try {
      final result = await client.getForServer(server.id, path);
      final rows = result is List
          ? result
          : result is Map
          ? result['members']
          : null;
      if (rows is! List) return;
      for (final row in rows.whereType<Map>()) {
        final id = agent ? row['id'] : row['userId'] ?? row['id'];
        final person = row['user'] is Map ? row['user'] as Map : row;
        final name =
            person['displayName'] ?? person['name'] ?? person['username'];
        if (id is! String || name is! String || id == client.user?.id) continue;
        if (channels.any(
          (c) =>
              c.type == 'dm' &&
              (c.json[agent ? 'agentId' : 'peerUserId'] == id ||
                  c.json['peerId'] == id),
        )) {
          continue;
        }
        targets.add(
          IncomingShareTarget(
            '@$name',
            agentId: agent ? id : null,
            userId: agent ? null : id,
          ),
        );
      }
    } on RaftApiException {
      // An unavailable peer directory does not hide joined conversations.
    }
  }

  if (raftCan(server.string('role'), 'viewAgents')) {
    await peers('/agents', true);
  }
  if (raftCan(server.string('role'), 'viewMembers')) {
    await peers('/servers/${server.id}/members', false);
  }
  final unique = {for (final target in targets) target.key: target}.values
      .toList();
  unique.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
  return unique;
}
