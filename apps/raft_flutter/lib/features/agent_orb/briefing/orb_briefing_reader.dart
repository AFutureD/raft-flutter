import 'dart:async';

import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentWorkState;
import 'package:raft_client/raft_client.dart';

import '../../../data/raft_location.dart';
import '../../../data/resource_row_reconcile.dart' show activityItemKey;
import '../../../data/workspace_controller.dart';
import '../../../data/workspace_entity_directory.dart';
import '../../activity_destination.dart';
import '../../agent_mode/agent_activity_feed.dart';
import '../../agent_mode/agent_mode_data.dart';
import 'orb_signals.dart';

/// Reads what a briefing is made of: the Activity rows, the tasks, the agents,
/// and, for each row that may matter, the content behind it (the parent
/// message and the newest replies), because an Activity row is only a
/// template ("X said …, N replies").
///
/// Everything here is a GET: nothing is marked read, nothing is written.
class OrbBriefingReader {
  OrbBriefingReader(
    this.w, {
    required this.now,
    this.fetchTimeout = const Duration(seconds: 6),
    this.maxFetched = 14,
  }) : data = AgentModeData(w, now: now);

  final WorkspaceController w;
  final AgentModeData data;
  final DateTime Function() now;
  final Duration fetchTimeout;

  /// Rows whose content is read; the rest only count as routine.
  final int maxFetched;

  OrbMe get me {
    final m = data.me;
    return OrbMe(id: m.id, names: m.names);
  }

  String get slug =>
      [
        w.server?.string('slug'),
        w.server?.id,
        w.client.serverId,
      ].whereType<String>().where((v) => v.isNotEmpty).firstOrNull ??
      '_';

  // ---- links ---------------------------------------------------------------

  String channelLink(String id, {bool dm = false, String? messageId}) =>
      RaftLocation.at(
        serverSlug: slug,
        route: dm ? RaftRoute.dm : RaftRoute.channel,
        entityId: id,
        query: {'msg': ?messageId},
      ).uri.toString();

  String taskLink(Map<String, dynamic> t) {
    final channel = _s(t['channelId']);
    if (channel == null) {
      return RaftLocation.at(
        serverSlug: slug,
        route: RaftRoute.tasks,
      ).uri.toString();
    }
    final item = _s(t['messageId']);
    return RaftLocation.at(
      serverSlug: slug,
      route: RaftRoute.channel,
      entityId: channel,
      query: {if (item != null) 'task': '$channel:$item'},
    ).uri.toString();
  }

  String agentLink(String id) => RaftLocation.at(
    serverSlug: slug,
    route: RaftRoute.agent,
    entityId: id,
  ).uri.toString();

  static String? _s(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  // ---- messages ------------------------------------------------------------

  static const _maxText = 600;

  OrbMessage? _message(Map<String, dynamic> m) {
    final id = _s(m['id'] ?? m['messageId']);
    if (id == null) return null;
    final me = this.me;
    final senderId = _s(m['senderId']);
    final senderType = _s(m['senderType']);
    final name =
        _s(m['senderDisplayName']) ??
        _s(m['senderName']) ??
        (senderId == null || senderType == null
            ? null
            : data.senderName(senderId, senderType));
    var text = AgentActivityFeed.excerptOf(
      '${m['content'] ?? ''}',
      max: _maxText,
    );
    final attachments = m['attachments'];
    if (text.isEmpty && attachments is List && attachments.isNotEmpty) {
      text = '[附件]';
    }
    return OrbMessage(
      id: id,
      seq: BigInt.tryParse('${m['seq']}'),
      senderId: senderId,
      senderName: name,
      senderType: senderType,
      text: text,
      at: AgentModeData.timeOf(m['createdAt']),
      mentionsMe: _mentionsMe(m, me),
      replyCount: (m['replyCount'] is num)
          ? (m['replyCount'] as num).toInt()
          : 0,
    );
  }

  static bool _mentionsMe(Map<String, dynamic> m, OrbMe me) {
    final list = m['mentions'];
    if (me.id != null && list is List) {
      for (final e in list) {
        if (e is Map && e['id'] == me.id) return true;
      }
    }
    final text = '${m['content'] ?? ''}';
    for (final n in me.names) {
      if (RegExp(
        '@${RegExp.escape(n)}(?![\\w-])',
        caseSensitive: false,
      ).hasMatch(text)) {
        return true;
      }
    }
    return false;
  }

  List<OrbMessage> _messages(Iterable<Map<String, dynamic>> rows) {
    final out = [for (final r in rows) ?_message(r)]
      ..sort((a, b) => (a.seq ?? BigInt.zero).compareTo(b.seq ?? BigInt.zero));
    return out;
  }

  // ---- the Activity ----------------------------------------------------------

  /// The Activity as candidates: the new rows with their content read, the
  /// tasks and the agents that may need the person. [fetched] is how many
  /// rows were read; [skipped] rows were new but not read (counted routine).
  Future<({List<OrbCandidate> candidates, int skipped})> activity() async {
    final results = await Future.wait([
      data.activityRows().then(
        (v) => v,
        onError: (Object _) => <Map<String, dynamic>>[],
      ),
      data.authors().then((_) => null, onError: (Object _) => null),
      _taskCandidates(),
      _agentCandidates(),
    ]);
    final rows = (results[0] as List<Map<String, dynamic>>)
        .where(
          (r) =>
              (((r['unreadCount'] as num?) ?? 0) > 0) ||
              r['kind'] == 'mention_action',
        )
        .toList();
    final tasks = results[2] as List<OrbCandidate>;
    final agents = results[3] as List<OrbCandidate>;

    int priority(Map<String, dynamic> r) {
      if (r['kind'] == 'mention_action' || r['hasMention'] == true) return 0;
      if (r['kind'] == 'dm') return 1;
      if (r['kind'] == 'thread') return r['isFollowing'] == true ? 2 : 3;
      return 4;
    }

    final ranked = [for (final (i, r) in rows.indexed) (i, r)]
      ..sort((a, b) {
        final p = priority(a.$2) - priority(b.$2);
        return p != 0 ? p : a.$1 - b.$1;
      });
    final take = ranked.take(maxFetched).map((e) => e.$2).toList();
    final skipped = ranked.length - take.length;

    final byThread = {
      for (final t in tasks)
        if (_s(t.task?['threadChannelId']) != null)
          _s(t.task!['threadChannelId'])!: t,
    };
    final merged = <String>{};
    final read = await Future.wait([
      for (final row in take) _rowCandidate(row, byThread, merged),
    ]);
    return (
      candidates: [
        for (final c in read) ?c,
        for (final t in tasks)
          if (!merged.contains(t.id)) t,
        ...agents,
      ],
      skipped: skipped,
    );
  }

  Future<OrbCandidate?> _rowCandidate(
    Map<String, dynamic> row,
    Map<String, OrbCandidate> taskByThread,
    Set<String> merged,
  ) async {
    final me = this.me;
    final feed = AgentActivityFeed(
      now: now(),
      myId: me.id,
      channels: w.channels,
      dms: w.dms,
      nameOf: data.senderName,
    );
    final item = feed.itemOf(row);
    final key = activityItemKey(row);
    if (item == null || key == null) return null;
    final kind = '${row['kind']}';
    final thread = kind == 'thread';
    final dm = item.dm;
    final destination = ActivityDestination.fromRow(row, canonical: false);
    final link = destination == null
        ? channelLink(item.channelId ?? '', dm: dm)
        : destination.canonicalLocation(slug).uri.toString();
    final unread = ((row['unreadCount'] as num?) ?? 0).toInt();
    final readId = thread ? _s(row['threadChannelId']) : _s(row['channelId']);

    List<OrbMessage> messages = const [];
    OrbMessage? parent;
    var contentRead = false;
    if (readId != null) {
      try {
        final read = await data
            .conversation(
              readId,
              limit: thread ? 8 : 10,
              withTasks: false,
              parentChannelId: thread ? _s(row['parentChannelId']) : null,
              parentMessageId: thread ? _s(row['parentMessageId']) : null,
            )
            .timeout(fetchTimeout);
        final parentId = thread ? _s(row['parentMessageId']) : null;
        final rows = [
          for (final m in read.rows)
            if (m['id'] != parentId) m,
        ];
        parent = parentId == null
            ? null
            : _messages([
                for (final m in read.rows)
                  if (m['id'] == parentId) m,
              ]).firstOrNull;
        messages = _messages(rows);
        // A channel's unread tail: older messages are not new.
        if (!thread && !dm && messages.length > unread && unread > 0) {
          messages = messages.sublist(messages.length - unread);
        }
        contentRead = messages.isNotEmpty;
      } on Object {
        // The row's own text is all there is; the verdict is a guess.
      }
    }
    if (!contentRead) {
      // The template text, flagged: the classifier reads it as the only
      // message, and the row's mention flag stands in for the @.
      final text = item.excerpt ?? '';
      messages = text.isEmpty
          ? const []
          : [
              OrbMessage(
                id: item.messageId ?? key,
                text: text,
                senderId: _s(
                  row[thread
                      ? 'latestActivitySenderId'
                      : 'lastMessageSenderId'],
                ),
                senderName:
                    item.doer ??
                    (item.waiters.isEmpty ? null : item.waiters.first),
                senderType: _s(
                  row[thread
                      ? 'latestActivitySenderType'
                      : 'lastMessageSenderType'],
                ),
                at: item.at,
              ),
            ];
    }

    final task = taskByThread[_s(row['threadChannelId']) ?? ''];
    if (task != null) merged.add(task.id);
    final topic = parent == null
        ? (item.threadTitle)
        : AgentHeadlines.clean(parent.text, max: 24);
    return OrbCandidate(
      id: key,
      source: kind == 'mention_action'
          ? OrbSource.mentionAction
          : thread
          ? OrbSource.thread
          : dm
          ? OrbSource.dm
          : OrbSource.channel,
      where: item.place ?? '',
      link: link,
      channelId: item.channelId,
      messages: messages,
      parent: parent,
      contentRead: contentRead,
      rowMention: row['hasMention'] == true || kind == 'mention_action',
      following: row['isFollowing'] == true,
      parentMineHint:
          me.id != null && _s(row['parentMessageSenderId']) == me.id,
      unread: unread,
      at: item.at,
      task: task?.task,
      taskCreated: task?.taskCreated ?? false,
      taskAssigned: task?.taskAssigned ?? false,
      taskMentioned: task?.taskMentioned ?? false,
      sourceIds: [key, for (final m in messages.reversed.take(3)) m.id],
      topic: topic == null || topic.isEmpty ? null : topic,
    );
  }

  // ---- tasks and agents ------------------------------------------------------

  OrbCandidate? _taskCandidate(Map<String, dynamic> t) {
    final id = _s(t['id']);
    if (id == null) return null;
    final relation = AgentModeData.relationOf(t, data.me);
    if (!(relation.created || relation.assigned || relation.mentioned)) {
      return null;
    }
    final number = t['taskNumber'];
    final title = AgentHeadlines.clean(
      '${t['title'] ?? ''}\n${t['description'] ?? t['descriptionPreview'] ?? ''}',
      max: 30,
    );
    final channelName = _s(t['channelName']);
    return OrbCandidate(
      id: 'task:$id',
      source: OrbSource.task,
      where: channelName == null ? '任务' : '#$channelName',
      link: taskLink(t),
      channelId: _s(t['channelId']),
      task: t,
      taskCreated: relation.created,
      taskAssigned: relation.assigned,
      taskMentioned: relation.mentioned,
      at: AgentModeData.timeOf(t['updatedAt']),
      sourceIds: [id],
      topic: number is int
          ? '#$number${title.isEmpty ? '' : '「$title」'}'
          : (title.isEmpty ? null : '「$title」'),
      versionKey: '${t['status']}@${t['updatedAt']}',
    );
  }

  Future<List<OrbCandidate>> _taskCandidates({String? channelId}) async {
    final lanes = await Future.wait([
      for (final status in const ['in_review', 'in_progress'])
        data
            .taskLane(status, channelId: channelId)
            .then(
              (v) => v.rows,
              onError: (Object _) => <Map<String, dynamic>>[],
            ),
    ]);
    return [
      for (final lane in lanes)
        for (final t in lane) ?_taskCandidate(t),
    ];
  }

  Future<List<OrbCandidate>> _agentCandidates() async {
    final List<AgentRuntimeInfo> agents;
    try {
      agents = await data.agents();
    } on Object {
      return const [];
    }
    final me = this.me;
    final managed = {
      for (final row in w.entityDirectory.rows(WorkspaceEntityKind.agents))
        if (me.id != null &&
            row['creatorType'] == 'user' &&
            row['creatorId'] == me.id)
          '${row['id']}',
    };
    return [
      for (final a in agents)
        if (a.state == AgentWorkState.blocked)
          OrbCandidate(
            id: 'agent:${a.id}',
            source: OrbSource.agent,
            where: '@${a.name}',
            link: agentLink(a.id),
            agentName: a.name,
            agentBlocked: true,
            agentManaged: managed.contains(a.id),
            agentActivity: a.activity,
            agentSince: a.since,
            sourceIds: [a.id],
            versionKey: 'blocked:${a.activity}',
          ),
    ];
  }

  // ---- one conversation ------------------------------------------------------

  RaftChannel? channelOf(String id) =>
      [...w.channels, ...w.dms].where((c) => c.id == id).firstOrNull;

  /// What is new in one conversation: each unread message that concerns the
  /// person on its own, the threads they started that got replies, and the
  /// channel's tasks.
  Future<({List<OrbCandidate> candidates, int skipped})> conversation(
    String id,
  ) async {
    final channel = channelOf(id);
    final dm = channel?.type == 'dm';
    final name = channel == null
        ? ''
        : dm
        ? '@${channel.json['peerName'] ?? channel.name}'
        : '#${channel.name}';
    final me = this.me;
    final unread = w.unread[id] ?? 0;
    final results = await Future.wait([
      data
          .conversation(id, limit: 30, withTasks: false)
          .then((v) => v.rows, onError: (Object _) => <Map<String, dynamic>>[]),
      if (channel != null && !dm) _taskCandidates(channelId: id),
    ]);
    final all = _messages(results[0] as List<Map<String, dynamic>>);
    final rawById = {
      for (final m in results[0] as List<Map<String, dynamic>>) '${m['id']}': m,
    };
    final tail = all.length <= (unread > 0 ? unread : 5)
        ? all
        : all.sublist(all.length - (unread > 0 ? unread : 5));
    final out = <OrbCandidate>[];
    if (channel == null) {
      // A thread (or a conversation the list does not know): its newest
      // messages are one item.
      out.add(
        OrbCandidate(
          id: 'conversation:$id',
          source: OrbSource.thread,
          where: name,
          link: channelLink(id),
          channelId: id,
          messages: tail,
          unread: tail.length,
          at: tail.lastOrNull?.at,
          following: true,
          sourceIds: [id, for (final m in tail.reversed.take(3)) m.id],
        ),
      );
    } else {
      var threads = 0;
      for (final m in tail) {
        if (m.from(me)) {
          // Mine: only the replies to it can be news.
        } else {
          out.add(
            OrbCandidate(
              id: 'msg:${m.id}',
              source: dm ? OrbSource.dm : OrbSource.channel,
              where: name,
              link: channelLink(id, dm: dm, messageId: m.id),
              channelId: id,
              messages: [m],
              unread: 1,
              at: m.at,
              sourceIds: [m.id],
              versionKey: m.id,
            ),
          );
        }
        final threadId = _s(
          rawById[m.id]?['threadId'] ?? rawById[m.id]?['threadChannelId'],
        );
        if (threadId != null &&
            m.replyCount > 0 &&
            (m.from(me) || m.mentionsMe) &&
            threads < 3) {
          threads++;
          try {
            final replies = _messages(
              (await data
                      .conversation(threadId, limit: 6, withTasks: false)
                      .timeout(fetchTimeout))
                  .rows,
            );
            out.add(
              OrbCandidate(
                id: 'thread:$threadId',
                source: OrbSource.thread,
                where: name,
                link: channelLink(id, dm: dm, messageId: m.id),
                channelId: id,
                messages: replies,
                parent: m,
                parentMineHint: m.from(me),
                unread: 1,
                at: replies.lastOrNull?.at,
                sourceIds: [
                  threadId,
                  for (final r in replies.reversed.take(2)) r.id,
                ],
                topic: AgentHeadlines.clean(m.text, max: 24),
              ),
            );
          } on Object {
            // That thread is left out.
          }
        }
      }
    }
    if (results.length > 1) out.addAll(results[1] as List<OrbCandidate>);
    return (candidates: out, skipped: 0);
  }
}
