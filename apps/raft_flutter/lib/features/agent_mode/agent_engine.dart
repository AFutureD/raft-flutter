/// What makes the text agent's model calls: Genkit (the default), or the
/// app's own direct calls to the Gemini API. The same loop and the same rules
/// of the app run on either.
enum AgentEngine {
  genkit('Genkit'),
  direct('直连');

  const AgentEngine(this.label);

  /// What the Labs control says.
  final String label;

  static AgentEngine? parse(String? name) {
    final want = name?.trim().toLowerCase();
    for (final v in values) {
      if (v.name == want) return v;
    }
    return null;
  }
}
