import 'package:flutter/widgets.dart';
import 'package:raft_client/raft_client.dart';

import '../../../data/raft_location.dart';
import '../../../data/source_task_bucket.dart';
import '../../../data/workspace_controller.dart';
import '../../../data/workspace_navigation.dart';
import '../../agent_mode/agent_activity_feed.dart';
import '../../agent_mode/agent_mode_data.dart';
import '../orb_tool.dart';
import 'orb_resolver.dart';
import 'orb_vocabulary.dart';
import 'orb_wait.dart';

/// `describe_page`: what the page shows, read from the DATA LAYER (the same
/// rows, windows and stores the screen paints), never from pixels.
///
/// Phase-1 pages are described in full: Activity, a channel or DM
/// conversation, a thread and a task. Every other page gets its route, title
/// and a summary of its Semantics (the labels and texts the page exposes).
/// Output is bounded: [orbMaxActivityItems] rows, [orbMaxMessages] messages,
/// at most [orbMessageTextCap] characters of one message's full text, and
/// [orbTextBudget] characters of message text in all.
const orbMaxActivityItems = 20;
const orbMaxMessages = 30;
const orbMessageTextCap = 1500;
const orbTextBudget = 16000;
const orbMaxSemanticsLines = 40;

/// Names of the pages in the result's `page` field.
abstract final class OrbPage {
  static const activity = 'activity';
  static const conversation = 'conversation';
  static const thread = 'thread';
  static const task = 'task';
  static const profile = 'profile';
  static const other = 'other';
}

/// The title of a location, as the person calls it.
String orbPageTitle(WorkspaceController w, RaftLocation loc) {
  RaftChannel? channelOf(String? id) => id == null
      ? null
      : [
          ?w.channel,
          ...w.channels,
          ...w.dms,
        ].where((c) => c.id == id).firstOrNull;
  switch (loc.route) {
    case RaftRoute.channel || RaftRoute.dm:
      final c = channelOf(loc.entityId);
      if (c == null) return loc.route == RaftRoute.dm ? '私信' : '频道';
      return c.type == 'dm' ? c.peerLabel : '#${c.name}';
    case RaftRoute.settings:
      final tab = loc.settingsPath.isEmpty
          ? null
          : WorkspaceNavigation.settingsTab(loc.settingsPath.first);
      final d = orbVocabulary
          .where(
            (d) =>
                d.route == RaftRoute.settings &&
                (tab == null
                    ? d.settingsPath.isEmpty && d.section == 'settings'
                    : d.settingsPath.length == 1 &&
                          d.settingsPath.first == tab),
          )
          .firstOrNull;
      return d?.zhName ?? '设置';
    default:
      final d = orbVocabulary
          .where((d) => d.route == loc.route && d.channelTab == null)
          .firstOrNull;
      return d?.zhName ?? loc.route.name;
  }
}

/// The directory of names the resolver matches: channels, DMs, members and
/// Agents the App holds now, and the discussions the Activity rows name.
OrbDirectory orbDirectoryOf(WorkspaceController w) {
  String? str(Object? v) =>
      v is String && v.trim().isNotEmpty ? v.trim() : null;
  final dir = w.entityDirectory;
  final people = <OrbPersonRef>[
    for (final m in dir.authorMembers)
      if (m['deletedAt'] == null)
        if (str(m['userId'] ?? m['id']) case final id?)
          if (str(m['displayName']) ?? str(m['name']) case final name?)
            OrbPersonRef(id: id, name: name, type: 'user'),
    for (final a in dir.authorAgents)
      if (a['deletedAt'] == null)
        if (str(a['id']) case final id?)
          if (str(a['displayName']) ?? str(a['name']) case final name?)
            OrbPersonRef(id: id, name: name, type: 'agent'),
  ];
  final store = w.activityUnreadIfBound;
  final rows = store != null && store.hasAcceptedWindow
      ? store.acceptedRows
      : const <Map<String, dynamic>>[];
  return OrbDirectory(
    channels: [
      for (final c in w.channels)
        if (c.type != 'dm')
          OrbChannelRef(id: c.id, name: c.name, archived: c.archived),
    ],
    dms: [
      for (final c in w.dms)
        OrbDmRef(
          id: c.id,
          name: c.peerLabel,
          peerId: str(c.json['peerId']),
          peerType: str(c.json['peerType']),
        ),
    ],
    people: people,
    threads: [
      for (final r in rows)
        if (r['kind'] == 'thread' &&
            str(r['parentChannelId']) != null &&
            str(r['parentMessageId']) != null &&
            str(r['parentMessagePreview']) != null)
          OrbThreadRef(
            parentChannelId: str(r['parentChannelId'])!,
            parentMessageId: str(r['parentMessageId'])!,
            title: AgentActivityFeed.excerptOf(
              str(r['parentMessagePreview'])!,
              max: 80,
            ),
            threadChannelId: str(r['threadChannelId']),
            channelName: str(r['parentChannelName']),
          ),
    ],
  );
}

/// [text] cut to [max] characters; null [truncated] when whole.
({String text, bool truncated}) orbClip(String text, int max) =>
    text.length <= max
    ? (text: text, truncated: false)
    : (text: '${text.substring(0, max).trimRight()}…', truncated: true);

String _stamp(DateTime now, DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  final n = now.toLocal(), t = at.toLocal();
  final days = DateTime(
    n.year,
    n.month,
    n.day,
  ).difference(DateTime(t.year, t.month, t.day)).inDays;
  final clock = '${two(t.hour)}:${two(t.minute)}';
  return switch (days) {
    0 => '今天 $clock',
    1 => '昨天 $clock',
    _ => '${t.month}月${t.day}日 $clock',
  };
}

/// The page the workspace is on, described. [budget] is how long to wait for
/// the page's first data (see [OrbWaitBudget]); with [OrbWaitBudget.none] it
/// is a snapshot of what is there now. `loading: true` means the data has not
/// arrived: it is NOT an empty page. `empty: true` is a page that loaded and
/// has nothing.
Future<Map<String, Object?>> describeOrbPage(
  OrbToolContext ctx, {
  required OrbWaitBudget budget,
  DateTime Function()? now,
}) async {
  final w = ctx.workspace;
  final clock = now ?? DateTime.now;
  final loc = w.location;
  final head = <String, Object?>{
    'route': loc.toString(),
    'title': orbPageTitle(w, loc),
  };
  try {
    final Map<String, Object?> body;
    if (loc.task != null || loc.legacyTask != null) {
      body = await _task(w, loc, budget, clock);
    } else if (loc.profile != null) {
      body = await _profile(ctx, loc, budget);
    } else if (loc.route == RaftRoute.activity) {
      body = await _activity(w, budget, clock);
    } else if ((loc.route == RaftRoute.channel || loc.route == RaftRoute.dm) &&
        loc.thread != null) {
      body = await _thread(w, loc, budget, clock);
    } else if (loc.route == RaftRoute.channel || loc.route == RaftRoute.dm) {
      body = await _conversation(w, loc, budget, clock);
    } else {
      body = _other(ctx, loc);
    }
    final title = body.remove('title');
    return {
      ...head,
      if (title is String && title.isNotEmpty) 'title': title,
      ...body,
    };
  } on Object catch (e) {
    return {
      ...head,
      'page': OrbPage.other,
      'loading': false,
      'error': '读取页面失败：${e is RaftApiException ? e.message : e.runtimeType}',
    };
  }
}

// --- Activity ---------------------------------------------------------------

Future<Map<String, Object?>> _activity(
  WorkspaceController w,
  OrbWaitBudget budget,
  DateTime Function() clock,
) async {
  final store = w.activityUnreadIfBound ?? w.activityUnread;
  var failed = false;
  if (!store.hasAcceptedWindow && store.scope != null) {
    // The page reads the window when it opens; the same read serves here
    // (coalesced), and its end without a window is a definite failure.
    var finished = false;
    store.refresh().whenComplete(() => finished = true).ignore();
    await budget.until(store, () => store.hasAcceptedWindow || finished);
    failed = finished && !store.hasAcceptedWindow;
  }
  if (!store.hasAcceptedWindow) {
    return {
      'page': OrbPage.activity,
      'loading': !failed,
      if (failed) 'error': '动态读取失败',
      if (!failed) 'note': '动态还在加载，不是空的',
      'items': const <Object?>[],
    };
  }
  final directory = w.entityDirectory..ensureAuthors();
  await budget.until(directory, () => !directory.authorsLoading);
  final data = AgentModeData(w, now: clock);
  final rows = store.acceptedRows;
  final items = data.activityItems(rows);
  final shown = items.take(orbMaxActivityItems).toList();
  final namesPending = directory.authorsLoading;
  return {
    'page': OrbPage.activity,
    'loading': false,
    'empty': items.isEmpty,
    'unreadTotal': ?store.totalUnreadCount,
    'count': items.length,
    if (items.length > shown.length) 'more': items.length - shown.length,
    if (namesPending) 'note': '成员名字还在加载，没有名字的发送人先不要猜',
    'items': [
      for (var i = 0; i < shown.length; i++) _activityItem(i + 1, shown[i]),
    ],
    'previewNote': '每条 preview 只是预览；要整段消息用 read_conversation',
  };
}

Map<String, Object?> _activityItem(int n, AgentAttentionItem item) {
  final line = item.progress.isEmpty ? null : item.progress.last;
  final who = line?.who;
  final preview = item.excerpt == null ? null : orbClip(item.excerpt!, 300);
  return {
    'n': n,
    'id': item.id,
    'kind': item.rowKind,
    // A system event names its actor in the text and has no sender.
    if (who != null && who.isNotEmpty) 'who': who,
    'where': item.place,
    'time': ?line?.time,
    'ago': item.agoLabel,
    'unread': item.unread,
    'why': item.reason,
    if (preview != null) ...{
      'preview': preview.text,
      'isPreview': true,
      if (preview.truncated) 'previewCut': true,
    },
    'channelId': ?item.channelId,
    'channelName': ?item.channelName,
    'messageId': ?item.messageId,
    'parentMessageId': ?item.parentMessageId,
    'threadChannelId': ?item.threadChannelId,
    if (item.taskNumber != null) 'task': item.taskNumber,
    'taskStatus': ?item.taskStatus,
  };
}

// --- Conversations ----------------------------------------------------------

/// One message as the model reads it: sender name, full text (capped), time,
/// reply count.
Map<String, Object?> orbMessageJson(
  RaftMessage m,
  WorkspaceController w,
  AgentModeData data,
  DateTime now, {
  Map<String, dynamic>? summaries,
  int cap = orbMessageTextCap,
}) {
  String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final type = s(m.json['senderType']);
  final senderId = s(m.json['senderId']);
  final named =
      s(m.json['senderDisplayName']) ??
      s(m.json['senderName']) ??
      (senderId == null || type == null
          ? null
          : s(data.senderName(senderId, type)));
  final system = type == 'system' || senderId == 'system';
  final mine = senderId != null && senderId == w.client.user?.id;
  final text = orbClip(m.content, cap);
  final created = m.createdAt;
  final replies = int.tryParse('${summaries?[m.id]?['replyCount']}') ?? 0;
  final attachments = m.attachments;
  return {
    'id': m.id,
    'seq': m.string('seq'),
    if (system) 'system': true,
    if (!system && named != null) 'from': named,
    if (!system && named == null && senderId != null) 'fromId': senderId,
    if (mine) 'fromMe': true,
    'time': ?(created == null ? null : _stamp(now, created)),
    'text': text.text,
    if (text.truncated) 'truncated': true,
    if (text.truncated) 'fullLength': m.content.length,
    if (replies > 0) 'replies': replies,
    if (attachments.isNotEmpty)
      'attachments': [
        for (final a in attachments.take(5))
          s(a['filename'] ?? a['name'] ?? a['fileName']) ?? '附件',
      ],
    if (m.json['pendingSend'] == true) 'pending': true,
  };
}

/// The newest of [all] that fit [maxMessages] and [textBudget] characters of
/// text; [omitted] older ones are left out.
({List<Map<String, Object?>> messages, int omitted}) orbBoundMessages(
  List<Map<String, Object?>> all, {
  int maxMessages = orbMaxMessages,
  int textBudget = orbTextBudget,
}) {
  final kept = <Map<String, Object?>>[];
  var chars = 0;
  for (final m in all.reversed) {
    final len = '${m['text']}'.length;
    if (kept.length >= maxMessages ||
        (kept.isNotEmpty && chars + len > textBudget)) {
      break;
    }
    chars += len;
    kept.add(m);
  }
  return (messages: kept.reversed.toList(), omitted: all.length - kept.length);
}

Future<Map<String, Object?>> _conversation(
  WorkspaceController w,
  RaftLocation loc,
  OrbWaitBudget budget,
  DateTime Function() clock,
) async {
  final id = loc.entityId;
  bool ready() {
    final window = w.messageWindow;
    return w.channel?.id == id &&
        window != null &&
        window.channelId == id &&
        (!window.loading ||
            window.error != null ||
            window.snapshot.timeline.isNotEmpty);
  }

  await budget.until(Listenable.merge([w, ?w.messageWindow?.changes]), ready);
  final channel = [
    ?w.channel,
    ...w.channels,
    ...w.dms,
  ].where((c) => c.id == id).firstOrNull;
  final window = w.channel?.id == id ? w.messageWindow : null;
  final snap = window?.snapshot;
  final error = snap?.error;
  final rows = snap?.timeline ?? const <RaftMessage>[];
  // Rows on screen while the window revalidates are the first data.
  final loading = snap == null || snap.loading && rows.isEmpty;
  final data = AgentModeData(w, now: clock);
  final now = clock();
  final summaries = id == null ? null : w.threadSummariesFor(id);
  final bounded = orbBoundMessages([
    for (final m in rows) orbMessageJson(m, w, data, now, summaries: summaries),
  ]);
  final dm = channel?.type == 'dm';
  return {
    'page': OrbPage.conversation,
    'title': channel == null
        ? null
        : dm
        ? channel.peerLabel
        : '#${channel.name}',
    'conversation': {
      'id': ?id,
      'type': dm ? 'dm' : 'channel',
      'name': dm ? channel?.peerLabel : channel?.name,
      if (channel != null && channel.description.isNotEmpty)
        'description': orbClip(channel.description, 200).text,
      if (channel?.archived == true) 'archived': true,
    },
    'loading': loading && error == null,
    if (loading && error == null) 'note': '消息还在加载，不是空的',
    'empty': !loading && error == null && rows.isEmpty,
    'error': ?error,
    if (snap?.contextLoadError != null)
      'contextError': snap!.contextLoadError!.name,
    'unread': ?(id == null ? null : w.unread[id]),
    if (snap?.hasMore == true) 'hasMoreAbove': true,
    if (bounded.omitted > 0) 'omitted': bounded.omitted,
    'focusMessageId': ?snap?.highlightedMessageId,
    'messages': bounded.messages,
  };
}

Future<Map<String, Object?>> _thread(
  WorkspaceController w,
  RaftLocation loc,
  OrbWaitBudget budget,
  DateTime Function() clock,
) async {
  final anchor = loc.thread!;
  bool ready() {
    final window = w.threadWindow;
    return w.threadResolutionError != null ||
        window != null &&
            !window.loading &&
            !window.parentLoading &&
            !window.resolving &&
            window.parent != null;
  }

  await budget.until(Listenable.merge([w, ?w.threadWindow?.changes]), ready);
  final window = w.threadWindow;
  final snap = window?.snapshot;
  final parent = snap?.parent ?? w.presentedThreadParent;
  final error = w.threadResolutionError ?? snap?.error;
  final loading =
      error == null &&
      (snap == null ||
          snap.loading ||
          snap.parentLoading ||
          snap.resolving ||
          parent == null);
  final data = AgentModeData(w, now: clock);
  final now = clock();
  final replies = snap?.timeline ?? const <RaftMessage>[];
  final bounded = orbBoundMessages([
    for (final m in replies) orbMessageJson(m, w, data, now),
  ]);
  final parentChannel = [
    ...w.channels,
    ...w.dms,
  ].where((c) => c.id == anchor.channelId).firstOrNull;
  final where = parentChannel == null
      ? null
      : parentChannel.type == 'dm'
      ? parentChannel.peerLabel
      : '#${parentChannel.name}';
  return {
    'page': OrbPage.thread,
    'title': where == null ? '讨论' : '$where › 讨论',
    'thread': {
      'parentChannelId': anchor.channelId,
      'parentMessageId': anchor.itemId,
      'where': ?where,
      if (parent != null) 'parent': orbMessageJson(parent, w, data, now),
    },
    'loading': loading,
    if (loading) 'note': '讨论还在加载，不是空的',
    'empty': !loading && error == null && replies.isEmpty,
    'error': ?error,
    if (bounded.omitted > 0) 'omitted': bounded.omitted,
    'replies': bounded.messages,
  };
}

// --- Task -------------------------------------------------------------------

Future<Map<String, Object?>> _task(
  WorkspaceController w,
  RaftLocation loc,
  OrbWaitBudget budget,
  DateTime Function() clock,
) async {
  final legacy = loc.task == null;
  final anchor = (loc.task ?? loc.legacyTask)!;
  Map<String, dynamic>? row;
  String? error;
  try {
    final bucket = await budget.within(
      readSourceTaskBucket(w, anchor.channelId),
    );
    if (bucket is Map) {
      for (final r in (bucket['tasks'] as List? ?? const []).whereType<Map>()) {
        if (legacy
            ? r['id'] == anchor.itemId && r['isLegacy'] == true
            : r['messageId'] == anchor.itemId && r['isLegacy'] != true) {
          row = Map<String, dynamic>.from(r);
          break;
        }
      }
      if (row == null) error = '没有找到这个任务';
    }
  } on Object catch (e) {
    error = '读取任务失败：${e is RaftApiException ? e.message : e.runtimeType}';
  }
  if (row == null) {
    return {
      'page': OrbPage.task,
      'title': '任务',
      'loading': error == null,
      if (error == null) 'note': '任务还在加载，不是空的',
      'error': ?error,
    };
  }
  var task = row;
  try {
    final full = await budget.within(
      w.query(
        '/tasks/channel/${anchor.channelId}/number/${task['taskNumber']}',
      ),
    );
    if (full is Map && full['task'] is Map) {
      task = {...task, ...Map<String, dynamic>.from(full['task'] as Map)};
    }
  } on Object {
    // The board row has the title, status and owner.
  }
  String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final threadId = s(task['threadChannelId']);
  var discussion = <Map<String, Object?>>[];
  var discussionLoading = false;
  if (threadId != null) {
    try {
      final page = await budget.within(
        w.client.messagePage(threadId, limit: 8),
      );
      if (page == null) {
        discussionLoading = true;
      } else {
        final rows =
            [
              for (final m
                  in (page['messages'] as List? ?? const []).whereType<Map>())
                Map<String, dynamic>.from(m),
            ]..sort(
              (a, b) => (BigInt.tryParse('${a['seq']}') ?? BigInt.zero)
                  .compareTo(BigInt.tryParse('${b['seq']}') ?? BigInt.zero),
            );
        final data = AgentModeData(w, now: clock);
        final now = clock();
        discussion = [
          for (final m in rows.skip(rows.length > 6 ? rows.length - 6 : 0))
            orbMessageJson(RaftMessage(m), w, data, now, cap: 600),
        ];
      }
    } on Object {
      discussion = [];
    }
  }
  final number = task['taskNumber'];
  final title = s(task['title']) ?? '任务';
  final description = s(task['description'] ?? task['descriptionPreview']);
  return {
    'page': OrbPage.task,
    'title': number == null ? title : '#$number $title',
    'loading': discussionLoading,
    if (discussionLoading) 'note': '任务讨论还在加载，不是空的',
    'task': {
      'number': ?number,
      'title': title,
      'status': ?s(task['status']),
      'assignee': ?s(task['claimedByName']),
      'creator': ?s(task['createdByName']),
      'channel': ?s(task['channelName']),
      'channelId': anchor.channelId,
      'id': ?s(task['id']),
      if (description != null) 'description': orbClip(description, 600).text,
      'updatedAt': ?s(task['updatedAt']),
    },
    'discussion': discussion,
  };
}

// --- Profile and other pages ------------------------------------------------

Future<Map<String, Object?>> _profile(
  OrbToolContext ctx,
  RaftLocation loc,
  OrbWaitBudget budget,
) async {
  final w = ctx.workspace;
  final profile = loc.profile!;
  final directory = w.entityDirectory..ensureAuthors();
  Map<String, dynamic>? find() {
    final rows = profile.kind == RaftProfileKind.agent
        ? directory.authorAgents
        : directory.authorMembers;
    return rows
        .where((r) => (r['userId'] ?? r['id']) == profile.id)
        .firstOrNull;
  }

  await budget.until(
    directory,
    () => find() != null || !directory.authorsLoading,
  );
  final row = find();
  String? s(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
  final name = s(row?['displayName']) ?? s(row?['name']);
  return {
    'page': OrbPage.profile,
    'title': name == null ? '资料' : '$name 的资料',
    'loading': row == null && directory.authorsLoading,
    'profile': {
      'kind': profile.kind.name,
      'id': profile.id,
      'name': ?name,
      'role': ?s(row?['role']),
      'status': ?s(row?['status']),
      'runtime': ?s(row?['runtime']),
    },
    'semantics': ctx.navigatorContext.mounted
        ? orbSemanticsLines(ctx.navigatorContext)
        : const <String>[],
  };
}

Map<String, Object?> _other(OrbToolContext ctx, RaftLocation loc) => {
  'page': OrbPage.other,
  'loading': false,
  'semantics': orbSemanticsLines(ctx.navigatorContext),
};

/// A summary of the page's Semantics: the labels and texts the current page
/// exposes to a screen reader, in tree order, without covered pages and
/// without duplicates. The fallback for pages that have no data description.
List<String> orbSemanticsLines(
  BuildContext context, {
  int max = orbMaxSemanticsLines,
}) {
  final element = context as Element;
  if (!element.mounted) return const [];
  final start =
      element.findAncestorStateOfType<NavigatorState>()?.context ?? element;
  final lines = <String>[];
  void add(String? raw) {
    final text = raw?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text == null || text.isEmpty || lines.length >= max) return;
    if (lines.isNotEmpty && lines.last == text) return;
    if (lines.contains(text)) return;
    lines.add(orbClip(text, 160).text);
  }

  void visit(Element e) {
    if (lines.length >= max) return;
    final widget = e.widget;
    if (widget is Offstage && widget.offstage) return;
    if (widget is ExcludeSemantics && widget.excluding) return;
    if (widget is Visibility && !widget.visible && !widget.maintainSemantics) {
      return;
    }
    if (widget is Semantics) {
      final p = widget.properties;
      add(p.label ?? p.value);
    } else if (widget is Text) {
      add(widget.data ?? widget.textSpan?.toPlainText());
    } else if (widget is RichText) {
      add(widget.text.toPlainText());
    }
    e.visitChildren(visit);
  }

  (start as Element).visitChildren(visit);
  return lines;
}
