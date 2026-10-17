import 'dart:convert';

/// Fixture data for the orb evaluation. Fictional names only (Sam is the
/// person using the app; Cody, Grok, CodexMac and 八戒 are agents; Alice is a
/// teammate). Ids are UUID-shaped on purpose: a model that reads one out loud
/// is caught by the scorer.

/// A stable UUID-shaped id for [key] (the same key always gives the same id).
String evalId(String key) {
  var h = 0xcbf29ce484222325;
  final bytes = utf8.encode(key);
  final out = StringBuffer();
  var state = h;
  for (var i = 0; i < 4; i++) {
    for (final b in bytes) {
      state = ((state ^ (b + i)) * 0x100000001b3) & 0x7fffffffffffffff;
    }
    out.write(state.toRadixString(16).padLeft(16, '0'));
  }
  final hex = out.toString();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}'
      '-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}

/// Someone in the fixture workspace.
class OrbEvalPerson {
  const OrbEvalPerson(
    this.key,
    this.name, {
    this.agent = false,
    this.system = false,
  });
  final String key;
  final String name;
  final bool agent;

  /// The platform itself (status changes, build results).
  final bool system;
  String get id => system ? 'system' : evalId('person:$key');
  String get type => system ? 'system' : (agent ? 'agent' : 'user');
}

const evalMe = OrbEvalPerson('me', 'Sam');
const evalAlice = OrbEvalPerson('alice', 'Alice');
const evalCody = OrbEvalPerson('cody', 'Cody', agent: true);
const evalGrok = OrbEvalPerson('grok', 'Grok', agent: true);
const evalCodexMac = OrbEvalPerson('codexmac', 'CodexMac', agent: true);
const evalBajie = OrbEvalPerson('bajie', '八戒', agent: true);
const evalSystem = OrbEvalPerson('system', '系统', system: true);
const evalPeople = [
  evalMe,
  evalAlice,
  evalCody,
  evalGrok,
  evalCodexMac,
  evalBajie,
];

/// The id of the fixture workspace and its address.
final evalServerId = evalId('server');
const evalServerSlug = 'fixture';

/// Everything a scenario's workspace holds, as the server would send it. The
/// helpers fill the JSON in the shapes the app's data layer reads; a scenario
/// starts from [OrbEvalData.cast] and arranges the rest.
///
/// Conversations are named by key (`'raft-flutter'`, `'dm:cody'`,
/// `'thread:review'`); [evalId] turns a key into the id the app sees.
class OrbEvalData {
  OrbEvalData();

  /// The fixture cast: the three channels, a DM with Cody and one with Alice,
  /// the agents and the members. Nothing unread, nothing in the Activity.
  factory OrbEvalData.cast() {
    final d = OrbEvalData();
    d.channel('raft-flutter');
    d.channel('design', joined: false);
    d.channel('swift-workflow');
    d.dm(evalCody);
    d.dm(evalAlice);
    return d;
  }

  /// When the fixture was made: ages are counted back from here.
  final DateTime now = DateTime.now().toUtc();

  final channels = <Map<String, dynamic>>[];
  final dms = <Map<String, dynamic>>[];
  final unread = <String, int>{};
  final inbox = <Map<String, dynamic>>[];
  final messages = <String, List<Map<String, dynamic>>>{};
  final tasks = <Map<String, dynamic>>[];

  /// The Activity (`/channels/inbox`) never answers while the scenario runs:
  /// the page stays "loading".
  bool holdInbox = false;

  String ago(int minutes) =>
      now.subtract(Duration(minutes: minutes)).toIso8601String();

  String _key(String key) => evalId(key);

  // ---- conversations -------------------------------------------------------

  /// A channel; its id is `evalId(key)`.
  String channel(String key, {bool joined = true}) {
    final id = _key(key);
    channels.add({
      'id': id,
      'name': key,
      'type': 'channel',
      'serverId': evalServerId,
      'joined': joined,
      'latestSeq': '0',
    });
    return id;
  }

  /// A private conversation with [peer]; key `dm:<peer key>`.
  String dm(OrbEvalPerson peer) {
    final id = _key('dm:${peer.key}');
    dms.add({
      'id': id,
      'type': 'dm',
      'name': peer.name.toLowerCase(),
      'peerId': peer.id,
      'peerType': peer.type,
      'peerName': peer.name,
      'serverId': evalServerId,
      'joined': true,
      'latestSeq': '0',
    });
    return id;
  }

  String idOf(String key) => _key(key);

  int _seq = 0;

  /// One message in the conversation [conversation]; returns its id.
  String say(
    String conversation,
    OrbEvalPerson from,
    String text, {
    int ago = 30,
    String? id,
    List<OrbEvalPerson> mentions = const [],
    int replies = 0,
    String? thread,
  }) {
    final channelId = _key(conversation);
    final seq = ++_seq;
    final messageId = id ?? _key('msg:$conversation:$seq');
    (messages[channelId] ??= []).add({
      'id': messageId,
      'channelId': channelId,
      'seq': '$seq',
      'senderId': from.id,
      'senderName': from.name,
      'senderType': from.type,
      'content': text,
      'createdAt': this.ago(ago),
      if (mentions.isNotEmpty)
        'mentions': [
          for (final m in mentions)
            {'id': m.id, 'type': m.type, 'name': m.name},
        ],
      if (replies > 0) 'replyCount': replies,
      if (thread != null) 'threadChannelId': _key(thread),
    });
    return messageId;
  }

  /// A message that arrives while a scenario runs (a realtime event): it is
  /// added to the conversation and returned as the event's payload.
  Map<String, dynamic> incoming(
    String conversation,
    OrbEvalPerson from,
    String text, {
    List<OrbEvalPerson> mentions = const [],
  }) {
    say(conversation, from, text, ago: 0, mentions: mentions);
    return messages[_key(conversation)]!.last;
  }

  void setUnread(String conversation, int count) =>
      unread[_key(conversation)] = count;

  // ---- the Activity --------------------------------------------------------

  /// A channel row of the Activity. [message] is the id of the newest message.
  void inboxChannel(
    String conversation, {
    required String name,
    required String preview,
    required OrbEvalPerson from,
    required String message,
    int unread = 1,
    int ago = 10,
    bool mention = false,
    String? firstUnread,
    String? firstMention,
  }) {
    if (unread > 0) this.unread[_key(conversation)] = unread;
    inbox.add({
      'kind': 'channel',
      'channelId': _key(conversation),
      'channelName': name,
      'channelType': 'channel',
      'lastMessageId': message,
      'lastMessagePreview': preview,
      'lastMessageSenderId': from.id,
      'lastMessageSenderType': from.type,
      'lastMessageSenderName': from.name,
      'lastActivityAt': this.ago(ago),
      'lastMessageAt': this.ago(ago),
      'unreadCount': unread,
      'firstUnreadMessageId': unread > 0 ? (firstUnread ?? message) : null,
      'firstMentionMessageId': mention ? (firstMention ?? message) : null,
      'hasMention': mention,
    });
  }

  /// A private-conversation row of the Activity.
  void inboxDm(
    String conversation, {
    required OrbEvalPerson peer,
    required String preview,
    required String message,
    OrbEvalPerson? from,
    int unread = 1,
    int ago = 10,
  }) {
    final sender = from ?? peer;
    if (unread > 0) this.unread[_key(conversation)] = unread;
    inbox.add({
      'kind': 'dm',
      'channelId': _key(conversation),
      'channelName': peer.name.toLowerCase(),
      'channelType': 'dm',
      'lastMessageId': message,
      'lastMessagePreview': preview,
      'lastMessageSenderId': sender.id,
      'lastMessageSenderType': sender.type,
      'lastMessageSenderName': sender.name,
      'lastActivityAt': this.ago(ago),
      'lastMessageAt': this.ago(ago),
      'unreadCount': unread,
      'firstUnreadMessageId': unread > 0 ? message : null,
      'hasMention': false,
    });
  }

  /// A discussion row of the Activity.
  void inboxThread({
    required String thread,
    required String parentConversation,
    required String parentName,
    required String parentMessage,
    required String parentPreview,
    required OrbEvalPerson parentFrom,
    required String latestMessage,
    required String latestPreview,
    required OrbEvalPerson latestFrom,
    int unread = 1,
    int ago = 10,
    bool mention = false,
    bool following = true,
    int? taskNumber,
    String? taskStatus,
  }) {
    inbox.add({
      'kind': 'thread',
      'threadChannelId': _key(thread),
      'parentChannelId': _key(parentConversation),
      'parentChannelName': parentName,
      'parentChannelType': 'channel',
      'parentMessageId': parentMessage,
      'parentMessagePreview': parentPreview,
      'parentMessageSenderId': parentFrom.id,
      'latestActivityMessageId': latestMessage,
      'latestActivityPreview': latestPreview,
      'latestActivitySenderId': latestFrom.id,
      'latestActivitySenderType': latestFrom.type,
      'lastActivityAt': this.ago(ago),
      'unreadCount': unread,
      'hasMention': mention,
      'isFollowing': following,
      'taskNumber': ?taskNumber,
      'taskStatus': ?taskStatus,
    });
  }

  /// A "mentioned you, waiting for an answer" row of the Activity.
  void inboxMention(
    String conversation, {
    required String name,
    required String message,
    required String preview,
    required OrbEvalPerson from,
    int ago = 10,
  }) {
    inbox.add({
      'kind': 'mention_action',
      'id': _key('mention:$message'),
      'channelId': _key(conversation),
      'channelName': name,
      'channelType': 'channel',
      'messageId': message,
      'messagePreview': preview,
      'lastMessagePreview': preview,
      'senderId': from.id,
      'senderType': from.type,
      'senderName': from.name,
      'lastActivityAt': this.ago(ago),
      'unreadCount': 1,
      'hasMention': true,
    });
  }

  // ---- tasks ---------------------------------------------------------------

  /// A task. [status] is `in_progress`, `in_review`, `todo` or `done`.
  void task(
    int number,
    String title,
    String status, {
    String channel = 'raft-flutter',
    OrbEvalPerson? by,
    OrbEvalPerson? createdBy,
    int ageMinutes = 60,
    String? thread,
    String? message,
    String description = '',
  }) {
    final creator = createdBy ?? evalMe;
    final channelId = _key(channel);
    tasks.add({
      'id': _key('task:$number'),
      'taskNumber': number,
      'title': title,
      'description': description,
      'status': status,
      'channelId': channelId,
      'channelName': channel,
      'messageId': message ?? _key('task-msg:$number'),
      'threadChannelId': thread == null ? null : _key(thread),
      'createdById': creator.id,
      'createdByType': creator.type,
      'createdByName': creator.name,
      'claimedById': by?.id,
      'claimedByType': by?.type,
      'claimedByName': by?.name,
      'updatedAt': ago(ageMinutes),
      'createdAt': ago(ageMinutes + 60),
    });
  }

  // ---- directories ---------------------------------------------------------

  List<Map<String, dynamic>> get agentRows => [
    for (final p in evalPeople)
      if (p.agent)
        {
          'id': p.id,
          'name': p.name,
          'displayName': p.name,
          'status': 'active',
          'runtime': p == evalCodexMac ? 'codex' : 'claude',
          'model': 'fixture',
          'creatorType': 'user',
          'creatorId': evalMe.id,
        },
  ];

  List<Map<String, dynamic>> get memberRows => [
    for (final p in evalPeople)
      if (!p.agent && !p.system)
        {
          'userId': p.id,
          'id': p.id,
          'name': p.name,
          'displayName': p.name,
          'role': p == evalMe ? 'owner' : 'member',
        },
  ];

  /// Every id the fixture holds: a reply that says one of these out loud is
  /// reading an id.
  Set<String> get allIds => {
    evalServerId,
    for (final p in evalPeople) p.id,
    for (final c in [...channels, ...dms]) '${c['id']}',
    for (final list in messages.values)
      for (final m in list) '${m['id']}',
    for (final t in tasks) '${t['id']}',
    for (final row in inbox) ...[
      for (final k in const [
        'id',
        'channelId',
        'threadChannelId',
        'parentChannelId',
        'parentMessageId',
        'lastMessageId',
        'latestActivityMessageId',
      ])
        if (row[k] is String) row[k] as String,
    ],
  };
}
