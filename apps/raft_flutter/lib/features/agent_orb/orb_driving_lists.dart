import 'briefing/orb_briefing_models.dart';
import 'orb_driving_rows.dart';
import 'orb_driving_surface.dart';

/// Why a list could not be made (said to the person as it is).
class OrbListError implements Exception {
  const OrbListError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The list kind a tool's `kind` argument names; null for any other word.
OrbListKind? orbListKindOf(Object? name) => switch ('$name'.trim()) {
  'unread' || '未读' => OrbListKind.unread,
  'recent' || '最近' || '动态' => OrbListKind.recent,
  'mentions' || 'mention' || '点名' || '@我' => OrbListKind.mentions,
  'tasks' || 'task' || '任务' => OrbListKind.tasks,
  'channel' || '频道' => OrbListKind.channel,
  'person' || 'dm' || '人' || '私信' => OrbListKind.person,
  _ => null,
};

/// The most messages a channel's or a person's list holds (three pages).
const orbConversationRows = 12;

/// Makes the list of [kind] from what the app has already read.
///
/// [activity] gives the Activity briefing (unread and the ones that name the
/// person are rows of it); [read] runs one of the orb's read tools
/// (`list_tasks`, `read_conversation`) and returns its result. Throws an
/// [OrbListError] with the reason when there is no list.
Future<OrbList> orbReadDrivingList({
  required OrbListKind kind,
  String target = '',
  required Future<OrbBriefing> Function() activity,
  required Future<Map<String, Object?>> Function(
    String tool,
    Map<String, Object?> args,
  )
  read,
}) async {
  switch (kind) {
    case OrbListKind.results:
    case OrbListKind.summary:
      throw const OrbListError('这种列表要先读了才能列出来');
    case OrbListKind.unread:
    case OrbListKind.mentions:
    case OrbListKind.recent:
      final OrbBriefing b;
      try {
        b = await activity();
      } on Object {
        throw const OrbListError('动态还没读出来，稍后再试');
      }
      return orbListOfBriefing(b, kind)!;
    case OrbListKind.tasks:
      final r = await read('list_tasks', const {'assignee': 'me', 'limit': 12});
      _check(r);
      return orbListOfTasks(r);
    case OrbListKind.channel:
    case OrbListKind.person:
      final name = target.trim();
      if (name.isEmpty) throw const OrbListError('要说是哪个频道，或者是谁');
      final r = await read('read_conversation', {
        'conversation': name,
        'limit': orbConversationRows,
      });
      _check(r);
      return orbListOfConversation(r);
  }
}

void _check(Map<String, Object?> result) {
  final candidates = result['candidates'];
  if (candidates is List && candidates.isNotEmpty) {
    final names = [
      for (final c in candidates.take(3))
        if (c is Map) '${c['title'] ?? c['name'] ?? ''}',
    ].where((n) => n.isNotEmpty).join('、');
    throw OrbListError('有几个都像：$names，要说清楚是哪个');
  }
  final error = result['error'];
  if (error != null) throw OrbListError('$error');
}
