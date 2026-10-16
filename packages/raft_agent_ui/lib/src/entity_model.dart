import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'surface_cards.dart' show AgentWorkState;

/// The things the model may point at by id. It never writes their content:
/// the app resolves an [AgentEntityRef] from its own data and draws it, so a
/// card cannot show something that is not there.
enum AgentEntityKind { message, task, agent, channel, member, computer, file }

/// Names of [AgentEntityKind] as the person reads them.
const agentEntityKindLabels = {
  AgentEntityKind.message: '消息',
  AgentEntityKind.task: '任务',
  AgentEntityKind.agent: 'Agent',
  AgentEntityKind.channel: '频道',
  AgentEntityKind.member: '成员',
  AgentEntityKind.computer: '电脑',
  AgentEntityKind.file: '文件',
};

/// How loudly a card speaks. The model picks the level, the theme draws it.
enum AgentEmphasis { normal, high }

/// What a card or callout says about itself: nothing special, good news, or
/// something to watch.
enum AgentTone { neutral, good, warn }

/// `compact` is the one-glance card read at arm's length; `detail` shows more
/// of the same thing.
enum AgentCardDensity { compact, detail }

/// A thing by kind and id.
@immutable
class AgentEntityRef {
  const AgentEntityRef(this.kind, this.id);
  final AgentEntityKind kind;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is AgentEntityRef && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);

  @override
  String toString() => '${kind.name}:$id';
}

/// Draws a person or agent avatar at [size]; the app supplies its own.
typedef AgentAvatarBuilder = Widget Function(BuildContext context, double size);

/// Draws a picture (a cached thumbnail) filling [size].
typedef AgentThumbBuilder = Widget Function(BuildContext context, Size size);

/// What a member is doing right now.
enum AgentPresence { online, away, offline }

const agentPresenceLabels = {
  AgentPresence.online: '在线',
  AgentPresence.away: '离开',
  AgentPresence.offline: '离线',
};

/// What an entity looks like once the app has read it. Strings arrive
/// already worded ("12 分钟前"), so the widgets need no clock or locale.
sealed class AgentEntityData {
  const AgentEntityData();
  AgentEntityKind get kind;

  /// One short phrase naming it, for a table cell or timeline row.
  String get label;
}

String _clip(String text, int max) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return one.characters.length <= max ? one : '${one.characters.take(max)}…';
}

class AgentMessageData extends AgentEntityData {
  const AgentMessageData({
    required this.author,
    required this.text,
    this.time,
    this.channel,
    this.attachmentCount = 0,
    this.avatar,
  });
  final String author, text;
  final String? time, channel;
  final int attachmentCount;
  final AgentAvatarBuilder? avatar;

  @override
  AgentEntityKind get kind => AgentEntityKind.message;
  @override
  String get label => '$author：${_clip(text, 24)}';
}

class AgentTaskData extends AgentEntityData {
  const AgentTaskData({
    required this.title,
    required this.status,
    this.number,
    this.assignee,
    this.channel,
    this.updated,
  });
  final String title;

  /// `todo`, `in_progress`, `in_review`, `done` or `closed`.
  final String status;
  final int? number;
  final String? assignee, channel, updated;

  @override
  AgentEntityKind get kind => AgentEntityKind.task;
  @override
  String get label => number == null ? title : '#$number $title';
}

class AgentAgentData extends AgentEntityData {
  const AgentAgentData({
    required this.name,
    required this.state,
    this.activity,
    this.computer,
    this.since,
    this.avatar,
  });
  final String name;
  final AgentWorkState state;
  final String? activity, computer, since;
  final AgentAvatarBuilder? avatar;

  @override
  AgentEntityKind get kind => AgentEntityKind.agent;
  @override
  String get label => name;
}

class AgentChannelData extends AgentEntityData {
  const AgentChannelData({
    required this.name,
    this.unread = 0,
    this.mentions = 0,
    this.lastActivity,
    this.direct = false,
  });

  /// Without the leading `#`.
  final String name;
  final int unread, mentions;
  final String? lastActivity;

  /// A direct message: shown by name, without `#`.
  final bool direct;

  @override
  AgentEntityKind get kind => AgentEntityKind.channel;
  @override
  String get label => direct ? name : '#$name';
}

class AgentMemberData extends AgentEntityData {
  const AgentMemberData({
    required this.name,
    this.role,
    this.presence = AgentPresence.offline,
    this.avatar,
  });
  final String name;
  final String? role;
  final AgentPresence presence;
  final AgentAvatarBuilder? avatar;

  @override
  AgentEntityKind get kind => AgentEntityKind.member;
  @override
  String get label => name;
}

class AgentComputerData extends AgentEntityData {
  const AgentComputerData({
    required this.name,
    required this.online,
    this.runtimes = const [],
    this.agentCount = 0,
  });
  final String name;
  final bool online;
  final List<String> runtimes;
  final int agentCount;

  @override
  AgentEntityKind get kind => AgentEntityKind.computer;
  @override
  String get label => name;
}

class AgentFileData extends AgentEntityData {
  const AgentFileData({
    required this.name,
    this.type,
    this.size,
    this.isImage = false,
    this.thumbnail,
  });
  final String name;

  /// "PNG", "PDF".
  final String? type, size;
  final bool isImage;

  /// Draws the cached thumbnail of an image; null shows a file icon.
  final AgentThumbBuilder? thumbnail;

  @override
  AgentEntityKind get kind => AgentEntityKind.file;
  @override
  String get label => name;
}

/// What the app knows about a reference right now.
sealed class AgentEntityResolution {
  const AgentEntityResolution();
}

/// Read: draw [data].
class AgentEntityFound extends AgentEntityResolution {
  const AgentEntityFound(this.data);
  final AgentEntityData data;
}

/// Not in the app's data yet, a read is on its way. Another notification
/// follows when it ends.
class AgentEntityLoading extends AgentEntityResolution {
  const AgentEntityLoading();
}

/// Does not exist, was deleted or may not be read. [reason] is worded for
/// the model, which is told.
class AgentEntityMissing extends AgentEntityResolution {
  const AgentEntityMissing(this.reason);
  final String reason;
}

/// The app's side of "render by id". Notifies whenever something it has
/// resolved may have changed (the underlying data changed, a fetch ended).
abstract interface class AgentEntityResolver implements Listenable {
  /// Cheap and synchronous: answers from what the app holds, and starts a
  /// read for what it does not (once, not on every call).
  AgentEntityResolution resolve(AgentEntityRef ref);
}

/// Called (after the frame) when a card could not be drawn from real data:
/// the model learns it pointed at something that is not there.
typedef AgentEntityProblem = void Function(AgentEntityRef ref, String reason);

/// Hands the resolver, and the place to report a missing entity, to the cards
/// below.
class AgentEntityScope extends InheritedWidget {
  const AgentEntityScope({
    super.key,
    required this.resolver,
    this.onProblem,
    required super.child,
  });
  final AgentEntityResolver resolver;
  final AgentEntityProblem? onProblem;

  static AgentEntityScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentEntityScope>();

  @override
  bool updateShouldNotify(AgentEntityScope old) =>
      old.resolver != resolver || old.onProblem != onProblem;
}

/// Resolves [entity] through the nearest [AgentEntityScope], rebuilds when
/// the data changes and reports an unreadable one exactly once.
class AgentEntityBuilder extends StatefulWidget {
  const AgentEntityBuilder({
    super.key,
    required this.entity,
    required this.builder,
  });
  final AgentEntityRef entity;
  final Widget Function(BuildContext context, AgentEntityResolution resolution)
  builder;

  @override
  State<AgentEntityBuilder> createState() => _AgentEntityBuilderState();
}

class _AgentEntityBuilderState extends State<AgentEntityBuilder> {
  AgentEntityResolver? _resolver;
  String? _reported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = AgentEntityScope.maybeOf(context)?.resolver;
    if (next == _resolver) return;
    _resolver?.removeListener(_changed);
    _resolver = next?..addListener(_changed);
  }

  @override
  void dispose() {
    _resolver?.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolver = _resolver;
    final resolution =
        resolver?.resolve(widget.entity) ??
        const AgentEntityMissing('这个界面没有接入数据，无法读取');
    if (resolution is AgentEntityMissing) {
      final key = '${widget.entity}|${resolution.reason}';
      if (_reported != key) {
        _reported = key;
        final scope = AgentEntityScope.maybeOf(context);
        final entity = widget.entity;
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) scope?.onProblem?.call(entity, resolution.reason);
        });
      }
    } else {
      _reported = null;
    }
    return widget.builder(context, resolution);
  }
}
