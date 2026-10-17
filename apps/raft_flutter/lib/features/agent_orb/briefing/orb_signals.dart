import 'orb_briefing_models.dart';

/// The signed-in person, as messages and tasks name them.
class OrbMe {
  const OrbMe({this.id, this.names = const {}});
  final String? id;

  /// Display name, handle, username: what an @mention may say.
  final Set<String> names;
}

/// One message as the briefing reads it: the real content, fetched, not the
/// template text of an Activity row.
class OrbMessage {
  const OrbMessage({
    required this.id,
    required this.text,
    this.seq,
    this.senderId,
    this.senderName,
    this.senderType,
    this.at,
    this.mentionsMe = false,
    this.replyCount = 0,
  });

  final String id;
  final BigInt? seq;
  final String? senderId, senderName, senderType;
  final String text;
  final DateTime? at;

  /// Names the person: an @mention in the text or in the message's mentions.
  final bool mentionsMe;
  final int replyCount;

  bool get isSystem => senderType == 'system' || senderId == 'system';
  bool from(OrbMe me) => me.id != null && senderId == me.id;
}

enum OrbSource { thread, channel, dm, mentionAction, task, agent }

/// Something that may belong in the briefing, with what was read about it.
class OrbCandidate {
  const OrbCandidate({
    required this.id,
    required this.source,
    this.where = '',
    this.link = '',
    this.channelId,
    this.messages = const [],
    this.parent,
    this.contentRead = true,
    this.rowMention = false,
    this.following = false,
    this.parentMineHint = false,
    this.unread = 0,
    this.at,
    this.task,
    this.taskCreated = false,
    this.taskAssigned = false,
    this.taskMentioned = false,
    this.agentName,
    this.agentBlocked = false,
    this.agentManaged = false,
    this.agentActivity,
    this.agentSince,
    this.sourceIds = const [],
    this.topic,
    this.versionKey,
  });

  final String id;
  final OrbSource source;
  final String where, link;
  final String? channelId;

  /// The messages read, oldest first (a thread: its replies, without
  /// [parent]).
  final List<OrbMessage> messages;
  final OrbMessage? parent;

  /// False when the content could not be read: [messages] then holds only the
  /// Activity row's own preview text, and the verdict is a guess.
  final bool contentRead;

  /// The Activity row says a message here mentions me.
  final bool rowMention;
  final bool following;

  /// The row says the thread's parent message is mine.
  final bool parentMineHint;
  final int unread;
  final DateTime? at;

  final Map<String, dynamic>? task;
  final bool taskCreated, taskAssigned, taskMentioned;

  final String? agentName, agentActivity, agentSince;
  final bool agentBlocked, agentManaged;
  final List<String> sourceIds;

  /// What the thing is about, short: the thread's first message, the task's
  /// title.
  final String? topic;

  /// Changes when the thing has something newer (default: the id of the
  /// newest message).
  final String? versionKey;

  bool get taskConcernsMe => taskCreated || taskAssigned || taskMentioned;

  OrbMessage? get latest => messages.isEmpty ? null : messages.last;
}

/// The deterministic verdict on one candidate.
class OrbSignal {
  const OrbSignal({
    required this.bucket,
    required this.reason,
    this.ambiguous = false,
    this.request,
    this.since,
    this.who,
    this.whoKind = 'user',
    this.viaTask = false,
  });

  final OrbBucket bucket;
  final OrbReason reason;

  /// Only the model can tell whether this asks me something.
  final bool ambiguous;

  /// The message the verdict rests on.
  final OrbMessage? request;

  /// When the request (or change) was made: waiting counts from here.
  final DateTime? since;
  final String? who;
  final String whoKind;

  /// The verdict rests on the task behind the conversation, not on what was
  /// said in it.
  final bool viaTask;

  OrbSignal markedViaTask() => OrbSignal(
    bucket: bucket,
    reason: reason,
    ambiguous: ambiguous,
    request: request,
    since: since,
    who: who,
    whoKind: whoKind,
    viaTask: true,
  );

  static const routine = OrbSignal(
    bucket: OrbBucket.routine,
    reason: OrbReason.routine,
  );
}

/// Relevance signals: which things need the person, which are progress, which
/// are routine. Deterministic and explainable; the model is only asked about
/// the ones marked ambiguous, and never overrides a definite verdict.
abstract final class OrbSignals {
  // A request or a question put to someone. "已确认" is a report, not a
  // request, and "请知悉" is an FYI.
  static final _request = RegExp(
    r'[?？]|吗|能不能|能否|可否|行不行|是否|要不要|怎么办|怎么样|如何|'
    r'(?<!已)(?<!已经)(?<!已被)(?:确认|批准|同意|决定|拍板|验收)|'
    r'请(?!知悉|注意|忽略|参考)|麻烦|帮(?:忙|我)|看一下|看看|回一下|回复我|'
    r'\b(?:please|could you|can you|would you|do you|should we|let me know|need you|thoughts|approve|review)\b',
    caseSensitive: false,
  );

  static final _question = RegExp(r'[?？]');

  // An explicit "waiting for you" request.
  static final _approval = RegExp(
    r'等你(?:来)?(?:批准|决定|拍板|确认|审批|点头|同意|验收|review)|'
    r'(?:请|待|需要|需你|麻烦你)你?(?:批准|审批|决定|拍板)|'
    r'waiting (?:for|on) (?:your|you)|awaiting your|'
    r'need(?:s)? your (?:approval|decision|sign-?off)',
    caseSensitive: false,
  );

  static final _failure = RegExp(
    r'(?:构建|编译|发布|部署|打包|流水线|CI|检查)\S{0,4}(?:失败|挂了|未通过|不通过|出错|报错)|'
    r'build (?:failed|failure|broke)|release (?:failed|failure)|'
    r'deploy(?:ment)? failed|ci (?:failed|is red)|checks? failed|'
    r'pipeline failed|workflow failed|❌',
    caseSensitive: false,
  );
  static final _repaired = RegExp(
    r'(?:已|已经)(?:修复|恢复|解决)|\b(?:fixed|resolved|green again)\b',
    caseSensitive: false,
  );

  // A result, completion or status change.
  static final _result = RegExp(
    r'完成|通过|合入|已合并|合并了|修复了|已修复|上线|已发布|发布了|搞定|交审|'
    r'\b(?:done|merged|passed|fixed|shipped|released|landed|moved|started|finished)\b|✅|🔄',
    caseSensitive: false,
  );

  static bool asksSomething(String text) => _request.hasMatch(text);
  static bool isApprovalRequest(String text) => _approval.hasMatch(text);
  static bool isFailure(String text) =>
      _failure.hasMatch(text) && !_repaired.hasMatch(text);
  static bool isResult(String text) => _result.hasMatch(text);

  /// A task row where the person is the one to decide: in review and theirs
  /// (they created it, or it mentions them).
  static bool isAwaitingMyReview(OrbCandidate c) =>
      c.task?['status'] == 'in_review' && (c.taskCreated || c.taskMentioned);

  static const stalledAfter = Duration(hours: 4);

  /// The verdict on [c]. [now] is the clock the waiting time is read from.
  static OrbSignal classify(
    OrbCandidate c, {
    required OrbMe me,
    required DateTime now,
  }) {
    switch (c.source) {
      case OrbSource.agent:
        return c.agentBlocked && c.agentManaged
            ? OrbSignal(
                bucket: OrbBucket.needsYou,
                reason: OrbReason.agentBlocked,
                who: c.agentName,
                whoKind: 'agent',
              )
            : OrbSignal.routine;
      case OrbSource.task:
        return _task(c, now);
      default:
        final read = _conversation(c, me);
        if (read.bucket == OrbBucket.needsYou) return read;
        // A thread that is a task's own: the task may wait for the person
        // even when the new messages say nothing about it.
        final waits = _task(c, now);
        return waits.bucket == OrbBucket.needsYou
            ? waits.markedViaTask()
            : read;
    }
  }

  static DateTime? _taskTime(Map<String, dynamic> t) => t['updatedAt'] is String
      ? DateTime.tryParse(t['updatedAt'] as String)?.toLocal()
      : null;

  static OrbSignal _task(OrbCandidate c, DateTime now) {
    final t = c.task;
    if (t == null || !c.taskConcernsMe) return OrbSignal.routine;
    final at = _taskTime(t);
    final status = '${t['status']}';
    final claimer = _name(t['claimedByName']);
    final creator = _name(t['createdByName']);
    if (isAwaitingMyReview(c)) {
      return OrbSignal(
        bucket: OrbBucket.needsYou,
        reason: OrbReason.awaitingApproval,
        since: at,
        who: claimer ?? creator,
        whoKind: claimer == null ? 'user' : 'agent',
      );
    }
    final stalled =
        status == 'in_progress' &&
        at != null &&
        now.difference(at) >= stalledAfter;
    if (c.taskAssigned && (status == 'blocked' || stalled)) {
      return OrbSignal(
        bucket: OrbBucket.needsYou,
        reason: OrbReason.assignedBlocked,
        since: at,
        who: creator,
      );
    }
    if (at != null && now.difference(at) < const Duration(hours: 24)) {
      return OrbSignal(
        bucket: OrbBucket.progress,
        reason: OrbReason.progress,
        since: at,
        who: claimer ?? creator,
        whoKind: claimer == null ? 'user' : 'agent',
      );
    }
    return OrbSignal.routine;
  }

  static String? _name(Object? v) {
    final s = v is String ? v.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }

  /// What a person says is a pending item: the messages after the person's
  /// own last message (what they already answered is done).
  static List<OrbMessage> pending(OrbCandidate c, OrbMe me) {
    final at = c.messages.lastIndexWhere((m) => m.from(me));
    return at < 0 ? c.messages : c.messages.sublist(at + 1);
  }

  static OrbSignal _conversation(OrbCandidate c, OrbMe me) {
    final open = pending(c, me);
    if (open.isEmpty) return OrbSignal.routine;
    final newest = open.last;
    final dm = c.source == OrbSource.dm;
    final parentMine =
        c.parentMineHint || (c.parent != null && c.parent!.from(me));
    // The person is the one this is said to.
    final addressed = dm || parentMine || c.rowMention || c.taskConcernsMe;

    OrbMessage? newestWhere(bool Function(OrbMessage) test) {
      for (final m in open.reversed) {
        if (test(m)) return m;
      }
      return null;
    }

    OrbSignal needs(OrbReason reason, OrbMessage m) => OrbSignal(
      bucket: OrbBucket.needsYou,
      reason: reason,
      request: m,
      since: m.at,
      who: _sender(m),
      whoKind: _kind(m),
    );

    final failed = newestWhere((m) => isFailure(m.text));
    if (failed != null) return needs(OrbReason.buildFailure, failed);

    final approval = newestWhere(
      (m) => isApprovalRequest(m.text) && (m.mentionsMe || addressed),
    );
    if (approval != null) return needs(OrbReason.awaitingApproval, approval);

    // Mentions: the message that names the person, or, when the row only
    // says a mention is among the new messages, the newest that asks.
    final mention = newestWhere((m) => m.mentionsMe && asksSomething(m.text));
    if (mention != null) return needs(OrbReason.mentionAsk, mention);
    if (c.rowMention && !open.any((m) => m.mentionsMe)) {
      final asked = newestWhere((m) => asksSomething(m.text));
      if (asked != null) return needs(OrbReason.mentionAsk, asked);
    }

    if (dm) {
      final asked = newestWhere((m) => asksSomething(m.text));
      if (asked != null) return needs(OrbReason.dmAsk, asked);
    }
    // In a thread the person started, replies are mostly reports to them,
    // and request words (批准, 确认, review) are often about someone else:
    // only a question is a definite ask; the rest is for the model.
    if (parentMine) {
      final asked = newestWhere((m) => _question.hasMatch(m.text));
      if (asked != null) return needs(OrbReason.replyAsk, asked);
    }

    // Addressed to the person, with nothing that reads as a request: only the
    // model can say whether it asks.
    final named =
        newestWhere((m) => m.mentionsMe) ?? (c.rowMention ? newest : null);
    if (named != null) {
      return _ambiguous(OrbReason.mentionFyi, named);
    }
    if (dm) return _ambiguous(OrbReason.dmFyi, newest);
    if (parentMine) return _ambiguous(OrbReason.replyFyi, newest);

    // Progress: results and status changes in what is the person's (or any
    // new result).
    final mine = c.following || c.taskConcernsMe;
    final result = newestWhere((m) => isResult(m.text));
    final system = newestWhere((m) => m.isSystem);
    if (system != null && mine) {
      return OrbSignal(
        bucket: OrbBucket.progress,
        reason: OrbReason.systemEvent,
        request: system,
        since: system.at,
        who: _sender(system),
        whoKind: 'system',
      );
    }
    if (system != null) return OrbSignal.routine;
    if (result != null && (c.unread > 0 || mine)) {
      return OrbSignal(
        bucket: OrbBucket.progress,
        reason: OrbReason.progress,
        request: result,
        since: result.at,
        who: _sender(result),
        whoKind: _kind(result),
      );
    }
    if (mine && c.unread > 0) {
      return OrbSignal(
        bucket: OrbBucket.progress,
        reason: OrbReason.progress,
        request: newest,
        since: newest.at,
        who: _sender(newest),
        whoKind: _kind(newest),
      );
    }
    return OrbSignal.routine;
  }

  static OrbSignal _ambiguous(OrbReason reason, OrbMessage m) => OrbSignal(
    // Until the model says it asks, it is progress (known, not demanding).
    bucket: OrbBucket.progress,
    reason: reason,
    ambiguous: true,
    request: m,
    since: m.at,
    who: _sender(m),
    whoKind: _kind(m),
  );

  static final _actor = RegExp(
    r'^[^\p{L}\p{N}]*([\p{L}\p{N}_.\-]+)\s+(?:moved|claimed|assigned|completed|closed|reopened|created|merged|approved|started|changed|set|marked)\b',
    unicode: true,
  );

  /// The real name of the sender. A system event names its actor in its text
  /// ("🔄 Cody moved #136 …") and is never "有人".
  static String? _sender(OrbMessage m) {
    if (m.isSystem) {
      return _actor.firstMatch(m.text)?[1] ?? '系统';
    }
    return _name(m.senderName);
  }

  static String _kind(OrbMessage m) =>
      m.isSystem ? 'system' : (m.senderType == 'agent' ? 'agent' : 'user');
}
