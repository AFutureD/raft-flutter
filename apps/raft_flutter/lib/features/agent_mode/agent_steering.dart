import 'dart:async';

import 'gemini_live.dart' show AgentToolHandler;
import 'key_info.dart';

/// What a text agent is given for one model request: the instruction and the
/// tools. They are decided again for every request, so the app can narrow
/// both to what the state of the conversation needs.
class AgentScope {
  const AgentScope({required this.systemPrompt, required this.tools});

  final String systemPrompt;

  /// Function declarations, in the shape of a live session's `tools`.
  final List<Map<String, Object?>> tools;
}

/// One tool the agent called in a turn, with what came back.
class AgentToolRun {
  const AgentToolRun(this.name, this.args, this.result);

  final String name;
  final Map<String, Object?> args;
  final Map<String, Object?> result;
}

/// What the app makes of the words the model ended a turn with.
class AgentReview {
  const AgentReview({this.retry, this.text});

  /// The model is told this and answers once more (at most once a turn). Used
  /// when its words say something the app knows is not so ("要发吗？" with no
  /// card up).
  final String? retry;

  /// These words are said instead of the model's.
  final String? text;
}

/// The key of a tool result that ends the turn: the app's own words for it.
/// The model is not asked again and these words are the turn's text.
const agentAppSays = 'app_say';

/// How the app steers a text agent (`GeminiAgentSession`): the realtime
/// sessions know nothing of it. The model decides what to look at and which
/// tools to call; the app decides what is said for the rules it owns.
class AgentSteering {
  const AgentSteering({
    required this.scope,
    this.intercept,
    this.review,
    this.preload,
    this.confirmation,
    this.streamSafe,
  });

  /// Asked before every model request of a turn (also the second and third
  /// of the same turn, when a tool has changed the state).
  final AgentScope Function() scope;

  /// Asked at the start of every turn: what the app already knows that the
  /// answer may need (the screen, what needs the person, the card waiting),
  /// short. It rides with the person's words as context, so the model can
  /// answer in one call instead of reading first.
  final String? Function()? preload;

  /// Offered each person's turn before the model: the app may answer it
  /// itself, calling tools through [run] (so they are seen like the model's
  /// own), and returns the words to say, or null to leave the turn to the
  /// model.
  final Future<String?> Function(String said, AgentToolHandler run)? intercept;

  /// Asked when the agent has given the words of a turn for the voice layer
  /// to speak: when they ask the person to confirm an action card, what the
  /// speech has to carry (the verb, to whom, the words, the numbers, that it
  /// is a question); null for every other answer. The voice layer checks what
  /// its voice said against it, for these answers only.
  final KeyInfo? Function()? confirmation;

  /// Asked while the final answer streams, with the tools the turn has run so
  /// far and the model text of the current step so far; true: the app's review
  /// would not change the beginning of these words, so they may be spoken
  /// before the turn is over. Null (the default): nothing streams.
  final bool Function(List<AgentToolRun> runs, String draft)? streamSafe;

  /// Offered the words a turn ends with (and the tools it ran) before they
  /// are said. See [AgentReview]. [run] calls a tool the way the model's own
  /// calls go (so the app's calls are seen like them).
  final FutureOr<AgentReview?> Function(
    String reply,
    List<AgentToolRun> runs,
    AgentToolHandler run,
  )?
  review;
}

/// A session the app can speak through: [speak] says [text], verbatim, as the
/// agent's own words, as a turn of its own.
abstract interface class AppSpeaker {
  void speak(String text);
}

/// A session whose turn under way can be cut short: the person spoke over it.
/// The turn stops at its next step, says nothing, and leaves no half of itself
/// in the history; turns queued behind it are dropped too.
abstract interface class CancellableTurn {
  void cancelTurn();
}
