/// How the voice layer of the agent layer speaks.
enum LayeredVoiceMode {
  /// Live only listens: the app sends what the person said to the agent
  /// itself, and speaks the agent's words with the device's own voice, exactly
  /// as they are.
  appSpeaks('App 朗读'),

  /// Live listens, asks the agent through its tool and says the answer; the
  /// first design, kept to compare.
  liveRelays('Live 转述');

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
