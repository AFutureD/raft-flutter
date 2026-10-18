import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Where the voice diagnostics go: one line each, to `adb logcat` (tag
/// `flutter`). Printed in debug and profile builds (the orb is hidden in true
/// release builds), so never gated by `kDebugMode`. Never pass a key or a
/// token to it.
typedef VoiceLog = void Function(String line);

/// The default [VoiceLog]: prints in debug and profile builds.
void printVoiceLog(String line) {
  if (!kReleaseMode) debugPrint(line);
}

/// The most characters of a person's or the voice's words in one log line.
const voiceLogClip = 120;

/// [text] on one line, cut at [max] characters (with the full length).
String clipForLog(String text, [int max = voiceLogClip]) {
  final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final chars = one.runes.toList();
  if (chars.length <= max) return one;
  return '${String.fromCharCodes(chars.take(max))}…(${chars.length})';
}

/// `voice-turn <event> k=v k="a value with spaces"`; null values are left
/// out, and a text value is clipped to [voiceLogClip].
String voiceTurnLine(String event, Map<String, Object?> fields) {
  final b = StringBuffer('voice-turn $event');
  fields.forEach((k, v) {
    if (v == null) return;
    var s = v is String ? clipForLog(v) : '$v';
    if (s.isEmpty || RegExp(r'[\s"=]').hasMatch(s)) s = jsonEncode(s);
    b.write(' $k=$s');
  });
  return b.toString();
}
