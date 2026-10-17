import 'package:raft_client/raft_client.dart';

import '../../../data/raft_location.dart';
import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/action_support.dart' show messageById;
import '../../agent_mode/capabilities/agent_capability.dart'
    show AgentCapabilityError;
import '../briefing/orb_briefing_models.dart' show OrbBriefItem;

/// What the app knows about who "他" is.
class OrbReplyContext {
  const OrbReplyContext({this.card, required this.needsYou});

  /// The item on the driving card, when driving.
  final OrbBriefItem? card;

  /// What needs the person, most pressing first (read when it is needed).
  final Future<List<OrbBriefItem>> Function() needsYou;
}

/// Where a reply goes: the tool that asks for it and its arguments.
typedef OrbReplyPlan = ({String tool, Map<String, Object?> args});

final _pronoun = RegExp(
  r'^(他|她|它|他们|她们|对方|这个|这条|那个|这件|him|her|them|he|she|it|this|that)$',
  caseSensitive: false,
);

bool _named(String a, String b) {
  final x = a.trim().toLowerCase().replaceAll('@', '');
  final y = b.trim().toLowerCase().replaceAll('@', '');
  return x.isNotEmpty && y.isNotEmpty && (x.contains(y) || y.contains(x));
}

/// Works out where "回复他说 [text]" goes, the way a person would: the item
/// on the driving card, else the conversation on the screen (the latest
/// message that mentions the person, else the latest from someone else, or the
/// private conversation itself), else what needs them most, else a private
/// conversation with the named person.
///
/// [to] is empty or a pronoun ("他"): the above; a name: that person; `#name`:
/// that channel; anything else is tried as a message id last. A reply to a
/// message is `reply_in_thread` (so the card names the person); in a private
/// conversation it is `send_message` to it. Throws [AgentCapabilityError]
/// when there is nobody to reply to.
Future<OrbReplyPlan> orbResolveReply(
  WorkspaceController w,
  OrbReplyContext ctx, {
  String? to,
  required String text,
}) async {
  final want = to?.trim() ?? '';
  if (want.startsWith('#') && want.length > 1) {
    return (
      tool: 'send_message',
      args: {'channel': want.substring(1), 'text': text},
    );
  }
  final person = want.isEmpty || _pronoun.hasMatch(want) ? null : want;

  // 1. The driving card.
  final card = ctx.card;
  if (card != null && (person == null || _named(card.who, person))) {
    final plan = await _fromItem(w, card, text);
    if (plan != null) return plan;
  }
  // 2. The conversation on the screen.
  final page = _fromPage(w, person, text);
  if (page != null) return page;
  // 3. What needs the person.
  List<OrbBriefItem> items = const [];
  try {
    items = await ctx.needsYou();
  } on Object {
    items = const [];
  }
  for (final item in items) {
    if (person != null && !_named(item.who, person)) continue;
    final plan = await _fromItem(w, item, text);
    if (plan != null) return plan;
  }
  // 4. A private conversation with the person.
  if (person != null) {
    final dm = w.dms.where((c) => _named(c.peerLabel, person)).firstOrNull;
    if (dm != null) {
      return (tool: 'send_message', args: {'channel': dm.id, 'text': text});
    }
    // 5. Perhaps it was a message id.
    try {
      final m = await messageById(w, person);
      return (
        tool: 'reply_in_thread',
        args: {'message': m.id, 'channel': m.channelId, 'text': text},
      );
    } on Object {
      // Not one either.
    }
    throw AgentCapabilityError('找不到“$person”可以回复的对话，请问用户要回复谁');
  }
  throw const AgentCapabilityError('不知道要回复谁：现在没有等着用户回复的消息，请问用户要回复谁');
}

Future<OrbReplyPlan?> _fromItem(
  WorkspaceController w,
  OrbBriefItem item,
  String text,
) async {
  final id = item.channelId;
  final channel = id == null
      ? null
      : [...w.channels, ...w.dms].where((c) => c.id == id).firstOrNull;
  if (channel != null && channel.type == 'dm') {
    return (tool: 'send_message', args: {'channel': channel.id, 'text': text});
  }
  // The messages the item was made from, the newest first (the first id is
  // the row's own).
  RaftMessage? first;
  for (final source in item.sourceIds) {
    try {
      final m = await messageById(w, source, channelRef: id);
      if (_named(m.author, item.who)) first ??= m;
      if (first != null) break;
    } on Object {
      continue;
    }
  }
  if (first != null) {
    return (
      tool: 'reply_in_thread',
      args: {'message': first.id, 'channel': first.channelId, 'text': text},
    );
  }
  // A private conversation named by its place ("@Alice").
  if (item.where.startsWith('@')) {
    final dm = w.dms.where((c) => _named(c.peerLabel, item.where)).firstOrNull;
    if (dm != null) {
      return (tool: 'send_message', args: {'channel': dm.id, 'text': text});
    }
  }
  return null;
}

OrbReplyPlan? _fromPage(WorkspaceController w, String? person, String text) {
  final loc = w.location;
  if ((loc.route != RaftRoute.channel && loc.route != RaftRoute.dm) ||
      loc.thread != null) {
    return null;
  }
  final id = loc.entityId;
  final channel = [
    ?w.channel,
    ...w.channels,
    ...w.dms,
  ].where((c) => c.id == id).firstOrNull;
  if (channel == null) return null;
  if (channel.type == 'dm') {
    if (person != null && !_named(channel.peerLabel, person)) return null;
    return (tool: 'send_message', args: {'channel': channel.id, 'text': text});
  }
  final me = w.client.user?.id;
  bool mentionsMe(Map<String, dynamic> row) =>
      me != null &&
      ((row['mentions'] as List?) ?? const []).any(
        (m) => m is Map && ('${m['id'] ?? m['userId']}' == me),
      );
  final others = [
    for (final row in w.ledger.messages(channel.id).reversed)
      if ('${row['senderId']}' != me &&
          (person == null || _named(RaftMessage(row).author, person)))
        row,
  ];
  if (others.isEmpty) return null;
  final pick = others.where(mentionsMe).firstOrNull ?? others.first;
  return (
    tool: 'reply_in_thread',
    args: {'message': '${pick['id']}', 'channel': channel.id, 'text': text},
  );
}
