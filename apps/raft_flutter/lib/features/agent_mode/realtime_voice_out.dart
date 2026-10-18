import 'dart:async';

import 'agent_language.dart';
import 'app_speech.dart';
import 'voice_layer_text.dart' show layeredForVoice;
import 'voice_provider.dart';

/// One thing a realtime voice session was asked to say: a sentence of the
/// app's, or a short lead-in the voice phrases itself.
class SpeechHandle {
  SpeechHandle({
    required this.text,
    this.onStart,
    this.onTranscript,
    required this.onCancel,
  });

  /// What was asked to be said (the sentence; for a lead-in, what the person
  /// asked).
  final String text;

  /// Called when the sound begins (the first audio of the response).
  final void Function()? onStart;

  /// Called with each piece of what the voice says, as the service
  /// transcribes it.
  final void Function(String piece)? onTranscript;

  /// How the session takes the handle back.
  final void Function(SpeechHandle) onCancel;
  final _done = Completer<void>();
  final _transcript = StringBuffer();
  bool _started = false;
  bool _cancelled = false;
  bool _failed = false;

  /// Completes when the voice has said it (and nearly all of it has played),
  /// or it was cut off, or it could not be said.
  Future<void> get done => _done.future;

  bool get started => _started;
  bool get cancelled => _cancelled;
  bool get failed => _failed;
  bool get finished => _done.isCompleted;

  /// What the voice said, as the service transcribed it so far.
  String get transcript => '$_transcript';

  /// Cuts it off, or takes it back before it is heard.
  void cancel() => onCancel(this);

  // ---- for the session that says it ----

  void markStarted() {
    if (_started) return;
    _started = true;
    onStart?.call();
  }

  void addTranscript(String piece) {
    _transcript.write(piece);
    onTranscript?.call(piece);
  }

  void markCancelled() => _cancelled = true;
  void markFailed() => _failed = true;

  void complete() {
    if (!_done.isCompleted) _done.complete();
  }
}

/// A realtime voice session that says what the app hands it, and nothing of
/// its own: the voice of the layered brain when it is OpenAI Realtime or Grok
/// Voice ([OpenAiRealtimeSession] with `relay: true`).
abstract interface class RealtimeVoiceOut {
  /// Whether the voice says [say]'s text exactly (a text-to-speech event) or
  /// only is told to repeat it (a model could drop or change a word).
  bool get speaksExactly;

  /// Has the voice say [text] as it is. Lines are said one after the other.
  SpeechHandle say(
    String text, {
    void Function()? onStart,
    void Function(String piece)? onTranscript,
  });

  /// Whether the sound of [text] is kept: saying it is instant.
  bool hasClip(String text);

  /// Has the voice say each of [phrases] once in the background and keep the
  /// sound, so that [say] of the same text is instant afterwards.
  Future<void> prewarm(Iterable<String> phrases);

  /// Has the voice phrase and say one short lead-in for what the person just
  /// asked ([request]), in its own words, while the agent works. [avoid] are
  /// the lead-ins already used; [after] is the acknowledgment already said
  /// (the lead-in goes on from it). It is phrased in [language] (the
  /// language of the turn); null is the session's own.
  SpeechHandle lead(
    String request, {
    List<String> avoid,
    String? after,
    AgentLanguage? language,
    void Function()? onStart,
    void Function(String piece)? onTranscript,
  });

  /// Stops what is being said and drops what is queued.
  void cancelSpeech();

  /// Completes when everything said so far has been played.
  Future<void> drained();
}

/// [SpeechOut] on a realtime voice: the same interface the app's own voice
/// has, so that the acknowledgment, the lead-in and the agent's answer are
/// queued, cut and logged the same way whichever voice says them.
class RealtimeSpeech implements SpeechOut, SpeechVoiceInfo {
  RealtimeSpeech(
    this.out, {
    required this.provider,
    required this.voice,
    required this.language,
  });

  final RealtimeVoiceOut out;
  final AgentVoiceProvider provider;
  final String voice;
  final AgentLanguage language;

  /// What the last [speak] was transcribed as (for checking a model's
  /// reading against the words it was given).
  String get lastTranscript => _last?.transcript ?? '';
  SpeechHandle? _last;

  /// Whether what is said is the text exactly, or the model's reading of it.
  bool get exact => out.speaksExactly;

  @override
  Map<String, Object?> get voiceInfo => {
    'engine': provider.name,
    'voice': voice,
    'lang': language.ttsCode,
  };

  @override
  Future<void> prepare() async {}

  @override
  Future<void> speak(String sentence, {void Function()? onStart}) {
    // A number written "#136" reads "136": the same to the ear, and the voice
    // does not stumble on the sign.
    final handle = _last = out.say(layeredForVoice(sentence), onStart: onStart);
    return handle.done;
  }

  /// A lead-in the voice phrases from [request], in [language] (the turn's;
  /// null is the session's); the caller keeps the handle
  /// to see whether it has begun and to take it back.
  SpeechHandle lead(
    String request, {
    List<String> avoid = const [],
    String? after,
    AgentLanguage? language,
    void Function()? onStart,
    void Function(String piece)? onTranscript,
  }) => out.lead(
    layeredForVoice(request),
    avoid: avoid,
    after: after,
    language: language,
    onStart: onStart,
    onTranscript: onTranscript,
  );

  /// Completes when the speech has played to its end.
  Future<void> drained() => out.drained();

  /// Whether [text] is said instantly (its sound is kept).
  bool hasClip(String text) => out.hasClip(text);

  /// Keeps the sound of [phrases] (in the background).
  Future<void> prewarm(Iterable<String> phrases) => out.prewarm(phrases);

  @override
  Future<void> stop() async => out.cancelSpeech();
}
