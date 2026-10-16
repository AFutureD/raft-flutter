import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';

import '../../data/attachment_image_repository.dart';
import '../../data/message_task_cache.dart';
import '../../data/server_task_window.dart';
import '../../data/task_board_reconcile.dart' show mergeTaskFields;
import '../../data/workspace_controller.dart';
import '../../data/workspace_entity_directory.dart';
import '../../platform/attachment_files.dart';
import '../agent_metadata_projection.dart';
import '../attachment_image_loader.dart';
import '../attachment_view.dart' show attachmentIsInlineImage;
import 'agent_mode_data.dart';
import 'agent_surface.dart';

/// Binds the entity cards and blocks of raft_agent_ui to the app: what a card
/// says is read from [WorkspaceController]'s own data by id, and the
/// components the model may compose are added to the catalog with their
/// schemas and validators.

/// Names of the entity and block components.
abstract final class AgentEntityComponents {
  static const entity = 'EntityCard';
  static const table = 'Table';
  static const timeline = 'Timeline';
  static const code = 'CodeBlock';
  static const callout = 'Callout';
  static const confirm = 'ConfirmCard';
  static const choice = 'Choice';
  static const toggle = 'Toggle';
}

// ---- What the person did on an interactive component ----------------------

/// A press on a [AgentEntityComponents.confirm], [AgentEntityComponents.choice]
/// or [AgentEntityComponents.toggle]. The app turns it into the `confirm`
/// tool (or a message to the model); the components only report it.
sealed class AgentInteraction {
  const AgentInteraction(this.nodeId, {this.slot});

  /// The `id` the model gave the component, if any.
  final String? nodeId;

  /// Names the component on its screen ([agentInteractionKey]): what the
  /// owner keeps the answer under, so it can draw (and tell the model) what
  /// the person chose.
  final String? slot;
}

/// Names a component for what the person did on it: its id, else its words.
String agentInteractionKey(SurfaceNode n) =>
    n.id ??
    '${n.component}|${n.string('prompt') ?? n.string('label') ?? n.string('title') ?? ''}';

/// What the person did on a component, kept under [agentInteractionKey]: the
/// index of the option, whether the switch is on, `confirmed` or `cancelled`.
SurfaceNode agentWithInteraction(SurfaceNode n, Map<String, Object?> done) {
  final v = done[agentInteractionKey(n)];
  if (v == null) return n;
  return switch (n.component) {
    AgentEntityComponents.choice => n.copyWith(
      props: {...n.props, '_picked': v},
    ),
    AgentEntityComponents.toggle => n.copyWith(props: {...n.props, 'value': v}),
    AgentEntityComponents.confirm => n.copyWith(
      props: {...n.props, '_result': v},
    ),
    _ => n,
  };
}

class AgentConfirmed extends AgentInteraction {
  const AgentConfirmed(
    super.nodeId, {
    required this.title,
    required this.yes,
    super.slot,
  });
  final String title;

  /// True for 确认, false for 取消.
  final bool yes;
}

class AgentChose extends AgentInteraction {
  const AgentChose(
    super.nodeId, {
    required this.index,
    required this.label,
    this.prompt,
    super.slot,
  });
  final int index;
  final String label;
  final String? prompt;
}

class AgentToggled extends AgentInteraction {
  const AgentToggled(
    super.nodeId, {
    required this.label,
    required this.on,
    super.slot,
  });
  final String label;
  final bool on;
}

/// Where interactions go. Without one the components still show and lock
/// after a press, but nobody hears it.
class AgentInteractionScope extends InheritedWidget {
  const AgentInteractionScope({
    super.key,
    required this.onInteraction,
    required super.child,
  });
  final void Function(AgentInteraction interaction) onInteraction;

  static AgentInteractionScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AgentInteractionScope>();

  @override
  bool updateShouldNotify(AgentInteractionScope old) => false;
}

// ---- The resolver ----------------------------------------------------------

/// Reads entities from the app's own data. It answers from caches first
/// (the entity directory, message windows, the task buckets), starts the one
/// existing read that can fill a gap, and notifies when anything it answered
/// from may have changed, so a card is never stale and never invented.
class WorkspaceEntityResolver extends ChangeNotifier
    implements AgentEntityResolver {
  WorkspaceEntityResolver(this.w, {DateTime Function()? now})
    : _now = now ?? DateTime.now {
    w.addListener(_source);
    w.entityDirectory.addListener(_source);
    _tasksCache = MessageTaskCache.of(w.client)..addListener(_source);
    _events = w.client.events.listen(_event);
  }

  final WorkspaceController w;
  final DateTime Function() _now;
  late final MessageTaskCache _tasksCache;
  late final StreamSubscription<RaftEvent> _events;
  bool _disposed = false;

  /// Tasks read from the server (all lanes), patched by task events.
  final _tasks = <String, Map<String, dynamic>>{};
  Future<void>? _taskRead;
  DateTime? _taskReadAt;

  /// How long a finished task read counts as fresh: a task still missing
  /// after it is not read for again until this passes.
  static const taskReadMaxAge = Duration(seconds: 30);

  /// Messages read by id (not in any held window), failed ones, in flight.
  final _messages = <String, Map<String, dynamic>>{};
  final _messageFailed = <String>{}, _messageReading = <String>{};

  /// Attachments of the held messages by id, rebuilt when the ledger changes.
  Map<
    String,
    ({Map<String, dynamic> metadata, String channelId, String? author})
  >
  _files = const {};
  int _filesRevision = -1;
  String? _filesServer;

  void _source() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    w.removeListener(_source);
    w.entityDirectory.removeListener(_source);
    _tasksCache.removeListener(_source);
    unawaited(_events.cancel());
    super.dispose();
  }

  @override
  AgentEntityResolution resolve(AgentEntityRef ref) => switch (ref.kind) {
    AgentEntityKind.message => _message(ref.id),
    AgentEntityKind.task => _task(ref.id),
    AgentEntityKind.agent => _agent(ref.id),
    AgentEntityKind.channel => _channel(ref.id),
    AgentEntityKind.member => _member(ref.id),
    AgentEntityKind.computer => _computer(ref.id),
    AgentEntityKind.file => _file(ref.id),
  };

  // ---- Shared ----

  List<RaftChannel> get _allChannels => [...w.channels, ...w.dms];

  RaftChannel? _channelById(String? id) {
    if (id == null || id.isEmpty) return null;
    if (w.channel?.id == id) return w.channel;
    for (final c in _allChannels) {
      if (c.id == id) return c;
    }
    return null;
  }

  static String? _s(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;

  String _ago(DateTime at) {
    final d = _now().difference(at);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  String _clock(DateTime at) {
    final a = at.toLocal(), n = _now().toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final hm = '${two(a.hour)}:${two(a.minute)}';
    return a.year == n.year && a.month == n.month && a.day == n.day
        ? hm
        : '${a.month}月${a.day}日 $hm';
  }

  AgentAvatarBuilder _avatar(String name, bool agent, String? url) =>
      (context, size) => RaftAvatarContent(
        name: name,
        kind: agent ? RaftAvatarContentKind.agent : RaftAvatarContentKind.human,
        uploadedUrl: url,
      );

  /// A row of a directory kind, or why there is none: still being read, or
  /// really not there.
  AgentEntityResolution _directory(
    WorkspaceEntityKind kind,
    String label,
    String id,
    String capability,
    Map<String, dynamic>? row,
    AgentEntityData Function(Map<String, dynamic> row) make,
  ) {
    if (row != null) return AgentEntityFound(make(row));
    if (!w.can(capability)) return AgentEntityMissing('你没有权限查看$label');
    final directory = w.entityDirectory..ensure([kind]);
    if (!directory.settled(kind)) return const AgentEntityLoading();
    return AgentEntityMissing('没有 id 为 $id 的$label');
  }

  // ---- Agent, member, computer ----

  AgentEntityResolution _agent(String id) {
    final directory = w.entityDirectory;
    if (directory.agentDeleted(id)) {
      return const AgentEntityMissing('这个 Agent 已被删除');
    }
    return _directory(
      WorkspaceEntityKind.agents,
      ' Agent',
      id,
      'viewAgents',
      directory.agent(id),
      (row) {
        final info = AgentModeData(
          w,
          now: _now,
        ).cachedAgents()?.where((a) => a.id == id).firstOrNull;
        final machineId = _s(row['machineId']);
        final machine = machineId == null
            ? null
            : directory.computer(machineId);
        final name = agentRowName(row);
        return AgentAgentData(
          name: name,
          state: info?.state ?? AgentWorkState.offline,
          activity: info?.activity ?? '已停用',
          since: info?.since,
          computer: _s(machine?['name']),
          model: _s(row['model']),
          avatar: _avatar(name, true, _s(row['avatarUrl'])),
        );
      },
    );
  }

  static const _roles = {
    'owner': '所有者',
    'admin': '管理员',
    'member': '成员',
    'guest': '访客',
  };

  AgentEntityResolution _member(String id) => _directory(
    WorkspaceEntityKind.members,
    '成员',
    id,
    'viewMembers',
    w.entityDirectory.member(id),
    (row) {
      final name = _s(row['displayName']) ?? _s(row['name']) ?? id;
      final role = _s(row['role']);
      return AgentMemberData(
        name: name,
        role: role == null ? null : (_roles[role] ?? role),
        presence: switch (row['online']) {
          true => AgentPresence.online,
          false => AgentPresence.offline,
          _ => null,
        },
        avatar: _avatar(name, false, _s(row['avatarUrl'])),
      );
    },
  );

  AgentEntityResolution _computer(String id) => _directory(
    WorkspaceEntityKind.computers,
    '电脑',
    id,
    'viewMachines',
    w.entityDirectory.computer(id),
    (row) {
      final agents = w.entityDirectory
          .rows(WorkspaceEntityKind.agents)
          .where((a) => a['machineId'] == id && a['deletedAt'] == null)
          .length;
      return AgentComputerData(
        name: _s(row['name']) ?? id,
        online: row['status'] == 'online',
        runtimes: [
          if (row['runtimes'] is List)
            for (final r in row['runtimes'] as List)
              if (r is String) r,
        ],
        agentCount: agents,
        version: _s(
          row['isComputer'] == true
              ? row['computerVersion']
              : row['daemonVersion'],
        ),
      );
    },
  );

  // ---- Channel ----

  AgentEntityResolution _channel(String id) {
    final c = _channelById(id);
    if (c == null) return const AgentEntityMissing('没有这个频道，或你没有加入它');
    final direct = c.type == 'dm';
    final last =
        w.ledger.latestCreatedAt(id) ??
        _time(c.json['lastMessageAt']) ??
        _time(c.json['updatedAt']);
    return AgentEntityFound(
      AgentChannelData(
        name: direct ? c.peerLabel : c.name,
        direct: direct,
        unread: w.unread[id] ?? 0,
        mentioned: w.mentions.contains(id),
        lastActivity: last == null ? null : _ago(last),
        description: direct ? null : _s(c.json['description']),
        memberCount: c.json['memberCount'] is num
            ? (c.json['memberCount'] as num).toInt()
            : null,
      ),
    );
  }

  // ---- Message ----

  AgentEntityResolution _message(String id) {
    Map<String, dynamic>? row;
    for (final c in [..._allChannels, ?w.channel]) {
      row = w.ledger.message(c.id, id);
      if (row != null) break;
    }
    final threadId = w.threadChannelId;
    if (row == null && threadId != null) row = w.ledger.message(threadId, id);
    row ??= _messages[id];
    if (row != null) return AgentEntityFound(_messageData(row));
    if (_messageFailed.contains(id)) {
      return const AgentEntityMissing('没有这条消息，或你没有权限看');
    }
    if (_messageReading.add(id)) unawaited(_readMessage(id));
    return const AgentEntityLoading();
  }

  Future<void> _readMessage(String id) async {
    try {
      final body = await w.query(
        '/messages/context/${Uri.encodeComponent(id)}',
      );
      final rows = body is Map && body['messages'] is List
          ? (body['messages'] as List).whereType<Map>()
          : const <Map>[];
      final hit = rows.where((m) => m['id'] == id).firstOrNull;
      if (hit == null) {
        _messageFailed.add(id);
      } else {
        _messages[id] = Map<String, dynamic>.from(hit);
      }
    } on Object {
      _messageFailed.add(id);
    } finally {
      _messageReading.remove(id);
      _source();
    }
  }

  AgentMessageData _messageData(Map<String, dynamic> row) {
    final m = RaftMessage(row);
    final channel = _channelById(m.channelId);
    final at = m.createdAt;
    final text = AgentHeadlines.plain(m.content, max: 600);
    return AgentMessageData(
      author: m.author,
      text: text.isEmpty ? '（没有文字）' : text,
      time: at == null ? null : _clock(at),
      channel: channel == null || channel.type == 'dm' ? null : channel.name,
      attachmentCount: m.attachments.length,
      avatar: _avatar(
        m.author,
        row['senderType'] == 'agent',
        _s(row['senderAvatarUrl']),
      ),
      reactions: [
        for (final r in row['reactions'] as List? ?? const [])
          if (r is Map && r['emoji'] is String)
            AgentReaction(
              r['emoji'] as String,
              r['reactorIds'] is List
                  ? (r['reactorIds'] as List).length
                  : (r['count'] as num?)?.toInt() ?? 1,
            ),
      ],
      threadCount:
          (w.threadSummaries[m.id] is Map
              ? int.tryParse(
                  '${(w.threadSummaries[m.id] as Map)['replyCount']}',
                )
              : null) ??
          0,
    );
  }

  // ---- Task ----

  /// A task by id, or by number when it is unique. The task buckets of the
  /// channels (kept live by their events) and the server read both count.
  ({Map<String, dynamic>? row, bool ambiguous}) _findTask(String id) {
    final number = int.tryParse(id);
    final byId = <String, Map<String, dynamic>>{};
    void add(Map<String, dynamic> row) {
      final key = '${row['id']}';
      final seen = byId[key];
      if (seen == null ||
          (_time(row['updatedAt']) ?? DateTime(0)).isAfter(
            _time(seen['updatedAt']) ?? DateTime(0),
          )) {
        byId[key] = row;
      }
    }

    for (final row in _tasks.values) {
      add(row);
    }
    for (final c in _allChannels) {
      for (final row
          in _tasksCache.tasks(w, c.id)?.values ??
              const <Map<String, dynamic>>[]) {
        add(row);
      }
    }
    if (number == null) return (row: byId[id], ambiguous: false);
    final hits = byId.values.where((r) => r['taskNumber'] == number).toList();
    if (hits.length > 1) return (row: null, ambiguous: true);
    // A task whose id is all digits is still an id first.
    return (row: byId[id] ?? hits.firstOrNull, ambiguous: false);
  }

  AgentEntityResolution _task(String id) {
    final found = _findTask(id);
    if (found.ambiguous) {
      return AgentEntityMissing('任务编号 $id 在几个频道里都有，请改用任务的 id');
    }
    final row = found.row;
    if (row != null) return AgentEntityFound(_taskData(row));
    if (_taskRead != null) return const AgentEntityLoading();
    final at = _taskReadAt;
    if (at == null || _now().difference(at) > taskReadMaxAge) {
      _taskRead = _readTasks();
      return const AgentEntityLoading();
    }
    return const AgentEntityMissing('没有这个任务，或你没有权限看');
  }

  Future<void> _readTasks() async {
    try {
      final rows = await AgentModeData(w, now: _now).searchTasks('');
      for (final row in rows) {
        final id = row['id'];
        if (id is String) _tasks[id] = row;
      }
    } on Object {
      // Stays missing; the next ask after the freshness window reads again.
    } finally {
      _taskRead = null;
      _taskReadAt = _now();
      _source();
    }
  }

  AgentTaskData _taskData(Map<String, dynamic> row) {
    final at = _time(row['updatedAt']);
    return AgentTaskData(
      number: row['taskNumber'] is int ? row['taskNumber'] as int : null,
      title: AgentHeadlines.plain('${row['title'] ?? ''}', max: 160),
      status: '${row['status'] ?? 'todo'}',
      assignee: _s(row['claimedByName']),
      channel:
          _s(row['channelName']) ?? _channelById(_s(row['channelId']))?.name,
      updated: at == null ? null : _ago(at),
      description: _some(
        AgentHeadlines.plain(
          '${row['description'] ?? row['descriptionPreview'] ?? ''}',
          max: 300,
        ),
      ),
    );
  }

  static String? _some(String s) => s.isEmpty ? null : s;

  void _event(RaftEvent event) {
    if (!event.name.startsWith('task:') || _disposed) return;
    final effect = classifyTaskEvent(event, serverId: w.client.serverId);
    if (effect is! TaskEventPatch) return;
    var changed = false;
    for (final MapEntry(key: id, value: incoming) in effect.patches.entries) {
      if (incoming == null) {
        changed = _tasks.remove(id) != null || changed;
        continue;
      }
      final held = _tasks[id];
      if (held != null) {
        _tasks[id] = mergeTaskFields(held, incoming);
        changed = true;
      } else if (incoming['title'] is String &&
          incoming['status'] is String &&
          incoming['taskNumber'] is int) {
        _tasks[id] = incoming;
        changed = true;
      }
    }
    if (changed) _source();
  }

  // ---- File ----

  void _indexFiles() {
    final revision = w.ledger.revision;
    if (_filesRevision == revision && _filesServer == w.ledger.serverId) {
      return;
    }
    _filesRevision = revision;
    _filesServer = w.ledger.serverId;
    final found =
        <
          String,
          ({Map<String, dynamic> metadata, String channelId, String? author})
        >{};
    final channels = {
      for (final c in [..._allChannels, ?w.channel]) c.id,
      ?w.threadChannelId,
    };
    for (final channelId in channels) {
      for (final message in w.ledger.messages(channelId)) {
        final attachments = message['attachments'];
        if (attachments is! List) continue;
        for (final a in attachments) {
          if (a is Map && a['id'] is String) {
            found[a['id'] as String] = (
              metadata: Map<String, dynamic>.from(a),
              channelId: channelId,
              author:
                  _s(message['senderDisplayName']) ?? _s(message['senderName']),
            );
          }
        }
      }
    }
    _files = found;
  }

  AgentEntityResolution _file(String id) {
    _indexFiles();
    final hit = _files[id];
    if (hit == null) {
      return const AgentEntityMissing('这个文件不在读到的消息里，或你没有权限看');
    }
    final metadata = hit.metadata;
    final name = _s(metadata['filename']) ?? '文件';
    final image = attachmentIsInlineImage(metadata);
    return AgentEntityFound(
      AgentFileData(
        name: name,
        type: _fileType(name, '${metadata['mimeType'] ?? ''}'),
        size: _size(metadata['sizeBytes']),
        author: hit.author,
        isImage: image,
        thumbnail: image
            ? (context, size) => AgentAttachmentThumb(
                controller: w,
                metadata: metadata,
                channelId: hit.channelId,
                size: size,
              )
            : null,
      ),
    );
  }

  static String? _fileType(String name, String mime) {
    final dot = name.lastIndexOf('.');
    if (dot > 0 && dot < name.length - 1 && name.length - dot <= 6) {
      return name.substring(dot + 1).toUpperCase();
    }
    final sub = mime.split(';').first.split('/').last.trim();
    return sub.isEmpty ? null : sub.toUpperCase();
  }

  static String? _size(Object? bytes) {
    if (bytes is! num || bytes < 0) return null;
    if (bytes < 1024) return '${bytes.toInt()} B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// The cached thumbnail of an image attachment, through the same repository
/// and loader the message list uses (the server's 320 px rendition, the
/// decoded image shared with the timeline).
class AgentAttachmentThumb extends StatefulWidget {
  const AgentAttachmentThumb({
    super.key,
    required this.controller,
    required this.metadata,
    required this.channelId,
    required this.size,
    this.files,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String channelId;
  final Size size;
  final AttachmentFiles? files;

  @override
  State<AgentAttachmentThumb> createState() => _AgentAttachmentThumbState();
}

class _AgentAttachmentThumbState extends State<AgentAttachmentThumb> {
  WorkspaceAttachmentImageLease? _lease;
  ImageProvider? _image;
  bool _failed = false;
  bool _begun = false;
  late final AttachmentFiles _files = widget.files ?? AttachmentFiles();

  WorkspaceController get _w => widget.controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_begun) return;
    _begun = true;
    unawaited(_begin(MediaQuery.devicePixelRatioOf(context)));
  }

  Future<void> _begin(double ratio) async {
    final metadata = widget.metadata;
    final key = AttachmentImageKey.fromMetadata(
      scope: _w.attachmentImageScope,
      channelId: widget.channelId,
      metadata: metadata,
      rendition: attachmentThumbnailUrl(metadata) != null
          ? 'thumbnail'
          : 'original',
      target: AttachmentDecodeTarget.box(
        widget.size.width,
        widget.size.height,
        devicePixelRatio: ratio,
        cover: true,
      ),
    );
    bool authorized() => mounted;
    try {
      final ready = _w.peekAttachmentImage(key, authorized: authorized);
      final readyImage = ready?.lease.value;
      if (ready != null && readyImage != null) {
        _lease = ready;
        setState(() => _image = readyImage);
        return;
      }
      ready?.release();
      final lease = _w.acquireAttachmentImage(
        key,
        authorized: authorized,
        load: attachmentImageLoader(
          controller: _w,
          files: _files,
          metadata: metadata,
          key: key,
        ),
        bestAvailable: true,
      );
      _lease = lease;
      final image = await lease.lease.ready;
      if (mounted) setState(() => _image = image);
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _lease?.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      // ignore: raft_lints/avoid_raw_image_decode -- The provider comes from an AttachmentImageRepository lease: already decoded at the target size and shared with the message bubble.
      return Image(
        image: image,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        excludeFromSemantics: true,
      );
    }
    return Center(
      child: Icon(
        _failed ? Icons.broken_image_outlined : Icons.image_outlined,
        size: 34,
        color: RaftAgentTheme.of(context).muted,
      ),
    );
  }
}

/// Gives the entity cards below it the app's data. Owns a
/// [WorkspaceEntityResolver] for [controller] (or draws from [resolver], which
/// the caller keeps); [onProblem] is told when the model pointed at something
/// the app cannot read, so it can answer the model.
class AgentEntityBindingScope extends StatefulWidget {
  const AgentEntityBindingScope({
    super.key,
    required this.controller,
    required this.child,
    this.onProblem,
    this.resolver,
  });
  final WorkspaceController controller;
  final AgentEntityProblem? onProblem;
  final WorkspaceEntityResolver? resolver;
  final Widget child;

  @override
  State<AgentEntityBindingScope> createState() =>
      _AgentEntityBindingScopeState();
}

class _AgentEntityBindingScopeState extends State<AgentEntityBindingScope> {
  WorkspaceEntityResolver? _own;

  WorkspaceEntityResolver get _resolver =>
      widget.resolver ?? (_own ??= WorkspaceEntityResolver(widget.controller));

  @override
  void didUpdateWidget(AgentEntityBindingScope old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller || widget.resolver != null) {
      _own?.dispose();
      _own = null;
    }
  }

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AgentEntityScope(
    resolver: _resolver,
    onProblem: widget.onProblem,
    child: widget.child,
  );
}

/// What the app reads for the [kind] (`task`, `agent` …) thing [id], as one
/// short phrase; null while it is still being read or cannot be.
String? agentEntityLabel(
  WorkspaceEntityResolver resolver,
  String kind,
  String id,
) {
  final k = AgentEntityKind.values.where((v) => v.name == kind).firstOrNull;
  if (k == null) return null;
  final r = resolver.resolve(AgentEntityRef(k, id));
  return r is AgentEntityFound ? r.data.label : null;
}

/// What the app read for the [kind] thing [id]; null while it is still
/// being read or cannot be.
AgentEntityData? agentEntityData(
  WorkspaceEntityResolver resolver,
  String kind,
  String id,
) {
  final k = AgentEntityKind.values.where((v) => v.name == kind).firstOrNull;
  if (k == null) return null;
  final r = resolver.resolve(AgentEntityRef(k, id));
  return r is AgentEntityFound ? r.data : null;
}

// ---- Catalog ---------------------------------------------------------------

/// What the model may write for an id, by kind. 1 to 64 letters, digits,
/// underscores or dashes: an id returned by a read tool, never a `#98`, an
/// `@name` or a name.
final _idFormat = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_\-]{0,63}$');

/// ① to ⑳ or 1 to 20.
final _handleFormat = RegExp(r'^(?:[1-9]|1\d|20|[①-⑳])$');

const _entityKinds = [
  'message',
  'task',
  'agent',
  'channel',
  'member',
  'computer',
  'file',
];
const _tones = ['neutral', 'good', 'warn'];

Map<String, Object?> _string(String doc, [int max = 120]) => {
  'type': 'string',
  'description': doc,
  'maxLength': max,
};

const _entityField = {
  'type': 'string',
  'enum': _entityKinds,
  'description': '要显示的东西的种类',
};

Map<String, Object?> get _idField => _string(
  '读取工具返回的 id（1 到 64 位字母、数字、下划线或短横线），不要写名字、#编号或 @名字；App 按 id 找到真实内容来画，找不到就显示“找不到”',
  64,
);

Map<String, Object?> get _handleField =>
    _string('这张卡的编号，① 到 ⑳（写 1 到 20 也行）；用户说“第二个”“③”时指的就是它', 3);

Map<String, Object?> get _toneField => {
  'type': 'string',
  'enum': _tones,
  'description': 'neutral 普通（默认）、good 好消息、warn 要注意；只选语气，颜色由 App 决定',
};

Map<String, Object?> get _cellRef => {
  'type': 'object',
  'description': '引用一个东西，App 画成一行',
  'properties': {
    'entity': _entityField,
    'id': _idField,
    'handle': _handleField,
  },
  'required': ['entity', 'id'],
};

/// Reasons [entity]/[id]/[handle] are not a reference App can resolve; empty
/// when they are. [path] names where it was written.
List<String> entityRefProblems(
  Object? entity,
  Object? id,
  Object? handle,
  String path,
) {
  final problems = <String>[];
  if (entity is! String || !_entityKinds.contains(entity)) {
    problems.add('$path.entity 只能是 ${_entityKinds.join('、')} 之一');
  }
  if (id is! String || !_idFormat.hasMatch(id)) {
    final text = '${id ?? ''}';
    problems.add(
      '$path.id "$text" 不是 id：要 1 到 64 位字母、数字、下划线或短横线'
      '${text.startsWith('#') || text.startsWith('@') ? '（不要带 # 或 @）' : ''}，'
      '用读取工具返回的 id，不要写名字',
    );
  }
  if (handle != null &&
      (handle is! String || !_handleFormat.hasMatch(handle))) {
    problems.add('$path.handle 只能是 ① 到 ⑳（或 1 到 20）');
  }
  return problems;
}

AgentEntityRef _refOf(String entity, String id) => AgentEntityRef(
  AgentEntityKind.values.firstWhere((k) => k.name == entity),
  id,
);

/// The `display` field of a component (see [agentDisplayKinds] for the
/// element names of each).
Map<String, Object?> _displayField(Iterable<String> kinds) =>
    agentDisplaySchema(kinds);

DisplaySpec? _spec(SurfaceNode n) {
  final d = agentDisplayOf(n.props);
  return d.isEmpty ? null : d;
}

final _entityKindNames = [for (final k in AgentEntityKind.values) k.name];

AgentTone _tone(String? name) => AgentTone.values.firstWhere(
  (t) => t.name == name,
  orElse: () => AgentTone.neutral,
);

int _lineCount(String code) {
  final lines = code.replaceAll('\r\n', '\n').split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  return lines.length;
}

/// The entity and block components, to be added to the standard catalog.
final List<AgentCatalogItem> agentEntityCatalogItems = [
  AgentCatalogItem(
    name: AgentEntityComponents.entity,
    description:
        '按 id 显示 App 里的一个东西（消息、任务、Agent、频道、成员、电脑、文件/图片）。你只给种类和 id，内容由 App 从自己的数据画出来，所以不会出错；id 必须来自读取工具的结果。'
        '怎么显示由 display 决定：level 选预设，show 逐项增减元素（只能写这个种类有的元素，没有数据的元素不会画）。各种类的元素和预设——'
        '${agentDisplayGuide(_entityKindNames).replaceAll('\n', '；')}。'
        '一个列表里的卡片要统一，就在列表（Column、Section、AgentStatusGroup）上写 childDisplay，如不要头像：childDisplay.show.avatar=false；用 update_component 改 display 时只写要变的项，show 里写 null 恢复预设。',
    schema: {
      'type': 'object',
      'properties': {
        'entity': _entityField,
        'id': _idField,
        'handle': _handleField,
        'emphasis': {
          'type': 'string',
          'enum': ['normal', 'high'],
          'description': 'high 把这一张突出出来，只给最重要的一张',
        },
        'tone': _toneField,
        'display': _displayField(_entityKindNames),
      },
      'required': ['entity', 'id'],
    },
    example: {
      'component': 'EntityCard',
      'entity': 'task',
      'id': 'task-id-from-get_task',
      'handle': '1',
      'emphasis': 'high',
    },
    line: (n) => '${n.string('entity') ?? ''} ${n.string('id') ?? ''}',
    validate: (n, path) {
      final refs = entityRefProblems(
        n.string('entity'),
        n.string('id'),
        n.string('handle'),
        path,
      );
      if (refs.isNotEmpty) return refs;
      // The elements are the kind's own: a model card has no `avatar`.
      return DisplaySpec.problems(
        n.props['display'],
        n.string('entity')!,
        '$path.display',
      );
    },
    build: (context, n, _) => HfEntityCard(
      entity: _refOf(n.string('entity')!, n.string('id')!),
      emphasis: n.string('emphasis') == 'high'
          ? AgentEmphasis.high
          : AgentEmphasis.normal,
      tone: _tone(n.string('tone')),
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.table,
    description: '表格：最多 5 列、20 行，单元格是一句短文字，或引用一个东西（App 画成一行）。用来并排比较',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'columns': {
          'type': 'array',
          'minItems': 1,
          'maxItems': AgentBlockLimits.tableColumns,
          'items': _string('列名', 20),
        },
        'rows': {
          'type': 'array',
          'minItems': 1,
          'maxItems': AgentBlockLimits.tableRows,
          'items': {
            'type': 'array',
            'maxItems': AgentBlockLimits.tableColumns,
            'items': {
              'oneOf': [_string('一句短文字', 60), _cellRef],
            },
          },
        },
        'display': _displayField(['Table']),
      },
      'required': ['columns', 'rows'],
    },
    example: {
      'component': 'Table',
      'columns': ['任务', '负责人'],
      'rows': [
        [
          {'entity': 'task', 'id': 'task-id-from-get_task'},
          'Aria',
        ],
      ],
    },
    line: (n) => '表格 ${n.list('rows').length} 行',
    validate: (n, path) {
      final problems = <String>[];
      final width = n.list('columns').length;
      for (final (i, row) in n.list('rows').indexed) {
        if (row is! List) continue;
        if (row.length != width) {
          problems.add('$path.rows[$i] 有 ${row.length} 格，要和列数一样（$width）');
        }
        for (final (j, cell) in row.indexed) {
          if (cell is Map) {
            problems.addAll(
              entityRefProblems(
                cell['entity'],
                cell['id'],
                cell['handle'],
                '$path.rows[$i][$j]',
              ),
            );
          }
        }
      }
      return problems;
    },
    build: (context, n, _) => HfTable(
      columns: [for (final c in n.list('columns')) '$c'],
      rows: [
        for (final row in n.list('rows'))
          if (row is List)
            [
              for (final cell in row)
                if (cell is Map)
                  AgentTableCell.entity(
                    _refOf('${cell['entity']}', '${cell['id']}'),
                    handle: cell['handle'] as String?,
                  )
                else
                  AgentTableCell.text('$cell'),
            ],
      ],
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.timeline,
    description: '时间线：按先后列出发生的事，每项有时间、一句话，可附一个引用的东西',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'items': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 12,
          'items': {
            'type': 'object',
            'properties': {
              'time': _string('时间，如 10:32 或 昨天', 20),
              'title': _string('发生了什么，一句话', 80),
              'entity': _entityField,
              'id': _idField,
              'handle': _handleField,
            },
            'required': ['time', 'title'],
          },
        },
        'display': _displayField(['Timeline']),
      },
      'required': ['items'],
    },
    example: {
      'component': 'Timeline',
      'items': [
        {'time': '09:10', 'title': '创建任务'},
        {
          'time': '10:32',
          'title': '进入验收',
          'entity': 'task',
          'id': 'task-id-from-get_task',
        },
      ],
    },
    line: (n) => '时间线 ${n.list('items').length} 项',
    validate: (n, path) {
      final problems = <String>[];
      for (final (i, item) in n.list('items').indexed) {
        if (item is! Map) continue;
        final at = '$path.items[$i]';
        final hasEntity = item['entity'] != null, hasId = item['id'] != null;
        if (hasEntity != hasId) {
          problems.add('$at 的 entity 和 id 要一起写，或都不写');
        } else if (hasEntity) {
          problems.addAll(
            entityRefProblems(item['entity'], item['id'], item['handle'], at),
          );
        } else if (item['handle'] != null) {
          problems.add('$at 有 handle 就要有 entity 和 id');
        }
      }
      return problems;
    },
    build: (context, n, _) => HfTimeline(
      items: [
        for (final item in n.list('items'))
          if (item is Map)
            AgentTimelineItem(
              time: '${item['time']}',
              title: '${item['title']}',
              entity: item['entity'] == null
                  ? null
                  : _refOf('${item['entity']}', '${item['id']}'),
              handle: item['handle'] as String?,
            ),
      ],
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.code,
    description: '代码或差异（最多 40 行，等宽字体）。format 写 diff 时，+ 开头的行显示绿色、- 开头显示红色',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'code': _string('代码原文，换行用 \\n，最多 40 行', 4000),
        'format': {
          'type': 'string',
          'enum': ['text', 'diff'],
          'description': 'text 普通代码（默认）；diff 差异',
        },
        'title': _string('文件名或语言，可不写', 40),
        'display': _displayField(['CodeBlock']),
      },
      'required': ['code'],
    },
    example: {
      'component': 'CodeBlock',
      'format': 'diff',
      'title': 'lib/main.dart',
      'code': '-final a = 1;\n+final a = 2;',
    },
    line: (n) => '代码 ${_lineCount(n.string('code') ?? '')} 行',
    validate: (n, path) {
      final code = n.string('code') ?? '';
      final lines = _lineCount(code);
      return [
        if (lines > AgentBlockLimits.codeLines)
          '$path.code 有 $lines 行，最多 ${AgentBlockLimits.codeLines} 行：只放关键的几行',
      ];
    },
    build: (context, n, _) => HfCodeBlock(
      code: n.string('code') ?? '',
      diff: n.string('format') == 'diff',
      title: n.string('title'),
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.callout,
    description: '一句话结论或提醒（只一句）。tone 选 good 好消息 / warn 要注意 / neutral 普通',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'text': _string('一句话，不超过 80 字', 80),
        'tone': _toneField,
        'display': _displayField(['Callout']),
      },
      'required': ['text'],
    },
    example: {'component': 'Callout', 'tone': 'good', 'text': '全量检查通过，可以合。'},
    line: (n) => n.string('text') ?? '',
    validate: (n, path) {
      final text = n.string('text') ?? '';
      final sentences = text
          .split(RegExp(r'[。！？!?]|\.\s'))
          .where((s) => s.trim().isNotEmpty)
          .length;
      return [
        if (text.contains('\n') || sentences > 1)
          '$path.text 只写一句话（不要换行，不要几句并列）',
      ];
    },
    build: (context, n, _) => HfCallout(
      text: n.string('text') ?? '',
      tone: _tone(n.string('tone')),
      display: _spec(n),
    ),
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.confirm,
    description: '确认卡：把“将要发生什么”列出来，等用户确认或取消。changes 每行写成“字段: 原值 → 新值”。risk 写 sensitive 表示敏感操作（会更醒目）',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'title': _string('要做的事，一句话，如“把 #98 标记为已完成？”', 60),
        'changes': {
          'type': 'array',
          'minItems': 1,
          'maxItems': AgentBlockLimits.confirmChanges,
          'items': _string('字段: 原值 → 新值', 120),
        },
        'risk': {
          'type': 'string',
          'enum': ['change', 'sensitive'],
          'description': 'change 普通修改（默认）；sensitive 敏感操作',
        },
        'display': _displayField(['ConfirmCard']),
      },
      'required': ['title', 'changes'],
    },
    example: {
      'component': 'ConfirmCard',
      'title': '把 #98 标记为已完成？',
      'changes': ['状态: 等验收 → 已完成'],
      'risk': 'change',
    },
    line: (n) => n.string('title') ?? '',
    validate: (n, path) => [
      for (final (i, line) in n.list('changes').indexed)
        if (line is String && !AgentChange.wellFormed(line))
          '$path.changes[$i] 要写成 "字段: 原值 → 新值"，现在是 "$line"',
    ],
    build: (context, n, _) {
      final scope = context == null
          ? null
          : AgentInteractionScope.maybeOf(context);
      final title = n.string('title') ?? '';
      void report(bool yes) => scope?.onInteraction(
        AgentConfirmed(
          n.id,
          title: title,
          yes: yes,
          slot: agentInteractionKey(n),
        ),
      );
      return HfConfirm(
        message: title,
        changes: [for (final c in n.list('changes')) '$c'],
        risk: n.string('risk') == 'sensitive'
            ? AgentConfirmRisk.sensitive
            : AgentConfirmRisk.change,
        result: switch (n.string('_result')) {
          'confirmed' => AgentConfirmResult.confirmed,
          'cancelled' => AgentConfirmResult.cancelled,
          _ => null,
        },
        display: _spec(n),
        onConfirm: () => report(true),
        onCancel: () => report(false),
      );
    },
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.choice,
    description: '让用户在 2 到 5 个选项里选一个；选了会告诉你选的是第几个',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'prompt': _string('问题，一句话', 60),
        'options': {
          'type': 'array',
          'minItems': 2,
          'maxItems': AgentBlockLimits.choiceOptions,
          'items': _string('选项，短', 40),
        },
      },
      'required': ['options'],
    },
    example: {
      'component': 'Choice',
      'prompt': '合到哪里？',
      'options': ['integration', 'main'],
    },
    line: (n) => n.string('prompt') ?? '',
    validate: (n, path) {
      final options = [for (final o in n.list('options')) '$o'.trim()];
      return [
        if (options.any((o) => o.isEmpty)) '$path.options 不能有空选项',
        if (options.toSet().length != options.length) '$path.options 不能有重复的选项',
      ];
    },
    build: (context, n, _) {
      final scope = context == null
          ? null
          : AgentInteractionScope.maybeOf(context);
      return HfChoice(
        prompt: n.string('prompt'),
        options: [for (final o in n.list('options')) '$o'],
        selected: n.integer('_picked'),
        onChoose: (index, label) => scope?.onInteraction(
          AgentChose(
            n.id,
            index: index,
            label: label,
            prompt: n.string('prompt'),
            slot: agentInteractionKey(n),
          ),
        ),
      );
    },
  ),
  AgentCatalogItem(
    name: AgentEntityComponents.toggle,
    description: '一个开关；用户拨动了会告诉你现在是开还是关',
    focusable: false,
    schema: {
      'type': 'object',
      'properties': {
        'label': _string('开关说明，一句话', 60),
        'value': {'type': 'boolean', 'description': '现在是否打开，默认关'},
      },
      'required': ['label'],
    },
    example: {'component': 'Toggle', 'label': '完成后通知我', 'value': false},
    line: (n) => n.string('label') ?? '',
    build: (context, n, _) {
      final scope = context == null
          ? null
          : AgentInteractionScope.maybeOf(context);
      final label = n.string('label') ?? '';
      return HfToggle(
        label: label,
        value: n.flag('value') ?? false,
        onChanged: (on) => scope?.onInteraction(
          AgentToggled(
            n.id,
            label: label,
            on: on,
            slot: agentInteractionKey(n),
          ),
        ),
      );
    },
  ),
];
