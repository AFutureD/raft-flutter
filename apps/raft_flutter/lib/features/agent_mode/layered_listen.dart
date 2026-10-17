import 'dart:async';

/// What the person said, as one turn: the app's own end-of-turn rule for the
/// voice layer's listening side.
///
/// The Live model hears and transcribes (its voice activity detection decides
/// when the person has stopped); it is not trusted to pass the words on. The
/// transcript chunks come here, and when the person's turn is over the whole
/// text goes to [forward] exactly as it was transcribed.
///
/// The earliest sign of the end of a turn the Live API gives is the model
/// starting to generate (a word, a sound, the end of its generation, a call)
/// after input was heard, and failing that `turnComplete`; with none of them,
/// [staleAfter] of silence in the transcript. [settle] waits a moment after
/// the sign for transcript chunks still on the way.
///
/// The speaker's own voice comes back through the microphone and is
/// transcribed too. While [guarding] (it is being said, or has just been), an
/// utterance that is mostly the words just said ([echoOf]) is dropped, and
/// one that is not is the person speaking over it: [onBargeIn].
class UserTurnForwarder {
  UserTurnForwarder({
    required this.forward,
    this.onChunk,
    this.onBargeIn,
    this.guarding,
    this.echoOf,
    this.settle = const Duration(milliseconds: 80),
    this.staleAfter = const Duration(seconds: 2),
  });

  /// The person's whole turn.
  final void Function(String text) forward;

  /// Each transcript chunk of the person's own words (never the echo).
  final void Function(String text)? onChunk;

  /// The person started to speak: once per utterance, as soon as it is known
  /// not to be the echo of the voice.
  final void Function()? onBargeIn;

  /// Whether the app's voice is, or just was, sounding.
  final bool Function()? guarding;

  /// Whether what the microphone heard is (mostly) what the voice said.
  final bool Function(String text)? echoOf;
  final Duration settle;
  final Duration staleAfter;

  final _text = StringBuffer();
  bool _decided = false;
  bool _echo = false;
  Timer? _settle;
  Timer? _stale;

  /// The most characters of an utterance the echo test waits for before it
  /// decides.
  static const _decideAt = 4;

  /// Letters and digits of [text], lower case: what two transcripts of the
  /// same words agree on.
  static String compact(String text) => text
      .replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '')
      .toLowerCase();

  /// Whether anything of [text] could be said: not just marks.
  static bool hasWords(String text) => compact(text).isNotEmpty;

  /// A chunk of the transcript of what the person says.
  void heard(String chunk) {
    if (chunk.isEmpty) return;
    // A chunk while the end of the turn is being waited for: wait again.
    final settling = _settle?.isActive ?? false;
    _settle?.cancel();
    _text.write(chunk);
    if (settling) _settle = Timer(settle, flush);
    _stale?.cancel();
    _stale = Timer(staleAfter, flush);
    if (_decided) {
      if (!_echo) onChunk?.call(chunk);
      return;
    }
    final c = compact('$_text');
    if (guarding?.call() ?? false) {
      if (c.length >= _decideAt) _decide(echoOf?.call(c) ?? false);
    } else {
      _decide(false);
    }
  }

  void _decide(bool echo) {
    _decided = true;
    _echo = echo;
    if (echo) return;
    onBargeIn?.call();
    onChunk?.call('$_text');
  }

  /// The model began to generate, or finished its turn: the person's turn is
  /// over when there are words.
  void modelActed() {
    if (_text.isEmpty) return;
    _settle?.cancel();
    _settle = Timer(settle, flush);
  }

  /// Ends the person's turn now: what was heard is forwarded.
  void flush() {
    _settle?.cancel();
    _stale?.cancel();
    final text = '$_text'.trim();
    final echo = _decided
        ? _echo
        : (guarding?.call() ?? false) && (echoOf?.call(compact(text)) ?? false);
    final decided = _decided;
    _text.clear();
    _decided = false;
    _echo = false;
    if (text.isEmpty || echo || !hasWords(text)) return;
    if (!decided) {
      onBargeIn?.call();
      onChunk?.call(text);
    }
    forward(text);
  }

  /// Drops what was heard (the session ends).
  void dispose() {
    _settle?.cancel();
    _stale?.cancel();
    _text.clear();
  }
}
