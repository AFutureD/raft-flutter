/// How the voice layer of the agent layer speaks.
enum LayeredVoiceMode {
  /// Live listens, asks the agent through its tool and tells the answer in
  /// its natural voice, in its own words. The default. A confirmation card's
  /// line is checked: when Live leaves out something of it, the app says the
  /// line itself.
  liveRelays('Live 转述'),

  /// Live only listens: the app sends what the person said to the agent
  /// itself, and speaks the agent's words with the device's own voice, exactly
  /// as they are.
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
