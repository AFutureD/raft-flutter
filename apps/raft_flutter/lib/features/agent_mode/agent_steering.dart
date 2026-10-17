/// What a text agent is given for one model request: the instruction and the
/// tools. They are decided again for every request, so the app can narrow
/// both to what the state of the conversation needs.
class AgentScope {
  const AgentScope({required this.systemPrompt, required this.tools});

  final String systemPrompt;

  /// Function declarations, in the shape of a live session's `tools`.
  final List<Map<String, Object?>> tools;
}

/// How the app steers a text agent (`GeminiAgentSession`): the realtime
/// sessions know nothing of it.
class AgentSteering {
  const AgentSteering({required this.scope});

  /// Asked before every model request of a turn (also the second and third
  /// of the same turn, when a tool has changed the state).
  final AgentScope Function() scope;
}
