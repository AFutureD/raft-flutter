import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// The app's own voice: the device's text to speech, which says exactly the
/// text it is given (the agent layer's `say`), a sentence at a time.
abstract interface class SpeechOut {
  /// Says [sentence]. [onStart] is called when the sound begins. The future
  /// completes when it has been said, or [stop] cut it off, or it could not
  /// be said at all.
  Future<void> speak(String sentence, {void Function()? onStart});

  /// Cuts off what is being said.
  Future<void> stop();
}

/// A [SpeechOut] that can say which engine and voice it speaks with, for the
/// log line of each sentence.
abstract interface class SpeechVoiceInfo {
  /// `engine`, `voice` and `lang` of the voice, as far as the platform tells
  /// (known once the first sentence has been asked for).
  Map<String, Object?> get voiceInfo;

  /// Makes the engine ready and asks it what it is, so that [voiceInfo] is
  /// complete.
  Future<void> prepare();
}

/// The sentences of [text], in order, each with its closing punctuation (and
/// the quote that closes after it). Nothing is dropped or changed but the
/// white space around a sentence, so that the sentences said one after the
/// other are the text. A full stop counts only before a space or the end
/// ("v1.2" and "3.5" stay whole); a line break ends a sentence.
List<String> orbSentences(String text) {
  const enders = '。！？!?；;…';
  const closers = '”’」』）)"\'';
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    final s = buf.toString().trim();
    buf.clear();
    if (s.isNotEmpty) out.add(s);
  }

  final runes = text.runes.map(String.fromCharCode).toList();
  for (var i = 0; i < runes.length; i++) {
    final c = runes[i];
    if (c == '\n') {
      flush();
      continue;
    }
    buf.write(c);
    final dot =
        c == '.' && (i + 1 >= runes.length || runes[i + 1].trim().isEmpty);
    if (!enders.contains(c) && !dot) continue;
    // The rest of the stops and the quotes that close with it.
    while (i + 1 < runes.length &&
        (enders.contains(runes[i + 1]) || closers.contains(runes[i + 1]))) {
      buf.write(runes[++i]);
    }
    flush();
  }
  flush();
  return out;
}

/// Whether the platform has a text-to-speech plugin the app uses.
bool get appSpeechSupported =>
    !kIsWeb &&
    (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows);

/// [SpeechOut] on the platform's own engine (Android TextToSpeech, iOS and
/// macOS AVSpeechSynthesizer, Windows) through `flutter_tts`: on the device,
/// so the first sentence starts without a network trip. Chinese, at the
/// normal rate.
class FlutterTtsSpeech implements SpeechOut, SpeechVoiceInfo {
  FlutterTtsSpeech({this.language = 'zh-CN'});

  final String language;

  @override
  Map<String, Object?> get voiceInfo => {..._info, 'lang': language};

  @override
  Future<void> prepare() => _ready();

  // Asked of the platform once, when the engine is made.
  Map<String, Object?> _info = const {};

  FlutterTts? _tts;
  Future<FlutterTts?>? _making;
  Completer<void>? _done;
  void Function()? _started;

  Future<FlutterTts?> _ready() => _making ??= _make();

  Future<FlutterTts?> _make() async {
    try {
      final tts = FlutterTts();
      tts.setStartHandler(() => _started?.call());
      tts.setCompletionHandler(_finished);
      tts.setCancelHandler(_finished);
      tts.setErrorHandler((_) => _finished());
      await tts.setLanguage(language);
      // 0.5 is the normal rate on both Android and iOS.
      await tts.setSpeechRate(0.5);
      await tts.setVolume(1);
      await tts.setPitch(1);
      _info = await _describe(tts);
      return _tts = tts;
    } catch (_) {
      // No engine on this platform (or none installed): nothing is said.
      return null;
    }
  }

  /// The engine and default voice the platform reports, once, for the log.
  static Future<Map<String, Object?>> _describe(FlutterTts tts) async {
    final info = <String, Object?>{};
    try {
      info['engine'] = await tts.getDefaultEngine.timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {}
    try {
      final voice = await tts.getDefaultVoice.timeout(
        const Duration(seconds: 2),
      );
      info['voice'] = voice is Map ? voice['name'] ?? voice : voice;
    } catch (_) {}
    return info;
  }

  void _finished() {
    final done = _done;
    if (done != null && !done.isCompleted) done.complete();
  }

  @override
  Future<void> speak(String sentence, {void Function()? onStart}) async {
    final tts = await _ready();
    if (tts == null) return;
    final done = _done = Completer<void>();
    _started = onStart;
    try {
      await tts.speak(sentence);
      // Done by the engine's own word; a lost callback does not hold the
      // rest of the reply for ever.
      await done.future.timeout(
        Duration(milliseconds: 6000 + sentence.length * 500),
      );
    } catch (_) {
      // Cut off or failed: the next sentence goes on.
    } finally {
      if (identical(_done, done)) _done = null;
      _started = null;
    }
  }

  @override
  Future<void> stop() async {
    final tts = _tts;
    _finished();
    if (tts == null) return;
    try {
      await tts.stop();
    } catch (_) {}
  }
}

/// A [SpeechOut] that says nothing aloud and writes down what it is asked to:
/// for tests and for the evaluation, where the words are what counts. Each
/// sentence "takes" [perSentence] to say (none by default: it is over at
/// once).
class RecordingSpeech implements SpeechOut {
  RecordingSpeech({this.perSentence = Duration.zero, this.onSpoken});

  final Duration perSentence;

  /// Told each sentence as its sound would begin.
  final void Function(String sentence)? onSpoken;

  /// Every sentence asked for, in order.
  final spoken = <String>[];

  /// How often [stop] was called.
  int stops = 0;

  Completer<void>? _pending;
  Timer? _timer;

  @override
  Future<void> speak(String sentence, {void Function()? onStart}) {
    spoken.add(sentence);
    onSpoken?.call(sentence);
    onStart?.call();
    if (perSentence == Duration.zero) return Future<void>.value();
    final done = _pending = Completer<void>();
    _timer = Timer(perSentence, () {
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    _timer?.cancel();
    final done = _pending;
    if (done != null && !done.isCompleted) done.complete();
  }
}
