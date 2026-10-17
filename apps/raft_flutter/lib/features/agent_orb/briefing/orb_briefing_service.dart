import 'dart:async';

import '../../../data/workspace_controller.dart';
import '../../agent_mode/agent_mode_data.dart';
import '../../agent_mode/gemini_text.dart';
import 'orb_briefing_models.dart';
import 'orb_briefing_reader.dart';
import 'orb_briefing_writer.dart';
import 'orb_signals.dart';

/// What each scope was last told: the version of every thing it held, so a
/// repeat briefing says only what is new.
class _Told {
  _Told(this.versions);
  final Map<String, String> versions;
}

/// Briefs the person: what needs them, how it relates to them, and where it
/// is at. Relevance comes first from deterministic signals ([OrbSignals]) over
/// the content behind the Activity rows; the model (Gemini Flash) only tells
/// "asking me" from "FYI" for ambiguous items and writes the sentences. With
/// no key, or a reply that breaks the schema, the rules write them.
class OrbBriefingService {
  OrbBriefingService(
    this.w, {
    GeminiText? model,
    DateTime Function()? now,
    this.language = 'zh',
    OrbBriefingWriter? writer,
    this.maxNeedsYou = 10,
    this.maxProgress = 6,
  }) : _now = now ?? DateTime.now,
       _writer = writer ?? OrbBriefingWriter(model: model);

  final WorkspaceController w;
  final DateTime Function() _now;
  final String language;
  final OrbBriefingWriter _writer;
  final int maxNeedsYou, maxProgress;

  static final _shared = Expando<OrbBriefingService>('orb briefing');

  /// The service of [w]: its cache and its "since last time" memory live as
  /// long as the workspace does.
  static OrbBriefingService of(WorkspaceController w, {GeminiText? model}) =>
      _shared[w] ??= OrbBriefingService(w, model: model ?? GeminiText.briefing);

  // Per item, keyed by "<id>@<version>": the model's words and verdict. An
  // item with nothing newer is never sent again.
  final _texts = <String, OrbItemText>{};
  final _overviews = <String, String>{};
  final _told = <String, _Told>{};

  /// Forgets what was briefed (the next briefing is the full one).
  void forgetTold() => _told.clear();

  final _warming = <String, Future<void>>{};
  late final _reads = OrbReadCache(now: _now);

  /// Reads [scope] and has the model word it ahead of time, so a briefing
  /// asked for soon after finds the words cached. It is not a briefing: what
  /// was told stays as it was. Never throws; one warm-up per scope at a time.
  Future<void> warm(OrbBriefScope scope) {
    final key = scope.key;
    return _warming[key] ??= _brief(scope, full: true, remember: false)
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() {
          // A block: `remove` returns this very future, and whenComplete
          // would wait on it forever.
          _warming.remove(key);
        });
  }

  /// The briefing for [scope]. A scope briefed before gets only what is new
  /// since, unless [full]; the first call, and every [full] call, give the
  /// whole picture.
  ///
  /// [modelWait] caps how long the model may take to word the items (the
  /// writer's own wait when null); past it the rules' sentences are used, so
  /// who, where and what is asked are the same either way.
  Future<OrbBriefing> brief(
    OrbBriefScope scope, {
    bool full = false,
    Duration? modelWait,
  }) async {
    // A warm-up in flight is asking the model already: wait for its words.
    final warming = _warming[scope.key];
    if (warming != null) await warming;
    return _brief(scope, full: full, modelWait: modelWait);
  }

  Future<OrbBriefing> _brief(
    OrbBriefScope scope, {
    required bool full,
    Duration? modelWait,
    bool remember = true,
  }) async {
    final reader = OrbBriefingReader(w, now: _now, cache: _reads);
    final read = scope.isActivity
        ? await reader.activity()
        : await reader.conversation(scope.conversationId!);
    final me = reader.me;
    final now = _now();

    // Deterministic verdicts and sentences.
    var items = <OrbBriefItem>[];
    var routine = <(String, String)>[];
    final requests = <String, OrbCandidate>{};
    for (final c in read.candidates) {
      var signal = OrbSignals.classify(c, me: me, now: now);
      // The Activity is the conversations: a task there only when it needs
      // the person (its talk is in its thread's row). In a channel its
      // progress stays.
      if (scope.isActivity &&
          c.source == OrbSource.task &&
          signal.bucket == OrbBucket.progress) {
        signal = OrbSignal.routine;
      }
      if (signal.bucket == OrbBucket.routine) {
        routine.add((c.id, _version(c)));
        continue;
      }
      items.add(_item(c, signal, now));
      requests[c.id] = c;
    }
    // Rows beyond the read cap are only counted.
    final skipped = read.skipped;

    // The model: the sentences and the ambiguous verdicts, for what is new.
    String key(OrbBriefItem i) => '${i.id}@${i.versionKey}';
    final drafts = [
      for (final i in items)
        if (!_texts.containsKey(key(i))) _draft(i, requests[i.id]!, now),
    ];
    String? modelOverview;
    if (drafts.isNotEmpty) {
      final result = await _writer.write(
        drafts: drafts,
        known: [
          for (final i in items)
            if (_texts.containsKey(key(i))) _texts[key(i)]!.title,
        ],
        counts: {
          'needsYou': items.where((i) => _needs(i)).length,
          'progress': items.where((i) => !_needs(i)).length,
          'routine': routine.length + skipped,
        },
        language: language,
        now: now,
        wait: modelWait,
      );
      if (result != null) {
        for (final e in result.items.entries) {
          final i = items.firstWhere((i) => i.id == e.key);
          _texts[key(i)] = e.value;
        }
        modelOverview = result.overview;
      }
    }
    final overviewKey = _overviewKey(items, routine.length + skipped);
    if (modelOverview != null) _overviews[overviewKey] = modelOverview;

    // Apply what the model wrote (now or earlier).
    items = [for (final i in items) _apply(i, _texts[key(i)])];
    final model = items.any((i) => _texts.containsKey(key(i)));

    final needs = [
      for (final i in items)
        if (_needs(i)) i,
    ]..sort(_byWaiting);
    final progress =
        [
          for (final i in items)
            if (!_needs(i)) i,
        ]..sort(
          (a, b) =>
              (b.sinceAt ?? DateTime(0)).compareTo(a.sinceAt ?? DateTime(0)),
        );
    final shownNeeds = needs.take(maxNeedsYou).toList();
    final shownProgress = progress.take(maxProgress).toList();
    // What does not fit is counted with the rest, never lost silently.
    final overflow =
        (needs.length - shownNeeds.length) +
        (progress.length - shownProgress.length);
    final routineCount = routine.length + skipped + overflow;

    // Since last time.
    final before = _told[scope.key];
    final delta = !full && before != null;
    final nowTold = <String, String>{
      for (final i in [...shownNeeds, ...shownProgress]) i.id: i.versionKey,
      for (final r in routine) r.$1: r.$2,
    };
    if (remember) _told[scope.key] = _Told(nowTold);

    bool isNew(OrbBriefItem i) =>
        !delta || before.versions[i.id] != i.versionKey;
    final newNeeds = [
      for (final i in shownNeeds)
        if (isNew(i)) i,
    ];
    final newProgress = [
      for (final i in shownProgress)
        if (isNew(i)) i,
    ];
    final newRoutine = delta
        ? routine.where((r) => before.versions[r.$1] != r.$2).length
        : routineCount;
    final carried =
        (shownNeeds.length - newNeeds.length) +
        (shownProgress.length - newProgress.length);

    final noun = scope.isActivity ? '条新动态' : '条新消息';
    final total = newNeeds.length + newProgress.length + newRoutine;
    final String overview;
    if (delta) {
      overview = total == 0
          ? '自上次简报后没有新的${scope.isActivity ? '动态' : '消息'}${carried > 0 ? '，上次说过的 $carried 件还在' : ''}'
          : '自上次简报后新增 $total 条，其中${newNeeds.isEmpty ? '没有需要你处理的' : ' ${newNeeds.length} 件需要你处理'}';
    } else if (total == 0) {
      overview = scope.isActivity ? '没有新的动态' : '这里没有新的消息';
    } else {
      overview =
          _overviews[overviewKey] ??
          '$total $noun，${newNeeds.isEmpty ? '没有需要你处理的' : '${newNeeds.length} 件需要你处理'}';
    }

    return OrbBriefing(
      scope: scope,
      overview: overview,
      needsYou: newNeeds,
      progress: newProgress,
      routineCount: newRoutine,
      isDelta: delta,
      carriedOver: delta ? carried : 0,
      writtenByModel: model,
    );
  }

  String _overviewKey(List<OrbBriefItem> items, int routine) => [
    for (final i in items) '${i.id}@${i.versionKey}:${i.reason.name}',
    'r$routine',
  ].join('|');

  bool _needs(OrbBriefItem i) => switch (i.reason) {
    OrbReason.mentionAsk ||
    OrbReason.replyAsk ||
    OrbReason.dmAsk ||
    OrbReason.awaitingApproval ||
    OrbReason.assignedBlocked ||
    OrbReason.agentBlocked ||
    OrbReason.buildFailure => true,
    _ => false,
  };

  /// What waited longest first: someone is blocked on the person.
  int _byWaiting(OrbBriefItem a, OrbBriefItem b) =>
      (a.sinceAt ?? DateTime.now()).compareTo(b.sinceAt ?? DateTime.now());

  String _version(OrbCandidate c) =>
      c.versionKey ?? c.latest?.id ?? c.sourceIds.join(',');

  // ---- items -----------------------------------------------------------------

  static String duration(Duration d) {
    if (d.inMinutes < 1) return '1 分钟';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟';
    if (d.inHours < 48) return '${d.inHours} 小时';
    return '${d.inDays} 天';
  }

  static String _why(OrbReason r) => switch (r) {
    OrbReason.mentionAsk => '点名你',
    OrbReason.replyAsk => '回复了你',
    OrbReason.dmAsk => '私信你',
    OrbReason.awaitingApproval => '等你批准',
    OrbReason.assignedBlocked => '你的任务卡住了',
    OrbReason.agentBlocked => 'Agent 卡住了',
    OrbReason.buildFailure => '构建失败',
    OrbReason.mentionFyi => '点名了你',
    OrbReason.replyFyi => '回复了你',
    OrbReason.dmFyi => '私信你',
    OrbReason.progress => '进展',
    OrbReason.systemEvent => '状态变化',
    OrbReason.routine => '',
  };

  static String _one(String text, int max) =>
      AgentHeadlines.clean(text, max: max);

  OrbBriefItem _item(OrbCandidate c, OrbSignal s, DateTime now) {
    final request = s.request ?? c.latest;
    final who = s.who ?? request?.senderName ?? '成员';
    final needs = _isNeeds(s.reason);
    final at = s.since ?? c.at ?? request?.at;
    final since = at == null
        ? ''
        : needs
        ? '已等 ${duration(now.difference(at))}'
        : '${duration(now.difference(at))}前';
    final text = request?.text ?? '';
    final topic = c.topic;
    final excerpt = _one(text, 40);

    String title;
    String? ask;
    OrbSuggestedAction? action;
    switch (s.reason) {
      case OrbReason.awaitingApproval:
        final what = topic ?? _one(text, 24);
        title = what.isEmpty ? '$who 在等你批准' : '$who 在等你批准$what';
        ask = '批准';
        action = const OrbSuggestedAction(
          label: '回复：批准',
          kind: 'reply',
          text: '批准',
        );
      case OrbReason.mentionAsk:
      case OrbReason.dmAsk:
        title = excerpt.isEmpty ? '$who 问你' : '$who 问你：$excerpt';
        ask = '回复';
        action = OrbSuggestedAction(label: '回复 $who', kind: 'reply');
      case OrbReason.replyAsk:
        title = excerpt.isEmpty ? '$who 回复了你' : '$who 回复了你：$excerpt';
        ask = '回复';
        action = OrbSuggestedAction(label: '回复 $who', kind: 'reply');
      case OrbReason.assignedBlocked:
        title = '${topic ?? '任务'}卡住了';
        ask = '解除阻塞';
        action = const OrbSuggestedAction(label: '打开任务', kind: 'open');
      case OrbReason.agentBlocked:
        title =
            '$who 卡住了${c.agentActivity == null ? '' : '：${c.agentActivity}'}';
        ask = '看一下';
        action = const OrbSuggestedAction(label: '看看 Agent', kind: 'open');
      case OrbReason.buildFailure:
        title = excerpt.isEmpty
            ? '${c.where} 构建失败'
            : '${c.where} ${_one(text, 30)}';
        ask = '看一下';
        action = const OrbSuggestedAction(label: '打开', kind: 'open');
      case OrbReason.progress when c.source == OrbSource.task:
        title = '${topic ?? '任务'}${_statusWord(c.task?['status'])}';
      case OrbReason.mentionFyi:
      case OrbReason.replyFyi:
      case OrbReason.dmFyi:
      case OrbReason.progress:
      case OrbReason.systemEvent:
      case OrbReason.routine:
        title = excerpt.isEmpty ? (topic ?? c.where) : excerpt;
    }
    return OrbBriefItem(
      id: c.id,
      title: title,
      who: who,
      whoKind: s.whoKind,
      where: c.where,
      since: since,
      sinceAt: at,
      ask: ask,
      suggestedAction: action,
      link: c.link,
      sourceIds: c.sourceIds,
      reason: s.reason,
      why: _why(s.reason),
      channelId: c.channelId,
      versionKey: _version(c),
    );
  }

  static String _statusWord(Object? status) => switch (status) {
    'in_review' => ' 交审了',
    'in_progress' => ' 在做',
    'done' => ' 完成了',
    _ => '',
  };

  static bool _isNeeds(OrbReason r) => switch (r) {
    OrbReason.mentionAsk ||
    OrbReason.replyAsk ||
    OrbReason.dmAsk ||
    OrbReason.awaitingApproval ||
    OrbReason.assignedBlocked ||
    OrbReason.agentBlocked ||
    OrbReason.buildFailure => true,
    _ => false,
  };

  OrbDraft _draft(OrbBriefItem i, OrbCandidate c, DateTime now) => OrbDraft(
    id: i.id,
    reason: i.reason.name,
    ambiguous: _ambiguous(i.reason),
    who: i.who,
    where: i.where,
    waited: i.since,
    parent: c.parent?.text ?? c.topic,
    messages: [
      for (final m
          in c.messages.reversed
              .take(OrbBriefingWriter.maxMessages)
              .toList()
              .reversed)
        (m.senderName ?? (m.isSystem ? '系统' : '成员'), m.text),
      if (c.messages.isEmpty && c.task != null)
        (i.who, '${c.topic ?? ''} ${c.task!['status']}'),
      if (c.messages.isEmpty && c.agentActivity != null)
        (i.who, c.agentActivity!),
    ],
  );

  static bool _ambiguous(OrbReason r) =>
      r == OrbReason.mentionFyi ||
      r == OrbReason.replyFyi ||
      r == OrbReason.dmFyi;

  /// Puts the model's words on an item, and its verdict on an ambiguous one:
  /// "asking me" makes it a request; FYI leaves it progress.
  OrbBriefItem _apply(OrbBriefItem i, OrbItemText? t) {
    if (t == null) return i;
    var reason = i.reason;
    var why = i.why;
    var ask = t.ask ?? i.ask;
    var action = i.suggestedAction;
    if (_ambiguous(reason) && t.askingMe == true) {
      reason = switch (reason) {
        OrbReason.mentionFyi => OrbReason.mentionAsk,
        OrbReason.replyFyi => OrbReason.replyAsk,
        _ => OrbReason.dmAsk,
      };
      why = _why(reason);
      ask ??= '回复';
      action = OrbSuggestedAction(label: '回复 ${i.who}', kind: 'reply');
    }
    if (t.reply != null && _isNeeds(reason) && action?.kind != 'open') {
      action = OrbSuggestedAction(
        label: '回复：${t.reply}',
        kind: 'reply',
        text: t.reply,
      );
    }
    return OrbBriefItem(
      id: i.id,
      title: t.title,
      who: i.who,
      whoKind: i.whoKind,
      where: i.where,
      since: _isNeeds(reason) && !_isNeeds(i.reason) && i.sinceAt != null
          ? '已等 ${duration(_now().difference(i.sinceAt!))}'
          : i.since,
      sinceAt: i.sinceAt,
      ask: _isNeeds(reason) ? ask : null,
      suggestedAction: _isNeeds(reason) ? action : null,
      link: i.link,
      sourceIds: i.sourceIds,
      reason: reason,
      why: why,
      channelId: i.channelId,
      versionKey: i.versionKey,
      askingMe: t.askingMe,
    );
  }
}
