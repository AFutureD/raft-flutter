import 'gemini_live.dart' show AgentToolHandler;

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
  const AgentSteering({required this.scope, this.intercept, this.review});

  /// Asked before every model request of a turn (also the second and third
  /// of the same turn, when a tool has changed the state).
  final AgentScope Function() scope;

  /// Offered each person's turn before the model: the app may answer it
  /// itself, calling tools through [run] (so they are seen like the model's
  /// own), and returns the words to say, or null to leave the turn to the
  /// model.
  final Future<String?> Function(String said, AgentToolHandler run)? intercept;

  /// Offered the words a turn ends with (and the tools it ran) before they
  /// are said. See [AgentReview].
  final AgentReview? Function(String reply, List<AgentToolRun> runs)? review;
}

/// A session the app can speak through: [speak] says [text], verbatim, as the
/// agent's own words, as a turn of its own.
abstract interface class AppSpeaker {
  void speak(String text);
}
