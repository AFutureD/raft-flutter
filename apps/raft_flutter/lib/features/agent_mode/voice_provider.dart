import 'dart:typed_data';

import 'agent_audio.dart';
import 'gemini_live.dart';
import 'openai_realtime.dart';

/// Which realtime voice service agent mode talks to.
enum AgentVoiceProvider { gemini, openai }

const agentVoiceProviderLabels = {
  AgentVoiceProvider.gemini: 'Gemini',
  AgentVoiceProvider.openai: 'OpenAI',
};

/// One realtime voice session: microphone audio goes in, speech, transcripts
/// and tool calls come out. [GeminiLiveSession] and [OpenAiRealtimeSession]
/// implement it; the voice controller only knows this.
///
/// The callbacks are constructor parameters of each session (they appear here
/// as getters so a caller can rely on them):
/// - [onAudio]: speech from the model, 24 kHz mono PCM16.
/// - [onInputText] / [onOutputText]: transcript chunks of what the person and
///   the model said.
/// - [onTurnComplete]: the model finished its turn.
/// - [onInterrupted]: the person spoke over the model.
/// - [onClosed]: the server ended the session.
/// - [onToolCall]: runs a tool the model called. A session sends the returned
///   map back to the model itself, intact, exactly once per call (a handler
///   that throws or is too slow is answered with an `error` map).
abstract interface class VoiceSession {
  /// Whether a connection is open.
  bool get connected;

  /// The model in use, once known (for messages only).
  String? get model;

  AgentToolHandler get onToolCall;
  void Function(Uint8List pcm24k)? get onAudio;
  void Function(String text)? get onInputText;
  void Function(String text)? get onOutputText;
  void Function()? get onTurnComplete;
  void Function()? get onInterrupted;
  void Function(String reason)? get onClosed;

  /// Opens the session; throws when it cannot be set up.
  Future<void> connect();

  /// One chunk of microphone audio: 16 kHz mono PCM16.
  void sendAudio(Uint8List pcm16k);

  /// The microphone stopped (push-to-talk released): answer now.
  void endAudio();

  /// Typed text, or a note from the app, as the person's next input.
  void sendText(String text);

  Future<void> close();
}

/// Builds the session of [provider]. [playbackPending] says how much of the
/// speech already received is still to be played (OpenAI needs it to cut the
/// unheard part off when the person interrupts).
VoiceSession createVoiceSession({
  required AgentVoiceProvider provider,
  required String apiKey,
  required String systemPrompt,
  required List<Map<String, Object?>> tools,
  required AgentToolHandler onToolCall,
  required String voice,
  void Function(Uint8List pcm24k)? onAudio,
  void Function(String text)? onInputText,
  void Function(String text)? onOutputText,
  void Function()? onTurnComplete,
  void Function()? onInterrupted,
  void Function(String reason)? onClosed,
  Future<Duration> Function()? playbackPending,
}) => switch (provider) {
  AgentVoiceProvider.gemini => GeminiLiveSession(
    apiKey: apiKey,
    voice: voice,
    systemPrompt: systemPrompt,
    tools: tools,
    onToolCall: onToolCall,
    onAudio: onAudio,
    onInputText: onInputText,
    onOutputText: onOutputText,
    onTurnComplete: onTurnComplete,
    onInterrupted: onInterrupted,
    onClosed: onClosed,
  ),
  AgentVoiceProvider.openai => OpenAiRealtimeSession(
    apiKey: apiKey,
    voice: voice,
    systemPrompt: systemPrompt,
    tools: tools,
    onToolCall: onToolCall,
    onAudio: onAudio,
    onInputText: onInputText,
    onOutputText: onOutputText,
    onTurnComplete: onTurnComplete,
    onInterrupted: onInterrupted,
    onClosed: onClosed,
    playbackPending: playbackPending,
  ),
};

/// The stored key of [provider].
AgentVoiceKey voiceKeyFor(AgentVoiceProvider provider) => switch (provider) {
  AgentVoiceProvider.gemini => AgentVoiceKey.instance,
  AgentVoiceProvider.openai => OpenAiVoiceKey.instance,
};

/// Reads a scanned code or pasted text: a Gemini key (`AIza...`) or an OpenAI
/// key (`sk-...`) is recognised wherever it sits in the text; a bare token
/// without either prefix belongs to [preferred]. Null when nothing looks like
/// a key.
({AgentVoiceProvider provider, String key})? parseScannedKey(
  String? scanned, {
  required AgentVoiceProvider preferred,
}) {
  if (scanned == null) return null;
  final openai = RegExp(r'sk-[0-9A-Za-z_\-]{20,}').firstMatch(scanned);
  final gemini = RegExp(r'AIza[0-9A-Za-z_\-]{30,}').firstMatch(scanned);
  // A key of the preferred provider wins if the text holds both.
  if (openai != null && gemini != null) {
    return preferred == AgentVoiceProvider.openai
        ? (provider: AgentVoiceProvider.openai, key: openai.group(0)!)
        : (provider: AgentVoiceProvider.gemini, key: gemini.group(0)!);
  }
  if (openai != null) {
    return (provider: AgentVoiceProvider.openai, key: openai.group(0)!);
  }
  if (gemini != null) {
    return (provider: AgentVoiceProvider.gemini, key: gemini.group(0)!);
  }
  final bare = scanned.trim();
  return RegExp(r'^[0-9A-Za-z_\-\.]{20,200}$').hasMatch(bare)
      ? (provider: preferred, key: bare)
      : null;
}

/// Stores a scanned key under the provider it belongs to; that provider, or
/// null when the text held no key.
Future<AgentVoiceProvider?> saveScannedKey(
  String? scanned, {
  required AgentVoiceProvider preferred,
}) async {
  final parsed = parseScannedKey(scanned, preferred: preferred);
  if (parsed == null) return null;
  await voiceKeyFor(parsed.provider).save(parsed.key);
  return parsed.provider;
}
