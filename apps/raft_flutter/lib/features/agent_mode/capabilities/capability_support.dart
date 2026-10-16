import 'package:raft_client/raft_client.dart';

import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../agent_mode_data.dart' show AgentHeadlines;
import 'agent_capability.dart';

/// Shared helpers of the capability definitions.

Map<String, Object?> objectSchema(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};

Map<String, Object?> strArg(
  String description, {
  List<String>? values,
  int max = 120,
}) => {
  'type': 'string',
  'description': description,
  'maxLength': max,
  'enum': ?values,
};

Map<String, Object?> intArg(
  String description, {
  int? min,
  int? max,
  int? dflt,
}) => {
  'type': 'integer',
  'description': description,
  'minimum': ?min,
  'maximum': ?max,
  'default': ?dflt,
};

Map<String, Object?> boolArg(String description) => {
  'type': 'boolean',
  'description': description,
};

const noArgs = <String, Object?>{'type': 'object', 'properties': {}};

/// Rows a model reads are short: one line of text, never a whole message.
String clip(Object? v, [int max = 200]) =>
    AgentHeadlines.plain('${v ?? ''}', max: max);

String? text(Object? v) {
  final s = v is String ? v.trim() : null;
  return s == null || s.isEmpty ? null : s;
}

/// A server timestamp for the model: local `MM-dd HH:mm`.
String? stamp(Object? v) {
  final at = v is String ? DateTime.tryParse(v)?.toLocal() : null;
  if (at == null) return null;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(at.month)}-${two(at.day)} ${two(at.hour)}:${two(at.minute)}';
}

/// Drops keys with null or empty-text values so results stay compact (an
/// empty list stays: "nothing found" is an answer).
Map<String, Object?> compact(Map<String, Object?> m) => {
  for (final e in m.entries)
    if (e.value != null && e.value != '') e.key: e.value,
};

String _norm(String v) => v.toLowerCase().replaceAll(RegExp(r'[#\s_\-]'), '');

/// A channel or DM by id, name (`#general`, `general`) or the other person's
/// name for a DM. Throws [AgentCapabilityError] with candidates when the
/// words fit several, and when nothing fits.
RaftChannel channelByRef(WorkspaceController w, String ref) {
  final all = [...w.channels, ...w.dms];
  final byId = all.where((c) => c.id == ref.trim()).firstOrNull;
  if (byId != null) return byId;
  final want = _norm(ref);
  String label(RaftChannel c) => c.type == 'dm' ? c.peerLabel : c.name;
  var hits = all.where((c) => _norm(label(c)) == want).toList();
  if (hits.isEmpty) {
    hits = all
        .where((c) => want.isNotEmpty && _norm(label(c)).contains(want))
        .toList();
  }
  if (hits.length == 1) return hits.single;
  if (hits.isEmpty) {
    throw AgentCapabilityError('没有叫“$ref”的频道或私信');
  }
  throw AgentCapabilityError(
    '“$ref”对得上多个频道，请问用户是哪一个',
    candidates: [for (final c in hits.take(6)) channelRow(w, c)],
  );
}

Map<String, Object?> channelRow(WorkspaceController w, RaftChannel c) =>
    compact({
      'id': c.id,
      'name': c.type == 'dm' ? c.peerLabel : c.name,
      'type': c.type,
      'description': c.description.isEmpty ? null : clip(c.description, 100),
      'unread': (w.unread[c.id] ?? 0) == 0 ? null : w.unread[c.id],
      'mention': w.mentions.contains(c.id) ? true : null,
      'archived': c.archived ? true : null,
      'joined': c.type == 'dm' || c.joined ? null : false,
    });

/// A compact message row: who, when, what, and the ids to open it.
Map<String, Object?> messageRow(Map<String, dynamic> m) => compact({
  'id': m['id'] ?? m['messageId'],
  'channelId': m['channelId'],
  'channel': m['channelName'],
  'from': m['senderDisplayName'] ?? m['senderName'],
  'senderId': m['senderId'],
  'senderType': m['senderType'],
  'time': stamp(m['createdAt']),
  'text': clip(m['content'] ?? m['preview'] ?? m['text'], 240),
  'threadId': m['threadId'] ?? m['threadChannelId'],
  'replyCount': m['replyCount'],
  'seq': m['seq'],
});

List<Map<String, dynamic>> mapRows(Object? v) => [
  if (v is List)
    for (final r in v)
      if (r is Map) Map<String, dynamic>.from(r),
];

/// The list inside a response that is a bare list or `{key: [...]}`.
List<Map<String, dynamic>> rowsOf(Object? body, List<String> keys) {
  if (body is List) return mapRows(body);
  if (body is Map) {
    for (final k in keys) {
      if (body[k] is List) return mapRows(body[k]);
    }
  }
  return const [];
}

/// `limit` capped to what a spoken answer can use.
int limitOf(Map<String, Object?> args, {int dflt = 10, int max = 30}) =>
    ((args['limit'] as int?) ?? dflt).clamp(1, max);

/// The directory rows of [kind], read from the server first when the app
/// holds none yet (a failed read leaves whatever is held).
Future<List<Map<String, dynamic>>> directoryRows(
  WorkspaceController w,
  WorkspaceEntityKind kind,
) async {
  final d = w.entityDirectory;
  if (d.rows(kind).isEmpty) {
    try {
      await d.refresh(kind).timeout(const Duration(seconds: 6));
    } on Object {
      // Fall back to whatever is held.
    }
  }
  return d.rows(kind);
}
