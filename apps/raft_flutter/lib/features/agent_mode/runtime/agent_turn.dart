import 'dart:async';

/// Where agent mode is in the conversation. One turn at a time moves through
/// these; [AgentRuntime] is the only thing that changes the phase.
///
/// ```
/// idle ─► listening ─► understanding ─► acting ─► awaitingConfirmation
///   ▲                       │              │  ▲            │
///   │                       ▼              ▼  │            ▼
///   └──────────────────── presenting ◄─────┴──┴────────────┘
/// ```
enum AgentPhase {
  /// Nothing is going on.
  idle,

  /// The person is speaking (the mic is open, words are arriving).
  listening,

  /// The words are in; the model is deciding what to do.
  understanding,

  /// A tool of this turn is running.
  acting,

  /// A preview is on screen and the person has not decided.
  awaitingConfirmation,

  /// The result is on screen and the model is saying it.
  presenting,
}

/// Which moves between phases are allowed. A new turn (new words, typed text,
/// a barge-in) may start from any phase: that is [AgentRuntime]'s restart, not
/// a transition, and it is not in this table.
const Map<AgentPhase, Set<AgentPhase>> agentPhaseTransitions = {
  AgentPhase.idle: {
    // A tool call with no person asking (the model started on its own).
    AgentPhase.acting,
  },
  AgentPhase.listening: {AgentPhase.understanding, AgentPhase.idle},
  AgentPhase.understanding: {
    AgentPhase.acting,
    AgentPhase.awaitingConfirmation,
    AgentPhase.presenting,
    AgentPhase.idle,
  },
  AgentPhase.acting: {
    AgentPhase.understanding,
    AgentPhase.awaitingConfirmation,
    AgentPhase.presenting,
    AgentPhase.idle,
  },
  AgentPhase.awaitingConfirmation: {
    AgentPhase.acting,
    AgentPhase.understanding,
    AgentPhase.presenting,
    AgentPhase.idle,
  },
  AgentPhase.presenting: {
    AgentPhase.acting,
    AgentPhase.understanding,
    AgentPhase.awaitingConfirmation,
    AgentPhase.idle,
  },
};

/// What started a turn.
enum AgentTurnSource {
  /// The person spoke (or held the mic).
  voice,

  /// The person typed.
  text,

  /// The person spoke over the model.
  bargeIn,

  /// The model called a tool with nobody asking.
  model,
}

/// How a turn stands.
enum AgentTurnStatus {
  /// Being worked on.
  open,

  /// A newer turn started; whether this one goes on with it or is dropped is
  /// decided by the model's first call in the new turn. Nothing it had in
  /// flight is delivered meanwhile.
  superseded,

  /// The model said the new turn adds to this one: its confirmations, its
  /// screen and its results carry on under the new turn.
  merged,

  /// Done: said and shown (or only answered).
  finished,

  /// Dropped: its late results are ignored, its screen stopped, its
  /// confirmations cancelled.
  cancelled,
}

/// Why a turn was cancelled.
enum AgentCancelReason {
  /// The person said 停 / 算了 / 等一下.
  stopped,

  /// A new request that is not an addition to it.
  replaced,

  /// Agent mode was closed.
  closed,
}

/// Lets work that outlives its turn find out it is no longer wanted. Cheap:
/// a flag and a future.
class AgentCancellation {
  final _done = Completer<AgentCancelReason>();
  AgentCancelReason? _reason;

  bool get isCancelled => _reason != null;
  AgentCancelReason? get reason => _reason;

  /// Completes (once) when the turn is cancelled.
  Future<AgentCancelReason> get whenCancelled => _done.future;

  void cancel(AgentCancelReason reason) {
    if (_reason != null) return;
    _reason = reason;
    _done.complete(reason);
  }
}

/// One call of a tool that has not answered yet.
class AgentToolCall {
  AgentToolCall(this.id, this.name, this.startedAt);
  final int id;
  final String name;
  final DateTime startedAt;
}

/// One thing the person asked, and everything that was started for it.
class AgentTurn {
  AgentTurn({
    required this.id,
    required this.userText,
    required this.startedAt,
    required this.source,
  });

  /// `t1`, `t2` … The model is told the id of the previous turn so a call can
  /// say it goes on from it.
  final String id;

  /// What the person said or typed (grows while they speak).
  String userText;
  final DateTime startedAt;
  final AgentTurnSource source;

  AgentTurnStatus status = AgentTurnStatus.open;
  final cancellation = AgentCancellation();

  /// The tool calls waiting for their answer.
  final inFlight = <AgentToolCall>[];

  /// The screens this turn began (surface ids); the ones still being streamed
  /// are stopped when the turn is replaced.
  final surfaces = <String>[];

  /// The confirmations (tokens) this turn asked the person for and that are
  /// still undecided.
  final pendingConfirmations = <String>{};

  /// The turn this one replaced, until the model decides about it.
  AgentTurn? previous;

  /// The turn this one was merged into (see [AgentTurnStatus.merged]).
  AgentTurn? mergedInto;

  /// Whether the model has made a call in this turn that says what it is
  /// about (as opposed to a mood or a spotlight).
  bool classified = false;

  /// What the turn showed or did, in a few words, for the next turn's context
  /// ("展示了 8 个任务").
  String? summary;

  /// Everything the turn showed or did, one short phrase each, in order. The
  /// turn context repeats the latest ones, so the model still knows after the
  /// session dropped the old turns from its window (context compression).
  final outcomes = <String>[];

  /// The model has said its last word for this turn.
  bool modelDone = false;

  /// Something was put on the screen for this turn.
  bool rendered = false;

  /// The model has been given the turn context (see `AgentRuntime.contextLine`).
  bool contextTold = false;

  /// The person only stopped something ("算了"): nothing more is asked of the
  /// model, and calls it still makes are refused.
  bool stopRequest = false;

  /// Whether this turn (or the one it was merged into) still counts: results
  /// may be shown and screens go on streaming.
  bool get isLive =>
      status == AgentTurnStatus.open ||
      status == AgentTurnStatus.merged && (mergedInto?.isLive ?? false);

  /// A turn whose results must not be delivered: replaced or cancelled and not
  /// (yet) taken over by a newer one.
  bool get dropped =>
      status == AgentTurnStatus.cancelled ||
      status == AgentTurnStatus.superseded;

  @override
  String toString() => 'AgentTurn($id ${status.name} "$userText")';
}
