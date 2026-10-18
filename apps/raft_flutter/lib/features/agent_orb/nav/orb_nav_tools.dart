import 'dart:async';

import 'package:raft_client/raft_client.dart';

import '../../../data/raft_location.dart';
import '../../../data/raft_navigation_history.dart';
import '../../../data/resource_row_reconcile.dart' show activityItemKey;
import '../../../data/workspace_controller.dart';
import '../../activity_destination.dart';
import '../../agent_mode/agent_mode_data.dart';
import '../orb_tool.dart';
import '../orb_tool_docs.dart' show orbToolDescription;
import '../screen/orb_screen.dart';
import '../screen/orb_screen_contract.dart';
import 'orb_choice.dart';
import 'orb_fuzzy.dart';
import 'orb_page_description.dart';
import 'orb_resolver.dart';
import 'orb_vocabulary.dart';
import 'orb_wait.dart';

export 'orb_page_description.dart'
    show describeOrbPage, orbDirectoryOf, orbMessageJson;
export 'orb_resolver.dart'
    show OrbDirectory, OrbKind, OrbMatch, OrbResolution, resolveOrbTarget;
export 'orb_choice.dart' show orbChannelsLine, orbNavLog, orbTargetsJson;
export 'orb_vocabulary.dart' show OrbDestination, orbVocabulary;

/// What `navigate` adds to its answer once it has arrived: the facts of the
/// place (for a conversation or the Activity, who needs the person and what
/// for), as JSON; null when the destination has none. It is given the match
/// that was opened. An error or a slow answer never fails the navigation: the
/// answer then says the facts were not read.
typedef OrbArrivalBrief = Future<Map<String, Object?>?> Function(
  OrbToolContext ctx,
  OrbMatch match,
);

/// The most `navigate` waits for [OrbArrivalBrief].
const orbArrivalWait = Duration(seconds: 10);

/// The navigation tools of the Agent orb: `navigate`, `list_targets`,
/// `describe_page` and `read_conversation`.
///
/// `navigate` goes where the model CHOOSES by id: a page from the enum of its
/// declaration (each id with its names and what is there), or a channel,
/// private conversation, member, discussion or task from `list_targets`. The
/// free-text `target` is only the fallback for a name the model could not
/// find; it runs the fuzzy matcher over the directory. It uses the App's own
/// navigation (the same
/// path as a tap, so Back returns), holds `operating` while it moves, waits
/// for the destination's first data (or a definite empty or error; at most
/// about 5 s) and answers `{route, title, page}` where `page` is what
/// `describe_page` would say. Ambiguous words answer `{candidates}`, unknown
/// words `{error}`; an id that does not exist answers `{error, valid}` with the
/// nearest ids.
///
/// [arrivalBrief] adds the facts of where `navigate` arrived (see
/// [OrbArrivalBrief]): without it the answer is the page alone.
List<OrbTool> orbNavigationTools({OrbArrivalBrief? arrivalBrief}) => [
  OrbTool(
    declaration: _navigateDeclaration,
    handler: (args, ctx) => _navigate(args, ctx, arrivalBrief),
  ),
  OrbTool(declaration: _listTargetsDeclaration, handler: _listTargets),
  OrbTool(declaration: _describePageDeclaration, handler: _describePage),
  OrbTool(
    declaration: _readConversationDeclaration,
    handler: _readConversation,
  ),
  OrbTool(declaration: _openItemDeclaration, handler: _openItem),
];

// --- open_item ----------------------------------------------------------------

final _openItemDeclaration = <String, Object?>{
  'name': 'open_item',
  'description': orbToolDescription('open_item'),
  'parameters': {
    'type': 'object',
    'properties': {
      'n': {'type': 'integer', 'description': '第几条（describe_page 的 n）'},
      'id': {'type': 'string', 'description': '条目的 id（describe_page 的 id）'},
    },
  },
};

/// Opens an Activity row as a tap on it would (Kevin on the G100: "打开动态
/// 里的第一个消息" was only ever read, never opened).
Future<Map<String, Object?>> _openItem(
  Map<String, Object?> args,
  OrbToolContext ctx,
) async {
  final w = ctx.workspace;
  if (w.server == null) return {'error': '还没有进入工作区'};
  final store = w.activityUnreadIfBound ?? w.activityUnread;
  if (!store.hasAcceptedWindow) {
    return {'error': '动态还没读到，先打开动态再说第几条'};
  }
  final rows = [
    for (final r in store.acceptedRows) Map<String, dynamic>.from(r),
  ];
  final data = AgentModeData(w);
  final items = data.activityItems(rows).take(orbMaxActivityItems).toList();
  final n = (args['n'] as num?)?.toInt();
  final id = _str(args['id']);
  int? index;
  if (n != null) {
    if (n < 1 || n > items.length) {
      return {'error': '动态里只有 ${items.length} 条，没有第 $n 条'};
    }
    index = n - 1;
  } else if (id != null) {
    final bare = id.startsWith('activity:') ? id.substring(9) : id;
    final at = items.indexWhere(
      (i) => i.id == id || i.id == 'activity:$bare' || i.id.endsWith(':$bare'),
    );
    if (at < 0) return {'error': '动态里没有这一条，先调 describe_page 看条目'};
    index = at;
  } else {
    return {'error': '要给 n（第几条）或 id'};
  }
  final item = items[index];
  final key = item.id.startsWith('activity:') ? item.id.substring(9) : item.id;
  final row = rows.where((r) => activityItemKey(r) == key).firstOrNull;
  // The phone's own tap (WorkspaceView.openCanonicalActivity, single): the
  // route, then the thread's or the message's data. Navigating alone left
  // a thread page with nothing in it (G100).
  final target = row == null
      ? null
      : ActivityDestination.fromRow(row, canonical: false, mobile: true);
  if (target == null) return {'error': '这一条打不开'};
  ctx.operating.value = true;
  try {
    w.navigation.navigate(target.canonicalLocation(w.location.serverSlug));
    w.closeThread(navigate: false);
    if (target.thread) {
      unawaited(
        w
            .resolveConversationChannel(target.channelId, preserveThread: true)
            .catchError((Object _) {}),
      );
      await w.openThreadIdentity(
        parentChannelId: target.channelId,
        parentMessageId: target.parentMessageId!,
        focusedMessageId: target.messageId,
        navigate: false,
      );
    } else {
      await w.jumpToMessage(
        target.channelId,
        target.messageId,
        navigate: false,
      );
    }
  } on Object {
    return {'error': '这一条打不开'};
  }
  return {
    'opened': index + 1,
    'title': item.place ?? item.excerpt ?? '那一条',
    'route': w.location.toString(),
    'note': '已经打开；要说内容就调 describe_page 或 read_conversation',
    // What can be done on the page it opened (a conversation: its text is
    // read with describe_page, so the controls only).
    'screen': await OrbScreen.of(w)
        .contractFor(ctx, detail: OrbScreenDetail.arrival),
  };
}

/// One line per destination for the declaration: `id = 中文 / English：what
/// is there`. The model reasons on this, so it carries both names.
String orbPageTable() => [
  for (final d in orbVocabulary)
    '${d.id} = ${d.zhName} / ${d.label}：${d.about}',
].join('\n');

/// The `navigate` declaration. Built from [orbVocabulary], so a new
/// destination is in the enum and the table by itself.
final _navigateDeclaration = <String, Object?>{
  'name': 'navigate',
  'description': orbToolDescription('navigate'),
  'parameters': {
    'type': 'object',
    'properties': {
      'page': {
        'type': 'string',
        'enum': [for (final d in orbVocabulary) d.id],
        'description':
            'App 的页面，选一个 id（id = 中文名 / English：那里有什么）：\n${orbPageTable()}',
      },
      'channel_id': {
        'type': 'string',
        'description':
            '频道的 id（list_targets 的 channels 或提示里的列表）；配 task_number 时限定哪个频道的任务',
      },
      'dm_id': {'type': 'string', 'description': '私信的 id（list_targets 的 dms）'},
      'person_id': {
        'type': 'string',
        'description': '成员或 Agent 的 id（list_targets 的 people），打开他的资料页',
      },
      'thread_id': {
        'type': 'string',
        'description': '讨论的 id（list_targets 的 threads）',
      },
      'task_number': {'type': 'integer', 'description': '任务编号，比如 136'},
      'target': {
        'type': 'string',
        'description': '用户说的名字，原样传（人、频道、私信、任务）；给了它就不要再给 page 或其他 id',
      },
      'kind': {
        'type': 'string',
        'enum': ['channel', 'dm', 'person', 'profile', 'task', 'thread'],
        'description': '只配 target 用：已经知道名字是哪一类时给',
      },
    },
  },
};

final _listTargetsDeclaration = <String, Object?>{
  'name': 'list_targets',
  'description': orbToolDescription('list_targets'),
  'parameters': {
    'type': 'object',
    'properties': {
      'kind': {
        'type': 'string',
        'enum': ['channels', 'dms', 'people', 'threads'],
        'description': '只要哪一类；省略是全部',
      },
    },
  },
};

final _describePageDeclaration = <String, Object?>{
  'name': 'describe_page',
  'description': orbToolDescription('describe_page'),
};

final _readConversationDeclaration = <String, Object?>{
  'name': 'read_conversation',
  'description': orbToolDescription('read_conversation'),
  'parameters': {
    'type': 'object',
    'properties': {
      'conversation': {
        'type': 'string',
        'description': '频道名 / 私信对象名 / 频道或讨论的 id；省略是当前对话',
      },
      'since': {
        'type': 'string',
        'enum': ['last_read', 'recent'],
        'description': 'last_read 上次读到之后的未读消息 / recent 最近的消息（默认）',
      },
      'limit': {'type': 'integer', 'description': '最多几条，默认 20，最多 50'},
    },
  },
};

/// " (HTTP 403)" for a refused request; the server's own text is not passed on.
String _status(Object e) =>
    e is RaftApiException && e.status != null ? '（HTTP ${e.status}）' : '';

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

// --- describe_page ----------------------------------------------------------

Future<Map<String, Object?>> _describePage(
  Map<String, Object?> args,
  OrbToolContext ctx,
) async {
  if (ctx.workspace.server == null) return {'error': '还没有进入工作区'};
  final budget = OrbWaitBudget(orbDescribeWait);
  try {
    return await describeOrbPage(ctx, budget: budget);
  } finally {
    budget.dispose();
  }
}

// --- navigate ---------------------------------------------------------------

Future<Map<String, Object?>> _listTargets(
  Map<String, Object?> args,
  OrbToolContext ctx,
) async {
  final w = ctx.workspace;
  if (w.server == null) return {'error': '还没有进入工作区'};
  w.entityDirectory.ensureAuthors();
  final only = _str(args['kind']);
  if (only != null &&
      !const {'channels', 'dms', 'people', 'threads'}.contains(only)) {
    return {'error': 'kind 只能是 channels、dms、people、threads 之一'};
  }
  if ((only == null || only == 'people') && w.entityDirectory.authorsLoading) {
    final budget = OrbWaitBudget(const Duration(seconds: 3));
    try {
      await budget.until(
        w.entityDirectory,
        () => !w.entityDirectory.authorsLoading,
      );
    } finally {
      budget.dispose();
    }
  }
  return orbTargetsJson(orbDirectoryOf(w), only: only);
}

Future<Map<String, Object?>> _navigate(
  Map<String, Object?> args,
  OrbToolContext ctx,
  OrbArrivalBrief? arrivalBrief,
) async {
  final w = ctx.workspace;
  final target = _str(args['target']) ?? _str(args['name']);
  // A name that was given is the destination. The page the model sends along
  // with it ("home", a default it adds) is not a second one, and used to win.
  if (target != null && args['page'] != null) {
    args = {...args}..remove('page');
  }
  final hasId = orbIdParams.any((p) => _str(args[p]) != null || args[p] is num);
  if (target == null && !hasId) {
    return {
      'error': '需要一个目的地：page、channel_id、dm_id、person_id、thread_id、task_number 之一（找不到名字时才用 target）',
    };
  }
  if (w.server == null) return {'error': '还没有进入工作区'};
  final kind = _str(args['kind']);

  // What was chosen is checked against what the App holds now. Members load
  // in the background: a name or id that fits nothing waits for them once.
  w.entityDirectory.ensureAuthors();
  OrbMatch? match;
  OrbResolution resolution = const OrbResolution.none('');
  OrbChoice? choice;
  void resolve() {
    final directory = orbDirectoryOf(w);
    choice = chooseOrbById(args, directory);
    if (choice == null && target != null) {
      resolution = resolveOrbTarget(target, directory, kind: kind);
    }
  }

  bool nothing() => choice != null
      ? choice!.error != null
      : resolution.match == null && resolution.candidates.isEmpty;
  resolve();
  if (nothing() && w.entityDirectory.authorsLoading) {
    final budget = OrbWaitBudget(const Duration(seconds: 3));
    try {
      await budget.until(
        w.entityDirectory,
        () => !w.entityDirectory.authorsLoading,
      );
    } finally {
      budget.dispose();
    }
    resolve();
  }

  if (choice != null) {
    if (choice!.error != null) {
      orbNavLog('invalid ${choice!.param}');
      return choice!.error!;
    }
    match = choice!.match;
    orbNavLog('choose ${choice!.param}=${match!.id} kind=${match.kind.name}');
  } else {
    if (resolution.candidates.isNotEmpty) {
      orbNavLog('fallback target candidates=${resolution.candidates.length}');
      return _candidates(resolution.candidates);
    }
    match = resolution.match;
    if (match == null) {
      orbNavLog('fallback target none');
      return {
        'error': resolution.error ?? '没有找到「$target」',
        if (resolution.suggestion != null)
          'suggestion': resolution.suggestion!.toJson(),
      };
    }
    orbNavLog('fallback target=${match.id} kind=${match.kind.name}');
  }

  final budget = OrbWaitBudget(orbNavigateWait, operating: ctx.operating);
  ctx.operating.value = true;
  try {
    if (match.kind == OrbKind.task) {
      final task = await _resolveTask(w, match, budget);
      if (task.candidates != null) return _candidates(task.candidates!);
      if (task.error != null) return {'error': task.error};
      match = task.match!;
    }
    final moved = await _go(ctx, match, budget);
    if (moved.error != null) return {'error': moved.error};
    // The facts of the place, read by the app (not left to the model to make
    // out of the page): who needs the person here, and for what. Read while
    // the page is described, not after it.
    final briefed = arrivalBrief == null || budget.interrupted
        ? null
        : arrivalBrief(ctx, match).timeout(orbArrivalWait);
    briefed?.ignore();
    final page = await describeOrbPage(ctx, budget: budget);
    final loading = page['loading'] == true;
    Map<String, Object?>? briefing;
    var briefingFailed = false;
    if (briefed != null && !budget.interrupted) {
      try {
        briefing = await briefed;
      } on Object {
        briefingFailed = true;
      }
    }
    return {
      'route': w.location.toString(),
      'title': page['title'] ?? match.title,
      'matched': match.toJson(),
      if (moved.already) 'alreadyThere': true,
      if (budget.interrupted) 'interrupted': true,
      if (budget.interrupted) 'note': '用户碰了屏幕，Agent 已让出控制',
      'loading': loading,
      if (loading && !budget.interrupted)
        'note': '等了约 5 秒，页面的数据还没读完：这是还在加载，不是空的。稍后可以调 describe_page 再看',
      // With a briefing, what matters is said there: the page's lists (every
      // item with its id) would only slow the answer and get ids read aloud.
      // Already there, the person likely wants what is on the page: its
      // rows come along (and how to read them), not only the briefing.
      if (moved.already && briefing != null) 'readNote': '已经在这个页面：用户要“读”内容时，按 page.items 的顺序逐条说谁、在哪、说了什么，不要拿 briefing 代替；问“什么需要我处理”才说 briefing',
      'page': briefing == null || moved.already
          ? page
          : {
              for (final e in page.entries)
                if (e.value is! List) e.key: e.value,
              'itemsNote':
                  '页面条目没有附上，要说的在 briefing 里；用户要逐条看或读原文时再调 describe_page',
            },
      'briefing': ?briefing,
      if (briefingFailed)
        'briefingNote':
            '这里的简报没读出来：不要自己从页面内容归纳谁需要用户处理，可以调 get_briefing 再试，或如实说没读到',
    };
  } on Object catch (e) {
    return {'error': '没能打开${_status(e)}'};
  } finally {
    budget.dispose();
    ctx.operating.value = false;
  }
}

/// The `navigate` argument that goes to [m] (the candidate's `use`).
Map<String, Object?> _use(OrbMatch m) => switch (m.kind) {
  OrbKind.page => {'page': m.id},
  OrbKind.channel => {'channel_id': m.id},
  OrbKind.dm => {'dm_id': m.id},
  OrbKind.person || OrbKind.profile => {'person_id': m.id},
  OrbKind.thread => {'thread_id': m.id},
  OrbKind.task => {
    'task_number': m.data['number'],
    if (m.data['row'] is Map && (m.data['row'] as Map)['channelId'] != null)
      'channel_id': (m.data['row'] as Map)['channelId'],
  },
};

Map<String, Object?> _candidates(List<OrbMatch> found) => {
  'candidates': [
    for (final m in found) {...m.toJson(), 'use': _use(m)},
  ],
  'note': '有几个都像，请用户选一个，再用选中项 use 里的参数调 navigate',
};

typedef _Moved = ({String? error, bool already});

_Moved _fail(String error) => (error: error, already: false);
const _Moved _ok = (error: null, already: false);
const _Moved _same = (error: null, already: true);

/// Settings pages whose visit the workspace gates by capability.
const _gatedSettings = {
  'server': 'workspace-settings',
  'providers': 'providers',
  'integrations': 'integrations',
  'im-bridges': 'im-bridges',
  'administration': 'administration',
  'billing': 'billing',
};

/// Moves the app to [match] by the App's own navigation.
Future<_Moved> _go(
  OrbToolContext ctx,
  OrbMatch match,
  OrbWaitBudget budget,
) async {
  final w = ctx.workspace;
  switch (match.kind) {
    case OrbKind.page:
      final d = orbVocabulary.firstWhere((d) => d.id == match.id);
      if (d.channelTab != null) {
        final here = w.location;
        if (here.route != RaftRoute.channel && here.route != RaftRoute.dm) {
          return _fail('先说是哪个频道或私信，再说它的${d.zhName}');
        }
        final next = here.withQuery({'chatTab': d.channelTab});
        if (next.uri == here.uri) return _same;
        w.navigation.navigate(next);
        w.notifyListeners();
        return _ok;
      }
      final gate = d.section ?? _gatedSettings[d.settingsPath.firstOrNull];
      if (gate != null && !w.canVisitSection(gate)) {
        return _fail('你在这个工作区里没有权限打开「${d.zhName}」');
      }
      final target = d.locationFor(w.location.serverSlug);
      if (w.location.uri == target.uri) return _same;
      w.closeThread(navigate: false);
      if (d.section != null) {
        w.setSection(d.section!);
      } else {
        w.navigation.navigate(target);
        w.notifyListeners();
      }
      return w.location.route == d.route ? _ok : _fail('没能打开「${d.zhName}」');
    case OrbKind.channel || OrbKind.dm:
      final channel = [
        ...w.channels,
        ...w.dms,
      ].where((c) => c.id == match.id).firstOrNull;
      if (channel == null) return _fail('这个对话已经不在列表里了');
      final here = w.location;
      if ((here.route == RaftRoute.channel || here.route == RaftRoute.dm) &&
          here.entityId == channel.id &&
          here.thread == null &&
          here.task == null &&
          here.profile == null) {
        return _same;
      }
      // The call returns when the first page is in; the wait below watches
      // the window, so a slow page does not hold this call past its cap.
      w.closeThread(navigate: false);
      unawaited(w.selectChannel(channel).catchError((Object _) {}));
      return _ok;
    case OrbKind.profile || OrbKind.person:
      final kind = match.data['profileKind'] == 'agent'
          ? RaftProfileKind.agent
          : RaftProfileKind.human;
      final here = w.location.profile;
      if (here?.kind == kind && here?.id == match.id) return _same;
      w.openProfile(kind, match.id);
      return w.location.profile == null ? _fail('没能打开这个资料') : _ok;
    case OrbKind.thread:
      final channelId = _str(match.data['parentChannelId']);
      if (channelId == null) return _fail('这个讨论缺少所在频道');
      final here = w.location.thread;
      if (here?.channelId == channelId && here?.itemId == match.id) {
        return _same;
      }
      // As the Activity page opens a discussion: the parent conversation is
      // the page, the discussion its slot, in one history entry.
      final dm = w.dms.any((c) => c.id == channelId);
      final next = ActivityDestination(
        channelId: channelId,
        dm: dm,
        parentMessageId: match.id,
        threadChannelId: _str(match.data['threadChannelId']),
      ).canonicalLocation(w.location.serverSlug);
      w.navigation.navigate(next);
      w.closeThread(navigate: false);
      w.notifyListeners();
      unawaited(
        w
            .resolveConversationChannel(channelId, preserveThread: true)
            .catchError((Object _) {}),
      );
      unawaited(
        w
            .openThreadIdentity(
              parentChannelId: channelId,
              parentMessageId: match.id,
              initialThreadChannelId: _str(match.data['threadChannelId']),
              navigate: false,
            )
            .catchError((Object _) {}),
      );
      return w.location.thread == null ? _fail('没能打开这个讨论') : _ok;
    case OrbKind.task:
      return _openTask(w, match);
  }
}

/// Opens a task the way the Tasks board does (the task slot of the URL).
_Moved _openTask(WorkspaceController w, OrbMatch match) {
  final row = match.data['row'];
  if (row is! Map) return _fail('没有找到这个任务');
  final channelId = _str(row['channelId']);
  final legacy = row['isLegacy'] == true;
  final itemId = _str(legacy ? row['id'] : row['messageId']);
  if (channelId == null || itemId == null) return _fail('这个任务没有可以打开的页面');
  final anchor = '$channelId:$itemId';
  final here = w.location;
  if (legacy
      ? here.legacyTask?.toString() == anchor
      : here.task?.toString() == anchor) {
    return _same;
  }
  w.closeThread(navigate: false);
  final next = w.location.withQuery({
    'profile': null,
    if (legacy) 'legacyTask': anchor else 'task': anchor,
    if (legacy) 'thread': null,
  });
  // The board's rule: when no task is open, the list under it is the Back
  // destination, so a profile or thread panel is dropped first.
  if (w.location.task == null && w.location.legacyTask == null) {
    final base = next.withQuery({'task': null, 'legacyTask': null});
    if (base.uri.query != w.location.uri.query) {
      w.navigation.navigate(base, kind: RaftNavigationKind.replace);
    }
  }
  w.navigation.navigateTask(next);
  w.notifyListeners();
  return _ok;
}

/// Finds the task numbered [match]: its row, or the choices when several
/// channels have that number.
Future<({OrbMatch? match, List<OrbMatch>? candidates, String? error})>
_resolveTask(
  WorkspaceController w,
  OrbMatch match,
  OrbWaitBudget budget,
) async {
  final number = match.data['number'] as int;
  final hint = _str(match.data['channelHint']);
  List<Map<String, dynamic>>? rows;
  try {
    rows = await budget.within(AgentModeData(w).searchTasks('$number'));
  } on Object catch (e) {
    return (match: null, candidates: null, error: '读任务列表失败${_status(e)}');
  }
  if (rows == null) {
    return (
      match: null,
      candidates: null,
      error: '任务列表还没读出来（超时），不是没有这个任务，请稍后再试',
    );
  }
  var found = <Map<String, dynamic>>[
    for (final r in rows)
      if (r['taskNumber'] == number) r,
  ];
  if (hint != null) {
    final narrowed = [
      for (final r in found)
        if (orbNameScore(hint, '${r['channelName'] ?? ''}') >= 0.72) r,
    ];
    if (narrowed.isNotEmpty) found = narrowed;
  }
  final seen = <String>{};
  found = [
    for (final r in found)
      if (seen.add('${r['channelId']}|${r['id']}')) r,
  ];
  if (found.isEmpty) {
    return (match: null, candidates: null, error: '没有找到任务 #$number');
  }
  OrbMatch of(Map<String, dynamic> r) => OrbMatch(
    kind: OrbKind.task,
    id: '#$number',
    title: '任务 #$number ${r['title'] ?? ''}'.trim(),
    score: 1,
    reason: '#${r['channelName'] ?? ''} 频道的任务 #$number（${r['status'] ?? ''}）',
    data: {'number': number, 'row': r, 'channelHint': r['channelName']},
  );
  if (found.length > 1) {
    return (
      match: null,
      candidates: [for (final r in found.take(6)) of(r)],
      error: null,
    );
  }
  return (match: of(found.single), candidates: null, error: null);
}

// --- read_conversation ------------------------------------------------------

Future<Map<String, Object?>> _readConversation(
  Map<String, Object?> args,
  OrbToolContext ctx,
) async {
  final w = ctx.workspace;
  if (w.server == null) return {'error': '还没有进入工作区'};
  var said =
      _str(args['conversation']) ??
      _str(args['channel']) ??
      _str(args['thread']) ??
      _str(args['id']) ??
      _str(args['name']);
  // An Activity item's id as describe_page gives it ("thread:<id>",
  // "channel:<id>", "dm:<id>") or a briefing scope ("conversation:<id>").
  final prefixed = said == null
      ? null
      : RegExp(r'^(?:thread|channel|dm|conversation):(.+)$').firstMatch(said);
  if (prefixed != null) said = prefixed[1];
  final since = _str(args['since']) == 'last_read' ? 'last_read' : 'recent';
  final limit = ((args['limit'] as num?)?.toInt() ?? 20).clamp(1, 50);

  // Which conversation: an id the App holds, a name, an id the App does not
  // list (a thread's channel), or the open one.
  final all = [?w.channel, ...w.channels, ...w.dms];
  String? id;
  RaftChannel? channel;
  if (said == null) {
    final loc = w.location;
    id = loc.thread != null
        ? w.threadChannelId
        : (loc.entityId ?? w.channel?.id);
  } else {
    channel = all.where((c) => c.id == said).firstOrNull;
    id = channel?.id;
    if (id == null) {
      var res = resolveOrbTarget(said, orbDirectoryOf(w), kind: 'channel');
      if (res.match == null && res.candidates.isEmpty) {
        res = resolveOrbTarget(said, orbDirectoryOf(w), kind: 'dm');
      }
      if (res.candidates.isNotEmpty) return _candidates(res.candidates);
      final m = res.match;
      if (m != null) {
        id = m.id;
      } else if (_looksLikeId(said)) {
        id = said;
      } else {
        return {'error': res.error ?? '没有找到「$said」'};
      }
    }
  }
  if (id == null) return {'error': '没有指定要读哪个对话，当前也没有打开的对话'};
  channel ??= all.where((c) => c.id == id).firstOrNull;

  final unreadHere = w.unread[id] ?? 0;
  final bounded = since == 'last_read' ? unreadHere.clamp(0, limit) : limit;
  final String name = channel == null
      ? id
      : channel.type == 'dm'
      ? channel.peerLabel
      : '#${channel.name}';
  if (since == 'last_read' && unreadHere == 0) {
    return {
      'conversation': {'id': id, 'name': name},
      'since': since,
      'unread': 0,
      'messages': const <Object?>[],
      'note': '没有未读消息（已读状态没有被改动）',
    };
  }
  final Map<String, dynamic> page;
  try {
    // A plain read of the page: it sends no read receipt.
    page = await w.client.messagePage(id, limit: bounded);
  } on Object catch (e) {
    return {'error': '读取失败${_status(e)}'};
  }
  final rows = [
    for (final m in (page['messages'] as List? ?? const []).whereType<Map>())
      RaftMessage(Map<String, dynamic>.from(m)),
  ]..sort((a, b) => a.seq.compareTo(b.seq));
  final data = AgentModeData(w);
  final now = DateTime.now();
  final summaries = page['threadSummariesByParentMessageId'];
  final shown = rows.length > bounded
      ? rows.sublist(rows.length - bounded)
      : rows;
  final bounded2 = orbBoundMessages(
    [
      for (final m in shown)
        orbMessageJson(
          m,
          w,
          data,
          now,
          summaries: summaries is Map
              ? Map<String, dynamic>.from(summaries)
              : null,
        ),
    ],
    maxMessages: 50,
    textBudget: 24000,
  );
  final messages = bounded2.messages;
  return {
    'conversation': {
      'id': id,
      'name': name,
      'type': channel == null
          ? 'conversation'
          : (channel.type == 'dm' ? 'dm' : 'channel'),
    },
    'since': since,
    if (since == 'last_read') 'unread': unreadHere,
    'count': messages.length,
    if (page['hasMore'] == true || rows.length > shown.length)
      'hasMoreAbove': true,
    if (bounded2.omitted > 0) 'omitted': bounded2.omitted,
    'empty': messages.isEmpty,
    'messages': messages,
    'readStateChanged': false,
  };
}

bool _looksLikeId(String s) =>
    RegExp(r'^[A-Za-z0-9_\-]{4,64}$').hasMatch(s) && RegExp(r'\d').hasMatch(s);
