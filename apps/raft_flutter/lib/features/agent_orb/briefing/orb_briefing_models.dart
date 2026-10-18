/// What a briefing is about: the whole Activity (動態) or one conversation
/// (a channel, a private conversation or a thread, by its channel id).
class OrbBriefScope {
  const OrbBriefScope._(this.conversationId);

  /// The Activity page: everything new for the person.
  static const activity = OrbBriefScope._(null);

  /// One conversation, by channel id (a thread is its own channel id).
  const OrbBriefScope.conversation(String id) : conversationId = id;

  final String? conversationId;

  bool get isActivity => conversationId == null;

  /// A stable key: what "since last time" is remembered under.
  String get key => isActivity ? 'activity' : 'conversation:$conversationId';

  @override
  bool operator ==(Object other) =>
      other is OrbBriefScope && other.conversationId == conversationId;

  @override
  int get hashCode => conversationId.hashCode;

  @override
  String toString() => key;
}

/// How an item concerns the person.
enum OrbBucket { needsYou, progress, routine }

/// Why an item needs the person (or why it is a progress item). Stable names:
/// they are part of the briefing JSON.
enum OrbReason {
  /// Someone mentions me and asks or requests something.
  mentionAsk,

  /// Someone replied to my message and asks something.
  replyAsk,

  /// Someone in a private conversation asks me something.
  dmAsk,

  /// Awaiting my approval or decision (a task I review, or "等你批准").
  awaitingApproval,

  /// A task assigned to me that is blocked.
  assignedBlocked,

  /// An agent I manage is blocked or failed.
  agentBlocked,

  /// A build or release failed.
  buildFailure,

  /// I am mentioned, and the model has to tell a question from an FYI.
  mentionFyi,

  /// A reply to me that may or may not ask something.
  replyFyi,

  /// A private message that may or may not ask something.
  dmFyi,

  /// A status change, result or completion in something that is mine.
  progress,

  /// A system event (a status change) on something that is mine.
  systemEvent,

  /// Nothing the person has to know.
  routine,
}

/// The one action the agent suggests for a needs-you item: a chip on the card.
/// `reply` pre-fills a reply (the app confirms before anything is sent);
/// `open` only opens the conversation.
class OrbSuggestedAction {
  const OrbSuggestedAction({
    required this.label,
    required this.kind,
    this.text,
  });
  final String label;

  /// `reply` or `open`.
  final String kind;

  /// The reply text for `reply` ("批准").
  final String? text;

  Map<String, Object?> toJson() => {
    'label': label,
    'kind': kind,
    if (text != null) 'text': text,
  };
}

/// One thing in a briefing.
class OrbBriefItem {
  const OrbBriefItem({
    required this.id,
    required this.title,
    required this.who,
    required this.where,
    required this.since,
    required this.link,
    required this.sourceIds,
    required this.reason,
    required this.why,
    this.whoKind = 'user',
    this.ask,
    this.suggestedAction,
    this.sinceAt,
    this.channelId,
    this.versionKey = '',
    this.askingMe,
    this.unread = 0,
  });

  /// Stable across briefings: the Activity row, task or agent behind it.
  final String id;

  /// One line. For a needs-you item it names who and what ("Cody 在等你批准
  /// 重构第 10 步"); for progress it is what happened, without the person.
  final String title;

  /// The real name of whoever the item is from. A system event names the
  /// actor in its text, else "系统"; never "有人".
  final String who;

  /// `user`, `agent` or `system`: what [who] is (for the avatar).
  final String whoKind;

  /// Where: "#raft-flutter", "#raft-flutter › 重构第 10 步", "@Alice".
  final String where;

  /// How long: "已等 20 分钟" for what waits for the person, "8 分钟前" else.
  final String since;

  /// The time [since] counts from (the request, or the last change).
  final DateTime? sinceAt;

  /// What the person has to do ("批准", "回复"), when they have to.
  final String? ask;
  final OrbSuggestedAction? suggestedAction;

  /// The app route (a path under `/s/<slug>/…`) that opens the real
  /// conversation, thread or task.
  final String link;

  /// Ids of the rows and messages the item was made from.
  final List<String> sourceIds;

  final OrbReason reason;

  /// The reason in the person's words ("点名你", "等你批准").
  final String why;

  final String? channelId;

  /// Changes when the thing behind the item has a newer message: what
  /// "since last time" and the model cache are keyed by.
  final String versionKey;

  /// The model's verdict on an ambiguous item; null when it was not asked.
  final bool? askingMe;

  /// How many unread messages the Activity row behind it shows ("3 条未读");
  /// 0 for a task or an Agent.
  final int unread;

  OrbBriefItem copyWith({
    String? title,
    String? ask,
    OrbSuggestedAction? suggestedAction,
    OrbReason? reason,
    String? why,
    bool? askingMe,
  }) => OrbBriefItem(
    id: id,
    title: title ?? this.title,
    who: who,
    whoKind: whoKind,
    where: where,
    since: since,
    sinceAt: sinceAt,
    ask: ask ?? this.ask,
    suggestedAction: suggestedAction ?? this.suggestedAction,
    link: link,
    sourceIds: sourceIds,
    reason: reason ?? this.reason,
    why: why ?? this.why,
    channelId: channelId,
    versionKey: versionKey,
    askingMe: askingMe ?? this.askingMe,
    unread: unread,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'who': who,
    'where': where,
    'since': since,
    if (sinceAt != null) 'sinceAt': sinceAt!.toUtc().toIso8601String(),
    'why': why,
    if (unread > 0) 'unread': unread,
    'reason': reason.name,
    if (ask != null) 'ask': ask,
    if (suggestedAction != null) 'suggestedAction': suggestedAction!.toJson(),
    'link': link,
    'sourceIds': sourceIds,
  };
}

/// What the person needs to know now, in the order to say it.
class OrbBriefing {
  const OrbBriefing({
    required this.scope,
    required this.overview,
    required this.needsYou,
    required this.progress,
    required this.routineCount,
    this.isDelta = false,
    this.carriedOver = 0,
    this.writtenByModel = false,
    this.waitingTasks = 0,
    this.waitingTaskTitles = const [],
  });

  final OrbBriefScope scope;

  /// One line: how many new, how many need the person.
  final String overview;
  final List<OrbBriefItem> needsYou, progress;

  /// Everything else, only counted ("其余 5 条是常规进度").
  final int routineCount;

  /// True when this only holds what is new since the scope was last briefed.
  final bool isDelta;

  /// Items briefed before and left out of a delta.
  final int carriedOver;

  /// The sentences came from the model (false: from the rules).
  final bool writtenByModel;

  /// In the Activity: the tasks (and blocked agents) that wait for the person.
  /// They are never cards: the Activity is for its messages, a task is "不急",
  /// so they are only counted and said at the end.
  final int waitingTasks;

  /// Up to [maxWaitingTaskTitles] of their titles.
  final List<String> waitingTaskTitles;
  static const maxWaitingTaskTitles = 3;

  /// "另外有 2 个任务在等你验收，不急", or null when none wait.
  static String? waitingTasksTail(int n) => n > 0 ? '另外有 $n 个任务在等你验收，不急' : null;

  bool get isEmpty =>
      needsYou.isEmpty &&
      progress.isEmpty &&
      routineCount == 0 &&
      waitingTasks == 0;

  /// The briefing as the model reads it. For the agent layer ([ordered]) it
  /// also says what comes first and last, so that the order is data rather
  /// than a rule in the prompt.
  Map<String, Object?> toJson({bool ordered = false}) => {
    'scope': scope.key,
    'overview': overview,
    'needsYou': [for (final i in needsYou) i.toJson()],
    'progress': [for (final i in progress) i.toJson()],
    'routineCount': routineCount,
    if (isDelta) 'sinceLastTime': true,
    if (carriedOver > 0) 'alreadyBriefed': carriedOver,
    if (waitingTasks > 0) 'waitingTasks': waitingTasks,
    if (waitingTasks > 0 && waitingTaskTitles.isNotEmpty)
      'waitingTaskTitles': waitingTaskTitles,
    // How much to say rides in the result, read right before speaking (the
    // full eval: with nothing to do the answer ran to four or five).
    if (needsYou.isEmpty) 'sayHint': '没有要用户处理的：最多两句，一句“没有要你处理的”，一句带过进展，不念条目',
    if (ordered) ...{
      if (needsYou.isEmpty) 'sayFirst': '没有要你处理的',
      if (waitingTasks > 0) 'sayLast': waitingTasksTail(waitingTasks),
      'order': '先说 needsYou 里的消息（最要紧的一两件），再用一句话带过 progress；任务不在其中，waitingTasks 只在最后用 sayLast 那一句带过。',
    },
  };
}
