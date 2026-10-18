/// The language the voice agent answers in (the person's choice, kept in
/// `AgentVoiceSettings.language`). The agent is pinned to it: a word of
/// another language in what the person says does not change it.
///
/// The prompt lines are the one place each language's instruction is written;
/// [speechCode] is the Gemini Live `speechConfig.languageCode`.
enum AgentLanguage {
  zh('中文', 'cmn-CN', '始终用中文回答，用户夹杂英文词也不要换语言。', '始终用中文说话，用户夹杂英文词也不要换语言。'),
  en(
    'English',
    'en-US',
    'Always answer in English, even if the person mixes in words of another language.',
    'Always speak English, even if the person mixes in words of another language.',
  );

  const AgentLanguage(this.label, this.speechCode, this.line, this.relayLine);

  /// How the choice is shown.
  final String label;

  /// The BCP-47 code Gemini Live's `speechConfig.languageCode` takes.
  final String speechCode;

  /// The prompt line of an agent that answers.
  final String line;

  /// The prompt line of the voice that only relays what the agent says.
  final String relayLine;

  /// The 【语言】 section of a prompt.
  String get promptSection => '【语言】$line\n\n';
}
