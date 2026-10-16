import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';


/// What an agent is doing right now, as the person reads it.
enum AgentWorkState { busy, idle, blocked, offline }

/// Labels for [AgentWorkState]; apps may pass localized ones.
const agentWorkStateLabels = {
  AgentWorkState.busy: '在忙',
  AgentWorkState.idle: '空闲',
  AgentWorkState.blocked: '卡住了',
  AgentWorkState.offline: '离线',
};

/// Labels for task statuses.
const agentTaskStatusLabels = {
  'todo': '待办',
  'in_progress': '进行中',
  'in_review': '等验收',
  'done': '已完成',
  'closed': '已关闭',
};

/// ① to ⑳ for 1 to 20, else the handle as written.
String agentHandleGlyph(String handle) {
  const circled = '①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳';
  final n = int.tryParse(handle);
  if (n != null && n >= 1 && n <= 20) return circled[n - 1];
  return handle;
}

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

/// One emoji and how many people used it.
@immutable
class AgentReaction {
  const AgentReaction(this.emoji, this.count);
  final String emoji;
  final int count;
}

class AgentMessageData extends AgentEntityData {
  const AgentMessageData({
    required this.author,
    required this.text,
    this.time,
    this.channel,
    this.attachmentCount = 0,
    this.avatar,
    this.reactions = const [],
    this.threadCount = 0,
  });
  final String author, text;
  final String? time, channel;
  final int attachmentCount;
  final AgentAvatarBuilder? avatar;
  final List<AgentReaction> reactions;

  /// How many replies the message has in its thread.
  final int threadCount;

  @override
  AgentEntityKind get kind => AgentEntityKind.message;
  @override
  String get label => '$author：${_clip(text, 20)}';
}

class AgentTaskData extends AgentEntityData {
  const AgentTaskData({
    required this.title,
    required this.status,
    this.number,
    this.assignee,
    this.channel,
    this.updated,
    this.description,
    this.latestProgress,
  });
  final String title;

  /// `todo`, `in_progress`, `in_review`, `done` or `closed`.
  final String status;
  final int? number;
  final String? assignee, channel, updated;

  /// What the task asks for, and the last thing said about it, already
  /// worded ("Grok · 10:32  已修复").
  final String? description, latestProgress;

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
    this.channel,
    this.model,
  });
  final String name;
  final AgentWorkState state;
  final String? activity, computer, since;

  /// The channel it is working in, and the model it runs.
  final String? channel, model;
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
    this.mentioned = false,
    this.lastActivity,
    this.direct = false,
    this.description,
    this.memberCount,
  });

  /// Without the leading `#`.
  final String name;
  final int unread;

  /// Someone @-mentioned the person in the unread messages.
  final bool mentioned;
  final String? lastActivity;

  /// A direct message: shown by name, without `#`.
  final bool direct;
  final String? description;
  final int? memberCount;

  @override
  AgentEntityKind get kind => AgentEntityKind.channel;
  @override
  String get label => direct ? name : '#$name';
}

class AgentMemberData extends AgentEntityData {
  const AgentMemberData({
    required this.name,
    this.role,
    this.presence,
    this.avatar,
  });
  final String name;
  final String? role;

  /// Null when the app does not know (nothing is claimed then).
  final AgentPresence? presence;
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
    this.version,
  });
  final String name;
  final bool online;
  final String? version;
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
    this.author,
  });
  final String name;

  /// Who uploaded it.
  final String? author;

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


/// What an entity says, as JSON: what travels to the TV, which has no
/// workspace of its own. The avatar and thumbnail builders do not travel.
Map<String, Object?> agentEntityToJson(AgentEntityData d) => switch (d) {
  AgentMessageData() => {
    'kind': 'message',
    'author': d.author,
    'text': d.text,
    'time': d.time,
    'channel': d.channel,
    'attachmentCount': d.attachmentCount,
    'reactions': [
      for (final r in d.reactions) [r.emoji, r.count],
    ],
    'threadCount': d.threadCount,
  },
  AgentTaskData() => {
    'kind': 'task',
    'title': d.title,
    'status': d.status,
    'number': d.number,
    'assignee': d.assignee,
    'channel': d.channel,
    'updated': d.updated,
    'description': d.description,
    'latestProgress': d.latestProgress,
  },
  AgentAgentData() => {
    'kind': 'agent',
    'name': d.name,
    'state': d.state.name,
    'activity': d.activity,
    'computer': d.computer,
    'since': d.since,
    'channel': d.channel,
    'model': d.model,
  },
  AgentChannelData() => {
    'kind': 'channel',
    'name': d.name,
    'unread': d.unread,
    'mentioned': d.mentioned,
    'lastActivity': d.lastActivity,
    'direct': d.direct,
    'description': d.description,
    'memberCount': d.memberCount,
  },
  AgentMemberData() => {
    'kind': 'member',
    'name': d.name,
    'role': d.role,
    'presence': d.presence?.name,
  },
  AgentComputerData() => {
    'kind': 'computer',
    'name': d.name,
    'online': d.online,
    'runtimes': d.runtimes,
    'agentCount': d.agentCount,
    'version': d.version,
  },
  AgentFileData() => {
    'kind': 'file',
    'name': d.name,
    'type': d.type,
    'size': d.size,
    'isImage': d.isImage,
    'author': d.author,
  },
};

/// The inverse of [agentEntityToJson]; null for anything it does not know.
AgentEntityData? agentEntityFromJson(Object? json) {
  if (json is! Map) return null;
  String? s(String k) => json[k] is String ? json[k] as String : null;
  int? i(String k) => json[k] is int ? json[k] as int : null;
  final name = s('name') ?? '';
  switch (json['kind']) {
    case 'message':
      return AgentMessageData(
        author: s('author') ?? '',
        text: s('text') ?? '',
        time: s('time'),
        channel: s('channel'),
        attachmentCount: i('attachmentCount') ?? 0,
        reactions: [
          for (final r in (json['reactions'] as List? ?? const []))
            if (r is List && r.length == 2 && r[1] is int)
              AgentReaction('${r[0]}', r[1] as int),
        ],
        threadCount: i('threadCount') ?? 0,
      );
    case 'task':
      return AgentTaskData(
        title: s('title') ?? '',
        status: s('status') ?? 'todo',
        number: i('number'),
        assignee: s('assignee'),
        channel: s('channel'),
        updated: s('updated'),
        description: s('description'),
        latestProgress: s('latestProgress'),
      );
    case 'agent':
      return AgentAgentData(
        name: name,
        state: AgentWorkState.values.firstWhere(
          (e) => e.name == json['state'],
          orElse: () => AgentWorkState.idle,
        ),
        activity: s('activity'),
        computer: s('computer'),
        since: s('since'),
        channel: s('channel'),
        model: s('model'),
      );
    case 'channel':
      return AgentChannelData(
        name: name,
        unread: i('unread') ?? 0,
        mentioned: json['mentioned'] == true,
        lastActivity: s('lastActivity'),
        direct: json['direct'] == true,
        description: s('description'),
        memberCount: i('memberCount'),
      );
    case 'member':
      return AgentMemberData(
        name: name,
        role: s('role'),
        presence: AgentPresence.values
            .where((e) => e.name == json['presence'])
            .firstOrNull,
      );
    case 'computer':
      return AgentComputerData(
        name: name,
        online: json['online'] == true,
        runtimes: [for (final r in (json['runtimes'] as List? ?? const [])) '$r'],
        agentCount: i('agentCount') ?? 0,
        version: s('version'),
      );
    case 'file':
      return AgentFileData(
        name: name,
        type: s('type'),
        size: s('size'),
        isImage: json['isImage'] == true,
        author: s('author'),
      );
  }
  return null;
}

/// Answers from a fixed set of entities (what a frame carried), by kind and
/// id: the TV's resolver. Never changes, never reads anything.
class AgentStaticEntityResolver extends ChangeNotifier
    implements AgentEntityResolver {
  AgentStaticEntityResolver(this._entities);

  /// A frame's `entities`: `kind:id` to the JSON of [agentEntityToJson].
  factory AgentStaticEntityResolver.fromJson(Object? json) {
    final out = <String, AgentEntityData>{};
    if (json is Map) {
      for (final e in json.entries) {
        final d = agentEntityFromJson(e.value);
        if (d != null) out['${e.key}'] = d;
      }
    }
    return AgentStaticEntityResolver(out);
  }
  final Map<String, AgentEntityData> _entities;

  @override
  AgentEntityResolution resolve(AgentEntityRef ref) {
    final d = _entities['${ref.kind.name}:${ref.id}'];
    return d == null
        ? const AgentEntityMissing('这块屏幕里没有它的内容')
        : AgentEntityFound(d);
  }
}
