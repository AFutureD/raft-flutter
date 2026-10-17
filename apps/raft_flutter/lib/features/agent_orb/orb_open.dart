import 'nav/orb_resolver.dart';

/// "打开 task 136", "进入动态", "去 raft-flutter", "跳到 Cody 的私信": the words
/// of a request to GO somewhere, and nothing else.
final _openVerb = RegExp(
  r'^(?:(?:请你?|帮我|麻烦|那就?|好[，,]?|嗯[，,]?)\s*)*(?:打开|进入|跳到|转到|去|到)\s*',
);

/// What follows the verb is only the place: no second clause or question.
final _more = RegExp(r'[，,。；;！!？?]|看看|谁|什么|怎么|有没有|吗|呢');

/// The arguments of the `navigate` call that "打开 X" means, when X is one
/// place the App's resolver is sure of (a task number, a page, a channel, a
/// private conversation); null when it is not an order to open one place, or
/// the place is not sure. The model still decides everything that is not this
/// plain.
Map<String, Object?>? orbOpenArgs(String said, OrbDirectory directory) {
  final s = said.trim();
  final verb = _openVerb.firstMatch(s);
  if (verb == null) return null;
  final rest = s.substring(verb.end).trim();
  if (rest.isEmpty || rest.length > 30 || _more.hasMatch(rest)) return null;
  final match = resolveOrbTarget(rest, directory).match;
  if (match == null || match.score < .99) return null;
  return switch (match.kind) {
    OrbKind.task when match.data['number'] is int => {
      'task_number': match.data['number'],
      if (match.data['channelHint'] is String &&
          (match.data['channelHint'] as String).isNotEmpty)
        'channel': match.data['channelHint'],
    },
    OrbKind.page => {'page': match.id},
    OrbKind.channel => {'channel_id': match.id},
    OrbKind.dm => {'dm_id': match.id},
    _ => null,
  };
}
