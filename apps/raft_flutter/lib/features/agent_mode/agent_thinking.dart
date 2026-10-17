/// How hard the text agent (the agent layer's model) thinks before it answers:
/// Gemini 3 `thinkingConfig.thinkingLevel`, and for a 2.5 model a
/// `thinkingBudget` of about the same weight. Lower is quicker.
enum AgentThinking {
  minimal('最少', 0),
  low('低', 1024),
  medium('中', 4096),
  high('高', 8192);

  const AgentThinking(this.label, this.budget);

  /// What the Labs control says.
  final String label;

  /// The tokens a 2.5 model may think with.
  final int budget;

  /// The level a link or the store names, or null when it names none.
  static AgentThinking? parse(String? name) {
    final want = name?.trim().toLowerCase();
    for (final v in values) {
      if (v.name == want) return v;
    }
    return null;
  }
}
