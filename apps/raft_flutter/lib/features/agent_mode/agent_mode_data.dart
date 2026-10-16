import 'dart:async';
import 'dart:convert';

import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_client/raft_client.dart';

import '../../data/workspace_controller.dart';
import '../../data/workspace_entity_directory.dart';
import '../agent_metadata_projection.dart';
import 'agent_headlines.dart';

/// What the person is asked to do with an item. Only [approve] writes.
enum AgentAction { approve, reply, open }

/// One line of a task's thread, shown as the latest progress.
class AgentProgressLine {
  const AgentProgressLine({
    required this.who,
    required this.time,
    required this.text,
  });
  final String who, time, text;
}

/// A task or thread that moves along without the person: the collapsed
/// "team progress" row lists these.
class AgentTeamItem {
  const AgentTeamItem({
    required this.id,
    required this.headline,
    required this.channelName,
    required this.who,
  });
  final String id, headline, channelName, who;
}

/// One proactive item: what happened, what it asks of the person, and why it
/// ranks where it does.
class AgentAttentionItem {
  const AgentAttentionItem({
    required this.id,
    required this.priority,
    required this.headline,
    required this.ask,
    required this.reason,
    required this.at,
    this.askLine,
    this.action = AgentAction.open,
    this.canApprove = false,
    this.score = 0,
    this.waitValue = 1,
    this.waitUnit = '小时',
    this.idle = false,
    this.waiters = const [],
    this.doer,
    this.channelId,
    this.channelName,
    this.threadTitle,
    this.taskId,
    this.taskNumber,
    this.progress = const [],
  });

  /// Task id for tasks, `mention:<thread or channel id>` for mentions.
  final String id;
  final AgentPriority priority;

  /// One sentence: who did what, and what the person is asked.
  final String headline;

  /// The verb of the ask: 验收 / 确认 / 回答 / 解除阻塞.
  final String ask;

  /// The ask as shown in the card ("验收「改名」"). Defaults to [ask].
  final String? askLine;
  final AgentAction action;

  /// The task can be set to done by this person right now.
  final bool canApprove;

  /// The one sticker: 点名找你 / 你派的任务 / 2 人在等 / 卡住了 …
  final String reason;

  /// Waiting time as a number and a unit ("24", "小时").
  final int waitValue;
  final String waitUnit;

  /// In progress without movement (reads "5 小时没动") rather than waiting.
  final bool idle;
  final DateTime at;
  final double score;

  /// People other than the user who wait on this.
  final List<String> waiters;

  /// Who did the work (claimer) or wrote the message.
  final String? doer;
  final String? channelId, channelName, threadTitle, taskId;
  final int? taskNumber;

  /// The last few thread lines, oldest first.
  final List<AgentProgressLine> progress;

  AgentAttentionItem withProgress(List<AgentProgressLine> lines) =>
      _copy(progress: lines);

  /// The same item with another sentence on its card.
  AgentAttentionItem withHeadline(String text) => _copy(headline: text);

  AgentAttentionItem _copy({
    String? headline,
    List<AgentProgressLine>? progress,
  }) => AgentAttentionItem(
    id: id,
    priority: priority,
    headline: headline ?? this.headline,
    ask: ask,
    reason: reason,
    at: at,
    askLine: askLine,
    action: action,
    canApprove: canApprove,
    score: score,
    waitValue: waitValue,
    waitUnit: waitUnit,
    idle: idle,
    waiters: waiters,
    doer: doer,
    channelId: channelId,
    channelName: channelName,
    threadTitle: threadTitle,
    taskId: taskId,
    taskNumber: taskNumber,
    progress: progress ?? this.progress,
  );

  String get askText => askLine ?? ask;
  AgentProgressLine? get quote => progress.isEmpty ? null : progress.last;
  String get waitLabel =>
      idle ? '$waitValue $waitUnit没动' : '等了 $waitValue $waitUnit';
  String get waitingText => waiters.isEmpty ? '' : '${waiters.join('、')} 在等你';

  /// "「title」任务 #1" or "「title」讨论": what the chip row names.
  String get threadKind => taskNumber == null ? '讨论' : '任务 #$taskNumber';

  /// The one-line reason this is the most urgent thing.
  String get urgent {
    final lead = doer ?? (waiters.isEmpty ? '有人' : waiters.first);
    final others = [
      for (final n in waiters)
        if (n != lead) n,
    ];
    final tail = others.isEmpty ? '' : '，${others.join('、')} 也在等你';
    final wait = '$waitValue $waitUnit';
    return switch (priority) {
      AgentPriority.blocked => '$lead 的任务已经 $wait没动$tail',
      AgentPriority.mention => '$lead 点名了你，已经等了 $wait$tail',
      _ => '$lead 的$ask已经等了 $wait$tail',
    };
  }
}

/// Everything agent mode asks the person to look at, as one accepted result.
class AgentAttention {
  const AgentAttention({
    required this.items,
    this.team = const [],
    int? teamCount,
    this.capped = false,
    // ignore: prefer_initializing_formals -- a private field cannot be a named parameter
  }) : _teamCount = teamCount;

  static const scopeNote = '只统计你创建、指派给你、或点名你确认的事项';

  /// Decisions, then blocked, then mentions; each by descending score.
  final List<AgentAttentionItem> items;
  final List<AgentTeamItem> team;
  final int? _teamCount;

  /// A source list hit the query limit: counts are lower bounds.
  final bool capped;

  List<AgentAttentionItem> _of(AgentPriority p) => [
    for (final i in items)
      if (i.priority == p) i,
  ];
  List<AgentAttentionItem> get decisions => _of(AgentPriority.decision);
  List<AgentAttentionItem> get blocked => _of(AgentPriority.blocked);
  List<AgentAttentionItem> get mentions => _of(AgentPriority.mention);
  int get decisionCount => decisions.length;
  int get blockedCount => blocked.length;
  int get mentionCount => mentions.length;
  int get teamCount => _teamCount ?? team.length;
  String get teamLabel => '$teamCount${capped ? '+' : ''}';
  bool get isEmpty => items.isEmpty;
  AgentAttentionItem? get top => items.isEmpty ? null : items.first;
  String? get urgent => top?.urgent;

  /// The same result without [ids] (snoozed or just approved).
  AgentAttention without(Set<String> ids) => ids.isEmpty
      ? this
      : AgentAttention(
          items: [
            for (final i in items)
              if (!ids.contains(i.id)) i,
          ],
          team: team,
          teamCount: _teamCount,
          capped: capped,
        );

  /// One spoken sentence, also what the agent knows about the screen.
  String get summary {
    if (isEmpty) return '现在没有需要你处理的事。';
    final parts = [
      if (decisionCount > 0) '$decisionCount 件等你决定',
      if (blockedCount > 0) '$blockedCount 件卡住了',
      if (mentionCount > 0) '$mentionCount 处点名你',
    ];
    return '${parts.join('，')}。';
  }

  /// What the TV mirror shows: the top three, no actions.
  Map<String, Object?> tvFrame({required String caption}) => {
    'decision': decisionCount,
    'blocked': blockedCount,
    'mention': mentionCount,
    'caption': caption,
    'items': [
      for (var n = 0; n < items.length && n < 3; n++)
        {
          'rank': n + 1,
          'priority': items[n].priority.name,
          'reason': items[n].reason,
          'channel': items[n].channelName ?? '',
          'headline': items[n].headline,
          'waitValue': items[n].waitValue,
          'waitUnit': items[n].waitUnit,
          'idle': items[n].idle,
          'urgent': n == 0,
        },
    ],
  };
}

/// What a headline is built from. A summarizer can use the same input.
class AgentHeadlineInput {
  const AgentHeadlineInput({
    required this.status,
    required this.text,
    this.claimer,
    this.number,
    this.idleHours,
  });

  /// `in_review` or `in_progress`.
  final String status;

  /// Title and description joined: the full content, not just the first line.
  final String text;

  /// Who did the work; null when unknown or the user themself.
  final String? claimer;
  final int? number;
  final int? idleHours;
}

/// Turns a task into the sentence on its card. The rule writer is
/// deterministic; a summarizer can implement this later without touching the
/// data or the UI.
abstract interface class AgentHeadlineWriter {
  String write(AgentHeadlineInput input);
}

class RuleHeadlineWriter implements AgentHeadlineWriter {
  const RuleHeadlineWriter();

  @override
  String write(AgentHeadlineInput i) {
    final clean = AgentHeadlines.clean(i.text);
    final n = i.number == null ? '任务' : '任务 #${i.number}';
    if (i.status == 'in_progress') {
      final who = i.claimer == null ? '' : '${i.claimer} 的';
      final what = clean.isEmpty ? n : '「$clean」';
      return '$who$what${AgentHeadlines.duration(i.idleHours ?? 0)}没动，卡住了';
    }
    final ask = AgentHeadlines.askVerb(i.text);
    final who = i.claimer;
    if (who != null) {
      return clean.isEmpty ? '$who 完成了$n，等你$ask' : '$who 完成了「$clean」，等你$ask';
    }
    return clean.isEmpty ? '$n 已提交，等你$ask' : '「$clean」已提交，等你$ask';
  }
}

/// Text helpers shared by headlines, quotes and chips.
abstract final class AgentHeadlines {
  static final _fence = RegExp(r'```[\s\S]*?```');
  static final _link = RegExp(r'\[([^\]]*)\]\([^)]*\)');
  static final _lead = RegExp(r'^(?:#{1,6}\s*|>\s*|[-*+]\s+|\d+[.)]\s+)+');
  static final _marks = RegExp(r'\*\*|__|~~|`|\*');
  static final _mention = RegExp(r'@[^\s@，,。：:！!？?；;、]+');
  static final _question = RegExp(r'确认|是否|？|\?|吗|要不要|可以');

  /// Markdown and @mentions removed, whitespace collapsed.
  static String plain(String raw, {int max = 120}) {
    final text = _strip(raw.replaceAll(_fence, ' ')).join(' ');
    return _clip(text, max);
  }

  static List<String> _strip(String raw) => [
    for (final line in raw.split(RegExp(r'\r?\n')))
      if (_line(line).isNotEmpty) _line(line),
  ];

  static String _line(String line) => line
      .trim()
      .replaceFirst(_lead, '')
      .replaceAllMapped(_link, (m) => m[1] ?? '')
      .replaceAll(_marks, '')
      .replaceAll(_mention, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max).trimRight()}…';

  /// The first meaningful sentence: leading @mentions and markdown removed,
  /// cut at the first sentence end or colon, at most 40 characters.
  static String clean(String raw, {int max = 40}) {
    final lines = _strip(raw.replaceAll(_fence, ' '));
    if (lines.isEmpty) return '';
    final line = lines.first;
    var end = line.length;
    var keep = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      final next = i + 1 < line.length ? line[i + 1] : ' ';
      if ('。；;：'.contains(c) ||
          ((c == ':' || c == '.') && next == ' ') ||
          '！？!?'.contains(c)) {
        end = i;
        keep = '！？!?'.contains(c);
        break;
      }
    }
    return _clip(line.substring(0, keep ? end + 1 : end).trim(), max);
  }

  /// 确认 when the text asks something, 验收 otherwise.
  static String askVerb(String text) => _question.hasMatch(text) ? '确认' : '验收';

  static bool asksQuestion(String text) => _question.hasMatch(text);

  static String duration(int hours) =>
      hours >= 48 ? '${hours ~/ 24} 天' : '$hours 小时';
}

/// One agent as the person reads it: what it is doing right now.
class AgentRuntimeInfo {
  const AgentRuntimeInfo({
    required this.id,
    required this.name,
    required this.state,
    required this.activity,
    this.since,
    this.channel,
    this.taskNumber,
    this.taskTitle,
  });

  final String id, name;
  final AgentWorkState state;

  /// One phrase: the task it holds, what its runtime reports, or "空闲".
  final String activity;

  /// How long, already worded ("12 分钟前有进展", "离线 3 小时").
  final String? since;
  final String? channel, taskTitle;
  final int? taskNumber;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'state': state.name,
    'activity': activity,
    if (since != null) 'since': since,
    if (channel != null) 'channel': channel,
    if (taskNumber != null) 'task': '#$taskNumber ${taskTitle ?? ''}'.trim(),
  };
}

/// One task read in full: content, who has it and the end of its thread.
class AgentTaskDetail {
  const AgentTaskDetail({
    required this.id,
    required this.number,
    required this.title,
    required this.status,
    required this.description,
    required this.updated,
    this.creator,
    this.claimer,
    this.channelId,
    this.channelName,
    this.thread = const [],
  });

  final String id, title, status, description;

  /// "3 小时前".
  final String updated;
  final int number;
  final String? creator, claimer, channelId, channelName;

  /// The last thread lines, oldest first.
  final List<AgentProgressLine> thread;

  Map<String, Object?> toJson() => {
    'number': number,
    'title': AgentHeadlines.plain(title, max: 140),
    'status': status,
    if (description.isNotEmpty)
      'description': AgentHeadlines.plain(description, max: 600),
    if (creator != null) 'creator': creator,
    if (claimer != null) 'claimer': claimer,
    if (channelName != null) 'channel': channelName,
    'updated': updated,
    'thread': [
      for (final l in thread)
        {
          'who': l.who,
          'time': l.time,
          'text': AgentHeadlines.plain(l.text, max: 300),
        },
    ],
  };
}

/// A compact view of one channel for a Z layer.
class AgentChannelBrief {
  const AgentChannelBrief({
    required this.channel,
    required this.messages,
    required this.tasks,
    required this.windowHours,
  });

  final RaftChannel channel;
  final List<Map<String, dynamic>> messages;
  final List<Map<String, dynamic>> tasks;
  final int windowHours;

  int get recentCount => messages.length;
  int get inReview => tasks.where((t) => t['status'] == 'in_review').length;
  int get inProgress => tasks.where((t) => t['status'] == 'in_progress').length;
}

/// What one visit keeps for the next: the last accepted result and what the
/// person set aside, so reopening agent mode paints final cards at once.
class _AgentSession {
  AgentAttention? attention;
  final hidden = <String>{};
}

/// Reads existing workspace endpoints for agent mode. The only write is
/// [approve], on an explicit confirmation.
///
/// Only the user's own matters wait for a decision: tasks they created, tasks
/// assigned to them, and tasks that @-mention them. Everything else in review
/// is team progress. Score = waiting time x how it concerns the user
/// (mentioned > assigned > created) x people waiting.
class AgentModeData {
  AgentModeData(
    this.w, {
    DateTime Function()? now,
    this.headlines = const RuleHeadlineWriter(),
    this.summarizer,
  }) : _now = now ?? DateTime.now;

  final WorkspaceController w;
  final DateTime Function() _now;
  final AgentHeadlineWriter headlines;

  /// Optional: rewrites the rule sentences with a model, in one batch. The
  /// rule sentence stays for every card it returns nothing for.
  final AgentHeadlineSummarizer? summarizer;

  /// How long a first result waits for the summarizer before showing the
  /// rule sentences (the model request goes on and fills its cache).
  static const summaryWait = Duration(seconds: 6);

  static const stalledAfter = Duration(hours: 4);

  /// The server-wide task queries return at most this many rows per status.
  static const taskLimit = 50;

  /// Rows read per status before the count is shown as "N+".
  static const maxTaskRows = 500;

  static final _sessions = <String, _AgentSession>{};

  static _AgentSession _session(WorkspaceController w) => _sessions.putIfAbsent(
    jsonEncode([w.client.origin, w.client.user?.id, w.client.serverId]),
    _AgentSession.new,
  );

  /// The last accepted result for this account and server.
  static AgentAttention? cached(WorkspaceController w) => _session(w).attention;
  static void remember(WorkspaceController w, AgentAttention value) =>
      _session(w).attention = value;

  /// Ids set aside ("稍后") or approved during this app session.
  static Set<String> hidden(WorkspaceController w) => _session(w).hidden;
  static void clearSession() => _sessions.clear();

  static DateTime? _time(Object? v) =>
      v is String ? DateTime.tryParse(v)?.toLocal() : null;

  static List<Map<String, dynamic>> _rows(Object? body, String key) {
    final list = body is Map ? body[key] : null;
    return [
      if (list is List)
        for (final r in list)
          if (r is Map) Map<String, dynamic>.from(r),
    ];
  }

  Future<List<Map<String, dynamic>>> _tasks(
    String status, {
    String? channelId,
    int limit = taskLimit,
  }) async =>
      (await _taskLane(status, channelId: channelId, limit: limit)).rows;

  /// One status lane, paged by `next_cursor` as the Tasks page does (the
  /// endpoint has no assignee or creator filter, so ownership is filtered by
  /// the caller). Reads until the server has no more or [maxTaskRows] rows
  /// are held; [truncated] is true only when rows may still be unread.
  Future<({List<Map<String, dynamic>> rows, bool truncated})> _taskLane(
    String status, {
    String? channelId,
    int limit = taskLimit,
  }) async {
    final path = channelId == null
        ? '/tasks/server'
        : '/tasks/channel/$channelId';
    final rows = <Map<String, dynamic>>[];
    final seen = <Object?>{};
    final cursors = <String>{};
    String? cursor;
    while (true) {
      final Object? body;
      try {
        body = await w.query(
          path,
          query: {
            'status': status,
            'detail': 'summary',
            'limit': limit,
            'cursor': ?cursor,
          },
        );
      } catch (_) {
        // The first page failing is a failed read; a later page leaves the
        // rows so far, and they are not the whole.
        if (cursor == null) rethrow;
        return (rows: rows, truncated: true);
      }
      for (final r in _rows(body, 'tasks')) {
        if (r['id'] == null || seen.add(r['id'])) rows.add(r);
      }
      final next = body is Map ? _str(body['next_cursor']) : null;
      if (next == null || !cursors.add(next)) {
        return (rows: rows, truncated: false);
      }
      if (rows.length >= maxTaskRows) return (rows: rows, truncated: true);
      cursor = next;
    }
  }

  /// The one write: the task is done. Throws when the server refuses.
  Future<void> approve(String taskId) async {
    await w.command('PATCH', '/tasks/$taskId/status', data: {'status': 'done'});
  }

  ({int value, String unit}) _ago(DateTime at) {
    final d = _now().difference(at);
    if (d.inMinutes < 60) return (value: d.inMinutes.clamp(1, 59), unit: '分钟');
    if (d.inHours < 48) return (value: d.inHours, unit: '小时');
    return (value: d.inDays, unit: '天');
  }

  /// "今天 07:02", "昨天 23:21", "10月3日 08:00".
  String _stamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    final now = _now().toLocal(), t = at.toLocal();
    final days = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(t.year, t.month, t.day)).inDays;
    final clock = '${two(t.hour)}:${two(t.minute)}';
    return switch (days) {
      0 => '今天 $clock',
      1 => '昨天 $clock',
      _ => '${t.month}月${t.day}日 $clock',
    };
  }

  static String? _str(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  /// The signed-in user, as the task rows name people.
  ({String? id, Set<String> names}) get _me {
    final u = w.client.user;
    return (
      id: _str(u?.id),
      names: {
        for (final k in const ['displayName', 'name', 'username'])
          ?_str(u?.json[k]),
      },
    );
  }

  static bool _mentions(Map<String, dynamic> t, String? id, Set<String> names) {
    final list = t['mentions'];
    if (id != null && list is List) {
      for (final m in list) {
        if (m is Map && m['id'] == id) return true;
      }
    }
    final text =
        '${t['title'] ?? ''}\n${t['description'] ?? ''}\n'
        '${t['descriptionPreview'] ?? ''}';
    return [
      for (final n in names)
        if (RegExp(
          '@${RegExp.escape(n)}(?![\\w-])',
          caseSensitive: false,
        ).hasMatch(text))
          n,
    ].isNotEmpty;
  }

  Future<AgentAttention> attention() async {
    final results = await Future.wait([
      _taskLane('in_review'),
      _taskLane('in_progress'),
      w.sharedQuery(
        '/channels/inbox',
        query: {'filter': 'all', 'sort': 'desc', 'limit': 30, 'offset': 0},
      ),
    ]);
    final reviewLane =
        results[0] as ({List<Map<String, dynamic>> rows, bool truncated});
    final progressLane =
        results[1] as ({List<Map<String, dynamic>> rows, bool truncated});
    final review = reviewLane.rows;
    final progress = progressLane.rows;
    // "N+" only when rows were left unread; with every row read, the counts
    // after ownership filtering are exact.
    final capped = reviewLane.truncated || progressLane.truncated;
    final now = _now();
    final me = _me;

    bool isMe(Object? id, Object? type) =>
        type != 'agent' && me.id != null && id == me.id;
    bool concerns(Map<String, dynamic> t) =>
        isMe(t['createdById'], t['createdByType']) ||
        isMe(t['claimedById'], t['claimedByType']) ||
        _mentions(t, me.id, me.names);

    final decisions = <AgentAttentionItem>[];
    final blocked = <AgentAttentionItem>[];
    final team = <AgentTeamItem>[];

    // What each card is about, for the summarizer.
    final sources = <String, String>{};

    AgentAttentionItem build(Map<String, dynamic> t, {required bool stalled}) {
      final createdByMe = isMe(t['createdById'], t['createdByType']);
      final assigned = isMe(t['claimedById'], t['claimedByType']);
      final mentioned = _mentions(t, me.id, me.names);

      final at = _time(t['updatedAt']) ?? now;
      final wait = now.difference(at);
      final claimer = assigned ? null : _str(t['claimedByName']);
      final creator = createdByMe ? null : _str(t['createdByName']);
      final waiters = <String>{
        for (final n in [creator, claimer])
          if (n != null && !me.names.contains(n)) n,
      }.toList();
      final text =
          '${t['title'] ?? ''}\n'
          '${t['description'] ?? t['descriptionPreview'] ?? ''}';
      final number = t['taskNumber'] is int ? t['taskNumber'] as int : null;
      final clean = AgentHeadlines.clean(text);
      final short = clean.length > 14 ? '${clean.substring(0, 14)}…' : clean;
      final hours = wait.inHours;
      final factor = mentioned ? 3.0 : (assigned ? 2.0 : 1.5);
      final score =
          (wait.inMinutes / 60).clamp(.25, 100000).toDouble() *
          factor *
          (1 + .5 * ((waiters.length - 1).clamp(0, 10)));
      final ago = _ago(at);
      final readOnly =
          t['readOnlyReason'] != null || w.server?.string('role') == 'guest';
      final reason = stalled
          ? (RegExp(r'合并|merge', caseSensitive: false).hasMatch(text)
                ? '卡住合并'
                : waiters.length > 1
                ? '${waiters.length} 人在等'
                : '卡住了')
          : waiters.length > 1
          ? '${waiters.length} 人在等'
          : mentioned
          ? '点名找你'
          : (createdByMe ? '你派的任务' : '指给你的任务');
      final verb = AgentHeadlines.askVerb(text);
      final taskId = '${t['id'] ?? ''}';
      sources[taskId] = AgentHeadlines.plain(text, max: 300);
      return AgentAttentionItem(
        id: taskId,
        taskId: taskId,
        taskNumber: number,
        priority: stalled ? AgentPriority.blocked : AgentPriority.decision,
        headline: headlines.write(
          AgentHeadlineInput(
            status: stalled ? 'in_progress' : 'in_review',
            text: text,
            claimer: claimer,
            number: number,
            idleHours: hours,
          ),
        ),
        ask: stalled ? '解除阻塞' : verb,
        askLine: stalled
            ? '解除阻塞'
            : (short.isEmpty ? '$verb这个任务' : '$verb「$short」'),
        action: !stalled && !readOnly ? AgentAction.approve : AgentAction.open,
        canApprove: !stalled && !readOnly && taskId.isNotEmpty,
        reason: reason,
        waitValue: ago.value,
        waitUnit: ago.unit,
        idle: stalled,
        at: at,
        score: score,
        waiters: waiters,
        doer: claimer,
        channelId: _str(t['channelId']),
        channelName: _str(t['channelName']),
        threadTitle: short.isEmpty ? null : short,
        progress: [
          AgentProgressLine(
            who: claimer ?? creator ?? '',
            time: _stamp(at),
            text: AgentHeadlines.plain(text),
          ),
        ],
      );
    }

    for (final t in review) {
      if (concerns(t)) {
        decisions.add(build(t, stalled: false));
      } else {
        team.add(_teamItem(t));
      }
    }
    for (final t in progress) {
      final at = _time(t['updatedAt']) ?? now;
      final stalled = now.difference(at) >= stalledAfter;
      if (!concerns(t)) {
        team.add(_teamItem(t));
      } else if (stalled) {
        blocked.add(build(t, stalled: true));
      }
    }

    final mentions = <AgentAttentionItem>[];
    final known = {
      for (final i in [...decisions, ...blocked])
        '${i.channelId}#${i.taskNumber}',
    };
    for (final r in _rows(results[2], 'items')) {
      if (r['hasMention'] != true) continue;
      final thread = r['kind'] == 'thread';
      final channelId = _str(thread ? r['parentChannelId'] : r['channelId']);
      if (r['taskNumber'] != null &&
          known.contains('$channelId#${r['taskNumber']}')) {
        continue;
      }
      final at = _time(r['lastActivityAt'] ?? r['lastMessageAt']) ?? now;
      final who =
          _str(
            r[thread ? 'latestActivitySenderName' : 'lastMessageSenderName'],
          ) ??
          '有人';
      final raw =
          '${r[thread ? 'latestActivityPreview' : 'lastMessagePreview'] ?? r['messagePreview'] ?? ''}';
      final where =
          _str(thread ? r['parentChannelName'] : r['channelName']) ?? '';
      final said = AgentHeadlines.clean(raw);
      final parentTitle = thread
          ? AgentHeadlines.clean('${r['parentMessagePreview'] ?? ''}')
          : '';
      final ago = _ago(at);
      final question = AgentHeadlines.asksQuestion(raw);
      final mentionId =
          'mention:${_str(r['threadChannelId']) ?? _str(r['channelId']) ?? mentions.length}';
      sources[mentionId] = AgentHeadlines.plain(raw, max: 300);
      mentions.add(
        AgentAttentionItem(
          id: mentionId,
          priority: AgentPriority.mention,
          headline: said.isEmpty
              ? '$who 在 $where @ 了你'
              : '$who 在 $where @ 了你：$said',
          ask: question ? '回答' : '回复',
          askLine: question ? '回答一个问题' : '回复 $who',
          action: AgentAction.reply,
          reason: '点名找你',
          waitValue: ago.value,
          waitUnit: ago.unit,
          at: at,
          score: (now.difference(at).inMinutes / 60).clamp(.25, 100000) * 3.0,
          waiters: [who],
          doer: who,
          channelId: channelId,
          channelName: where.isEmpty ? null : where,
          threadTitle: parentTitle.isEmpty ? null : parentTitle,
          progress: [
            AgentProgressLine(
              who: who,
              time: _stamp(at),
              text: AgentHeadlines.plain(raw),
            ),
          ],
        ),
      );
    }

    int byScore(AgentAttentionItem a, AgentAttentionItem b) {
      final s = b.score.compareTo(a.score);
      return s != 0 ? s : a.at.compareTo(b.at);
    }

    decisions.sort(byScore);
    blocked.sort(byScore);
    mentions.sort(byScore);
    final items = [...decisions, ...blocked, ...mentions];
    return AgentAttention(
      items: await _rewrite(
        await _withThreads(items, [...review, ...progress]),
        sources,
      ),
      team: team,
      capped: capped,
    );
  }

  /// Gives the cards the summarizer's sentences. Done before the result is
  /// accepted, so a card never changes after its first frame; a summarizer
  /// that is slow, offline or wrong leaves the rule sentences.
  Future<List<AgentAttentionItem>> _rewrite(
    List<AgentAttentionItem> items,
    Map<String, String> sources,
  ) async {
    final summarizer = this.summarizer;
    if (summarizer == null || items.isEmpty) return items;
    final requests = [
      for (final i in items)
        AgentHeadlineRequest(
          id: i.id,
          version: i.at.toUtc().toIso8601String(),
          kind: i.priority.name,
          text: sources[i.id] ?? '',
          ask: i.askText,
          wait: i.waitLabel,
          doer: i.doer,
          quote: i.quote?.text == null
              ? null
              : AgentHeadlines.plain(i.quote!.text, max: 160),
        ),
    ];
    // Whichever comes first: the sentences, a failure, or the wait running
    // out. A request still running then keeps filling the summarizer's cache.
    final done = Completer<Map<String, String>>();
    void finish(Map<String, String> v) {
      if (!done.isCompleted) done.complete(v);
    }

    final timer = Timer(summaryWait, () => finish(const {}));
    Future<Map<String, String>>.sync(() => summarizer.summarize(requests))
        .then(finish, onError: (Object _) => finish(const {}));
    final got = await done.future;
    timer.cancel();
    return [
      for (final i in items) got[i.id] == null ? i : i.withHeadline(got[i.id]!),
    ];
  }

  AgentTeamItem _teamItem(Map<String, dynamic> t) {
    final who = _str(t['claimedByName']) ?? _str(t['createdByName']) ?? '';
    final text = '${t['title'] ?? ''}\n${t['description'] ?? ''}';
    final clean = AgentHeadlines.clean(text);
    final what = clean.isEmpty ? '任务 #${t['taskNumber'] ?? ''}' : '「$clean」';
    final verb = t['status'] == 'in_review' ? '完成了' : '正在做';
    return AgentTeamItem(
      id: '${t['id'] ?? ''}',
      headline: who.isEmpty ? what : '$who $verb$what',
      channelName: _str(t['channelName']) ?? '',
      who: who,
    );
  }

  /// Replaces the fallback quote with the last lines of the task's thread
  /// when it can be read. Done before the result is accepted so a card never
  /// changes after its first frame.
  Future<List<AgentAttentionItem>> _withThreads(
    List<AgentAttentionItem> items,
    List<Map<String, dynamic>> tasks,
  ) async {
    final threadOf = {
      for (final t in tasks)
        if (_str(t['threadChannelId']) != null)
          '${t['id']}': _str(t['threadChannelId'])!,
    };
    return Future.wait([
      for (final i in items)
        if (i.taskId != null && threadOf[i.taskId] != null)
          _thread(threadOf[i.taskId]!)
              .then((lines) => lines.isEmpty ? i : i.withProgress(lines))
        else
          Future.value(i),
    ]);
  }

  Future<List<AgentProgressLine>> _thread(
    String threadChannelId, {
    int limit = 3,
  }) async {
    try {
      final body = await w
          .query('/messages/channel/$threadChannelId', query: {'limit': limit})
          .timeout(const Duration(seconds: 4));
      final rows = _rows(body, 'messages')
        ..sort((a, b) {
          final sa = BigInt.tryParse('${a['seq']}') ?? BigInt.zero;
          final sb = BigInt.tryParse('${b['seq']}') ?? BigInt.zero;
          return sa.compareTo(sb);
        });
      return [
        for (final m in rows.skip(
          rows.length > limit ? rows.length - limit : 0,
        ))
          if (AgentHeadlines.plain('${m['content'] ?? ''}').isNotEmpty ||
              '${m['content'] ?? ''}'.trim().isNotEmpty)
            AgentProgressLine(
              who: _str(m['senderName']) ?? '',
              time: _stamp(_time(m['createdAt']) ?? _now()),
              text: '${m['content'] ?? ''}'
                  .replaceAll(RegExp(r'\s+'), ' ')
                  .trim(),
            ),
      ];
    } on Object {
      // A thread that cannot be read leaves the task's own text as the quote.
      return const [];
    }
  }

  // ---- Grounding reads for the voice model and generated screens ---------

  /// Task rows of every status, newest facts only; a lane the server refuses
  /// is left out rather than failing the read.
  Future<List<Map<String, dynamic>>> _allTasks([
    Iterable<String>? statuses,
  ]) async {
    final lanes = await Future.wait([
      for (final s
          in statuses ??
              const ['in_progress', 'in_review', 'todo', 'done', 'closed'])
        _tasks(s)
            .then((v) => v, onError: (Object _) => <Map<String, dynamic>>[]),
    ]);
    return [for (final l in lanes) ...l];
  }

  static const _blockedKinds = {
    'delivery_unconsumed',
    'wake_crash_loop_blocked',
    'terminal_failure_paused',
  };

  /// Every agent with what it is doing now. State comes from the same
  /// presence rules the Agents list uses (runtime activity, external last
  /// seen); an online agent holding a task that has not moved for
  /// [stalledAfter] counts as blocked, the same rule the attention layer uses.
  Future<List<AgentRuntimeInfo>> agents() async {
    final directory = w.entityDirectory;
    try {
      await directory
          .refresh(WorkspaceEntityKind.agents)
          .timeout(const Duration(seconds: 8));
    } on Object {
      // The accepted rows (if any) are still the best facts.
    }
    var rows = directory.rows(WorkspaceEntityKind.agents);
    if (rows.isEmpty) {
      try {
        final body = await w.query('/agents');
        rows = [
          if (body is List)
            for (final r in body)
              if (r is Map && r['deletedAt'] == null)
                Map<String, dynamic>.from(r),
        ];
      } on Object {
        rows = const [];
      }
    }
    final held = <String, Map<String, dynamic>>{};
    try {
      for (final t in await _tasks('in_progress')) {
        final owner = _str(t['claimedById']);
        if (owner == null) continue;
        final seen = held[owner];
        if (seen == null ||
            (_time(t['updatedAt']) ?? DateTime(0)).isAfter(
              _time(seen['updatedAt']) ?? DateTime(0),
            )) {
          held[owner] = t;
        }
      }
    } on Object {
      // Without tasks the activity text comes from the runtime alone.
    }
    final now = _now();
    String agoText(DateTime at) {
      final a = _ago(at);
      return '${a.value} ${a.unit}';
    }

    final out = <AgentRuntimeInfo>[];
    for (final row in rows) {
      final id = '${row['id']}';
      final display = agentRowAmbientDisplay(row, now: now);
      if (display.deactivated) continue;
      final task = held[id];
      final taskAt = task == null ? null : _time(task['updatedAt']);
      final stalled = taskAt != null && now.difference(taskAt) >= stalledAfter;
      final taskNumber = task?['taskNumber'] is int
          ? task!['taskNumber'] as int
          : null;
      final taskTitle = task == null
          ? null
          : AgentHeadlines.clean(
              '${task['title'] ?? ''}\n${task['description'] ?? ''}',
              max: 30,
            );
      final taskText = taskNumber == null
          ? null
          : '#$taskNumber${taskTitle == null || taskTitle.isEmpty ? '' : '「$taskTitle」'}';
      final detail = AgentHeadlines.plain(display.detail, max: 60);
      final lastSeen = _time(row['lastSeenAt']);
      final AgentWorkState state;
      final String activity;
      String? since;
      if (!display.online) {
        state = AgentWorkState.offline;
        activity = '离线';
        if (lastSeen != null) since = '离线 ${agoText(lastSeen)}';
      } else if (display.activity == 'error' ||
          _blockedKinds.contains(display.detailKind)) {
        state = AgentWorkState.blocked;
        final reason = AgentHeadlines.plain(
          agentActivityErrorDetail(display.detail),
          max: 60,
        );
        activity = reason.isNotEmpty ? '出错：$reason' : '运行出错';
      } else if (display.activity == 'working' ||
          display.activity == 'thinking') {
        if (stalled) {
          state = AgentWorkState.blocked;
          activity = '$taskText 超过 ${agoText(taskAt)}没动';
        } else {
          state = AgentWorkState.busy;
          activity = taskText != null
              ? '在做 $taskText'
              : detail.isNotEmpty
              ? detail
              : (display.activity == 'thinking' ? '在思考' : '在工作');
          if (taskAt != null) since = '${agoText(taskAt)}前有进展';
        }
      } else if (stalled) {
        state = AgentWorkState.blocked;
        activity = '$taskText 超过 ${agoText(taskAt)}没动';
      } else {
        state = AgentWorkState.idle;
        activity = '空闲';
      }
      out.add(
        AgentRuntimeInfo(
          id: id,
          name: agentRowName(row),
          state: state,
          activity: activity,
          since: since,
          channel: _str(task?['channelName']),
          taskNumber: taskNumber,
          taskTitle: taskTitle,
        ),
      );
    }
    int order(AgentWorkState s) => switch (s) {
      AgentWorkState.blocked => 0,
      AgentWorkState.busy => 1,
      AgentWorkState.idle => 2,
      AgentWorkState.offline => 3,
    };
    out.sort((a, b) {
      final o = order(a.state) - order(b.state);
      return o != 0 ? o : a.name.compareTo(b.name);
    });
    return out;
  }

  /// Tasks numbered [number] (numbers repeat across channels), each read in
  /// full with the end of its thread. [channel] narrows by channel name.
  Future<List<AgentTaskDetail>> tasksNumbered(
    int number, {
    String? channel,
  }) async {
    final want = channel?.replaceAll('#', '').trim().toLowerCase();
    final rows = [
      for (final t in await _allTasks())
        if (t['taskNumber'] == number &&
            (want == null ||
                want.isEmpty ||
                '${t['channelName']}'.toLowerCase() == want))
          t,
    ];
    final seen = <String>{};
    final unique = [
      for (final t in rows)
        if (seen.add('${t['channelId']}')) t,
    ].take(3);
    return Future.wait([for (final t in unique) _detail(t)]);
  }

  Future<AgentTaskDetail> _detail(Map<String, dynamic> summary) async {
    var task = summary;
    final channelId = _str(summary['channelId']);
    try {
      if (channelId != null) {
        final full = await w.query(
          '/tasks/channel/$channelId/number/${summary['taskNumber']}',
        );
        if (full is Map && full['task'] is Map) {
          task = {
            ...summary,
            ...Map<String, dynamic>.from(full['task'] as Map),
          };
        }
      }
    } on Object {
      // The summary row still has the title and status.
    }
    final threadId = _str(task['threadChannelId']);
    final thread = threadId == null
        ? const <AgentProgressLine>[]
        : await _thread(threadId, limit: 6);
    final at = _time(task['updatedAt']) ?? _now();
    final ago = _ago(at);
    return AgentTaskDetail(
      id: '${task['id'] ?? ''}',
      number: task['taskNumber'] as int,
      title: '${task['title'] ?? ''}',
      status: '${task['status'] ?? ''}',
      description: '${task['description'] ?? ''}',
      updated: '${ago.value} ${ago.unit}前',
      creator: _str(task['createdByName']),
      claimer: _str(task['claimedByName']),
      channelId: channelId,
      channelName: _str(task['channelName']),
      thread: thread,
    );
  }

  /// Tasks of any status whose title, text, owner or channel contain every
  /// word of [query] (`#94` or `94` matches by number). Newest first.
  Future<List<Map<String, dynamic>>> searchTasks(
    String query, {
    String? status,
  }) async {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final rows = await _allTasks(
      status == null || status.isEmpty ? null : [status],
    );
    bool hit(Map<String, dynamic> t) {
      final hay =
          '#${t['taskNumber']} ${t['title']} ${t['description'] ?? t['descriptionPreview'] ?? ''} '
                  '${t['claimedByName']} ${t['createdByName']} ${t['channelName']}'
              .toLowerCase();
      return words.every((w) => hay.contains(w));
    }

    return [
      for (final t in rows)
        if (words.isEmpty || hit(t)) t,
    ]..sort(
      (a, b) => (_time(b['updatedAt']) ?? DateTime(0)).compareTo(
        _time(a['updatedAt']) ?? DateTime(0),
      ),
    );
  }

  Future<AgentChannelBrief> channel(
    RaftChannel c, {
    int windowHours = 6,
  }) async {
    final results = await Future.wait([
      w.client.messagePage(c.id, limit: 30),
      _tasks('in_review', channelId: c.id),
      _tasks('in_progress', channelId: c.id),
    ]);
    final page = results[0] as Map<String, dynamic>;
    final since = _now().subtract(Duration(hours: windowHours));
    final messages = _rows(page, 'messages')
      ..sort((a, b) {
        final sa = BigInt.tryParse('${a['seq']}') ?? BigInt.zero;
        final sb = BigInt.tryParse('${b['seq']}') ?? BigInt.zero;
        return sa.compareTo(sb);
      });
    final recent = [
      for (final m in messages)
        if ((_time(m['createdAt']) ?? since).isAfter(since)) m,
    ];
    return AgentChannelBrief(
      channel: c,
      messages: recent.isEmpty
          ? messages.sublist(messages.length > 5 ? messages.length - 5 : 0)
          : recent,
      tasks: [
        ...results[1] as List<Map<String, dynamic>>,
        ...results[2] as List<Map<String, dynamic>>,
      ],
      windowHours: windowHours,
    );
  }

  Future<List<Map<String, dynamic>>> openTasks() async {
    final results = await Future.wait([
      _tasks('in_review'),
      _tasks('in_progress'),
    ]);
    return [...results[0], ...results[1]];
  }
}

/// What a typed (later spoken) request asks for.
sealed class AgentIntent {
  const AgentIntent();
}

class AgentBack extends AgentIntent {
  const AgentBack();
}

class AgentHome extends AgentIntent {
  const AgentHome();
}

class AgentTasks extends AgentIntent {
  const AgentTasks();
}

class AgentOpenChannel extends AgentIntent {
  const AgentOpenChannel(this.channel);
  final RaftChannel channel;
}

/// "讲讲第一条" / "展开第 2 条" / "详细说说这个": open the detail of a card.
/// [index] is null for "这个" (the focused one, else the most urgent).
class AgentExpand extends AgentIntent {
  const AgentExpand(this.index);
  final int? index;
}

/// "下一批": the next cards on the phone's first layer.
class AgentNextBatch extends AgentIntent {
  const AgentNextBatch();
}

class AgentUnknown extends AgentIntent {
  const AgentUnknown();
}

/// Demo intent matching. A realtime voice model replaces this with tool calls
/// that map onto the same intents.
AgentIntent parseAgentIntent(String text, List<RaftChannel> channels) {
  final s = text.trim().toLowerCase();
  if (RegExp(r'^(返回|回去|后退|back)$').hasMatch(s)) return const AgentBack();
  if (RegExp(r'下一批|还有吗|再看看别的').hasMatch(s)) return const AgentNextBatch();
  if (RegExp(r'讲讲|展开|详细|详情|细说|说说|expand').hasMatch(s)) {
    final n = agentOrdinal(s);
    if (n != null || RegExp(r'这个|这条|这件|它|展开$').hasMatch(s)) {
      return AgentExpand(n);
    }
  }
  if (RegExp(r'(提醒|需要我|首页|home|回到开始)').hasMatch(s)) {
    return const AgentHome();
  }
  RaftChannel? best;
  for (final c in channels) {
    if (c.archived || c.name.isEmpty) continue;
    final name = c.name.toLowerCase();
    if (s.contains(name) && (best == null || name.length > best.name.length)) {
      best = c;
    }
  }
  if (best != null) return AgentOpenChannel(best);
  if (RegExp(r'(任务|task)').hasMatch(s)) return const AgentTasks();
  return const AgentUnknown();
}

/// The number in "第一条", "第 2 条", "第十二个": null when none is said.
int? agentOrdinal(String text) {
  final m = RegExp(r'第\s*([0-9一二两三四五六七八九十]+)').firstMatch(text);
  if (m == null) return null;
  final raw = m[1]!;
  final digits = int.tryParse(raw);
  if (digits != null) return digits;
  const d = {
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (raw == '十') return 10;
  if (raw.startsWith('十')) return 10 + (d[raw.substring(1)] ?? 0);
  if (raw.endsWith('十')) return (d[raw[0]] ?? 0) * 10;
  if (raw.length == 3 && raw[1] == '十') {
    return (d[raw[0]] ?? 0) * 10 + (d[raw[2]] ?? 0);
  }
  return raw.length == 1 ? d[raw] : null;
}
