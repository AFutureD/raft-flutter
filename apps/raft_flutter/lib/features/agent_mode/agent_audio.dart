import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Microphone and speaker for agent mode: 16 kHz PCM16 chunks from the
/// microphone, 24 kHz PCM16 speech to the speaker. Android only for the demo.
class AgentAudio {
  AgentAudio._() {
    _methods.setMethodCallHandler((call) async {
      if (call.method == 'playbackIdle') onPlaybackIdle?.call();
    });
  }
  static final instance = AgentAudio._();

  /// A subclass for tests: no platform channel is touched.
  @visibleForTesting
  AgentAudio.forTesting();

  static const _methods = MethodChannel('app.raft/agent-audio');
  static const _mic = EventChannel('app.raft/agent-audio/mic');

  bool get supported => !kIsWeb && Platform.isAndroid;

  /// Called when queued speech has finished playing.
  VoidCallback? onPlaybackIdle;

  Future<bool> requestPermission() async =>
      supported && (await _methods.invokeMethod<bool>('permission') ?? false);

  /// Starts the microphone on listen and stops it on cancel.
  Stream<Uint8List> microphone() =>
      _mic.receiveBroadcastStream().map((e) => e as Uint8List);

  Future<void> play(Uint8List pcm) => _methods.invokeMethod('play', pcm);

  /// How long until the speech already received has been heard; visuals
  /// that belong after it wait this long.
  Future<Duration> pending() async {
    if (!supported) return Duration.zero;
    try {
      final ms = await _methods.invokeMethod<int>('pendingMs') ?? 0;
      return Duration(milliseconds: ms);
    } catch (_) {
      return Duration.zero;
    }
  }

  Future<void> stopPlayback() async {
    if (supported) await _methods.invokeMethod('stopPlayback');
  }

  Future<void> release() async {
    if (supported) await _methods.invokeMethod('release');
  }

  /// Opens the system QR scanner; null when cancelled.
  Future<String?> scanCode() => _methods.invokeMethod<String>('scanCode');
}

/// The Gemini API key for the demo, kept in the platform secure storage.
class AgentVoiceKey extends ChangeNotifier {
  AgentVoiceKey._([this._storageKey = 'raft.agentDemo.geminiKey']);
  static final instance = AgentVoiceKey._();

  /// A key that is already read, for tests.
  @visibleForTesting
  AgentVoiceKey.forTesting(String? key)
    : _storageKey = 'test',
      _key = key,
      _loaded = true;
  final String _storageKey;

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  String? _key;
  bool _loaded = false;

  Future<String?> read() async {
    if (_loaded) return _key;
    try {
      _key = await _storage.read(key: _storageKey);
    } catch (_) {
      _key = null;
    }
    _loaded = true;
    notifyListeners();
    return _key;
  }

  /// The key if it has been read (or saved) already; null before that.
  String? get loaded => _key;

  /// Last four characters, for display only.
  String? get suffix {
    final k = _key;
    if (k == null || k.length < 4) return null;
    return k.substring(k.length - 4);
  }

  /// Accepts a bare key or text containing one (e.g. `GEMINI_API_KEY=...`).
  static String? parse(String? scanned) {
    if (scanned == null) return null;
    final match = RegExp(r'AIza[0-9A-Za-z_\-]{30,}').firstMatch(scanned);
    if (match != null) return match.group(0);
    final bare = scanned.trim();
    return RegExp(r'^[0-9A-Za-z_\-\.]{20,200}$').hasMatch(bare) ? bare : null;
  }

  Future<void> save(String key) async {
    await _storage.write(key: _storageKey, value: key);
    _key = key;
    _loaded = true;
    notifyListeners();
  }

  Future<void> clear() async {
    await _storage.delete(key: _storageKey);
    _key = null;
    notifyListeners();
  }
}

/// The OpenAI API key for the Realtime voice, stored like the Gemini key.
class OpenAiVoiceKey extends AgentVoiceKey {
  OpenAiVoiceKey._() : super._('raft.agentDemo.openaiKey');
  static final instance = OpenAiVoiceKey._();
}

/// The xAI API key for Grok Voice, stored like the others.
class GrokVoiceKey extends AgentVoiceKey {
  GrokVoiceKey._() : super._('raft.agentDemo.grokKey');
  static final instance = GrokVoiceKey._();
}
