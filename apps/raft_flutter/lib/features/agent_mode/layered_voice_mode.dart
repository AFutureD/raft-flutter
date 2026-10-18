/// Which brain the orb runs on, chosen in the Agent settings.
enum AgentBrainMode {
  /// The realtime voice model alone listens, thinks, calls the tools and
  /// speaks (OpenAI, Gemini or Grok).
  voiceOnly('纯语音模型'),

  /// A voice model listens and speaks, a text model (the Agent) thinks and
  /// calls the tools, and the app's rules sit between them.
  layered('语音模型 + 文字 Agent');

  const AgentBrainMode(this.label);

  /// What the settings say.
  final String label;
}

/// How the voice layer of the agent layer speaks.
enum LayeredVoiceMode {
  /// The voice service speaks the answer in its natural voice. The default.
  /// Gemini Live asks the agent through its tool and tells the answer in its
  /// own words; a confirmation card's line is checked: when Live leaves out
  /// something of it, the app says the line itself. OpenAI Realtime and Grok
  /// Voice never call a tool: the app asks the agent, and has the voice say a
  /// lead-in it phrases itself and then the answer, line by line.
  liveRelays('Live 转述'),

  /// The voice service only listens (whichever it is): the app sends what the
  /// person said to the agent itself, and speaks the agent's words with the
  /// device's own voice, exactly as they are.
  appSpeaks('App 朗读');

  const LayeredVoiceMode(this.label);

  /// What the Labs control says.
  final String label;

  static LayeredVoiceMode? parse(String? name) {
    final want = name?.trim().toLowerCase();
    for (final v in values) {
      if (v.name.toLowerCase() == want) return v;
    }
    // Short names, for a command line.
    return switch (want) {
      'app' => appSpeaks,
      'relay' || 'live' => liveRelays,
      _ => null,
    };
  }
}
