import 'package:flutter/foundation.dart' show VoidCallback;
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

  // ---- What the operations call on the controller, recorded ----

  /// `(method, path, data)` of every [command].
  final commands = <(String, String, Object?)>[];
  final commandRoutes = <String, Object? Function(Object? data)>{};
  Object? commandError;

  @override
  Future<dynamic> command(String method, String path, {dynamic data}) async {
    commands.add((method, path, data));
    final error = commandError;
    if (error != null) throw error;
    return (commandRoutes['$method $path'] ?? (_) => <String, dynamic>{})(data);
  }

  /// Channels selected, in order (the page's own `selectChannel`).
  final selected = <String>[];

  @override
  Future<void> selectChannel(
    RaftChannel next, {
    bool autoRead = true,
    bool navigate = true,
    bool retainContextUntilAccepted = false,
    bool preserveThread = false,
    VoidCallback? onDraftRestored,
  }) async {
    selected.add(
      '${next.id}${autoRead ? '' : ':quiet'}${navigate ? '' : ':stay'}',
    );
    channel = next;
  }

  /// `(text, channel at the time, thread, mentions, randomId)` of each send.
  final sent =
      <
        ({
          String text,
          String? channel,
          bool thread,
          List<Map<String, dynamic>>? mentions,
          String? randomId,
          String? parent,
        })
      >[];
  bool sendAccepted = true;

  @override
  Future<bool> send(
    String text, {
    bool thread = false,
    List<String>? attachments,
    List<Map<String, dynamic>>? mentions,
    String? randomId,
    bool asTask = false,
    String Function(int count)? attachmentsOnlyBody,
    void Function(int window)? onWindowRefreshed,
  }) async {
    sent.add((
      text: text,
      channel: channel?.id,
      thread: thread,
      mentions: mentions,
      randomId: randomId,
      parent: threadParent?.id,
    ));
    if (!sendAccepted) {
      error = 'Failed to send message';
      return false;
    }
    final target = thread ? threadChannelId : channel?.id;
    if (target != null) {
      ledger.ingest([
        {
          'id': 'm-sent-${sent.length}',
          'channelId': target,
          'randomId': randomId,
          'content': text,
          'seq': '${900 + sent.length}',
          'senderId': 'kevin',
          'senderType': 'user',
        },
      ], expectedGeneration: ledger.generation);
    }
    return true;
  }

  /// Sends addressed by channel id (what the operations use): the selection,
  /// the open thread and the drafts are never touched, so `selected` and
  /// `threads` stay empty.
  @override
  Future<bool> sendToChannel(
    RaftChannel target,
    String text, {
    List<Map<String, dynamic>>? mentions,
    String? randomId,
  }) async {
    sent.add((
      text: text,
      channel: target.id,
      thread: false,
      mentions: mentions,
      randomId: randomId,
      parent: null,
    ));
    if (!sendAccepted) {
      error = 'Failed to send message';
      return false;
    }
    ledger.ingest([
      {
        'id': 'm-sent-${sent.length}',
        'channelId': target.id,
        'randomId': randomId,
        'content': text,
        'seq': '${900 + sent.length}',
        'senderId': 'kevin',
        'senderType': 'user',
      },
    ], expectedGeneration: ledger.generation);
    return true;
  }

  @override
  Future<bool> sendThreadReply(
    RaftMessage parent,
    String text, {
    List<Map<String, dynamic>>? mentions,
    String? randomId,
    void Function(String threadChannelId)? resolved,
  }) async {
    sent.add((
      text: text,
      channel: parent.channelId,
      thread: true,
      mentions: mentions,
      randomId: randomId,
      parent: parent.id,
    ));
    if (!sendAccepted) {
      error = 'Failed to send message';
      return false;
    }
    final threadId = 'thr-${parent.id}';
    resolved?.call(threadId);
    ledger.ingest([
      {
        'id': 'm-sent-${sent.length}',
        'channelId': threadId,
        'randomId': randomId,
        'content': text,
        'seq': '${900 + sent.length}',
        'senderId': 'kevin',
        'senderType': 'user',
      },
    ], expectedGeneration: ledger.generation);
    return true;
  }

  final threads = <String>[];

  @override
  Future<void> openThread(
    RaftMessage parent, {
    String? focusedMessageId,
    bool navigate = true,
  }) async {
    threads.add('${parent.id}${navigate ? '' : ':stay'}');
    threadParent = parent;
    threadChannelId = 'thr-${parent.id}';
  }

  @override
  void closeThread({bool navigate = true}) {
    threads.add('closed');
    threadParent = null;
    threadChannelId = null;
  }

  /// `message:emoji` of every toggle.
  final toggles = <String>[];
  Object? toggleError;

  @override
  Future<void> toggleReaction(RaftMessage message, String emoji) async {
    toggles.add('${message.id}:$emoji');
    if (toggleError != null) throw toggleError!;
  }

  @override
  Future<void> hydrateReactionViewer(RaftMessage message) async {}

  int channelRefreshes = 0;

  @override
  Future<void> refreshChannels() async => channelRefreshes++;

  final readAcks = <String>[];

  @override
  bool acceptReadAllAck(
    String scopeId,
    dynamic receipt, {
    required String serverId,
    required String principalId,
  }) {
    readAcks.add(scopeId);
    unread = {...unread, scopeId: 0};
    return true;
  }

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

(ActivityClient, CapabilityWorld) capabilityWorld({ActivityClient? client}) {
  client ??= ActivityClient();
  client.user = RaftRecord({'id': 'kevin', 'displayName': 'Kevin'});
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
