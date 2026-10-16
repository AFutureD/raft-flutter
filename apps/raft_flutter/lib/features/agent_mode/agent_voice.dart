import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_audio.dart';
import 'agent_voice_settings.dart';
import 'gemini_live.dart';

/// The conversation of agent mode: captions, the mic state and the realtime
/// voice session. Push-to-talk on hold, live conversation on tap.
class AgentVoiceController extends ChangeNotifier {
  AgentVoiceController({
    required this.tools,
    required this.onToolCall,
    required this.systemPrompt,
    this.beforeConnect,
    this.onSessionEnd,
    AgentAudio? audio,
    AgentVoiceKey? key,
  }) : audio = audio ?? AgentAudio.instance,
       key = key ?? AgentVoiceKey.instance {
    this.audio.onPlaybackIdle = _playbackIdle;
    AgentVoiceSettings.instance.addListener(_settingsChanged);
    unawaited(AgentVoiceSettings.instance.applyOutput());
  }

  static const tapLimit = Duration(milliseconds: 300);

  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;

  /// Built when a session starts, so it can include the latest context.
  final String Function() systemPrompt;

  /// Awaited before a session is built (e.g. the shared memory still loading).
  final Future<void> Function()? beforeConnect;
  final AgentAudio audio;
  final AgentVoiceKey key;

  /// Plays a short greeting in [voice] so it can be heard at once; the
  /// voice is already saved in [AgentVoiceSettings].
  Future<void> preview(String voice) async {
    await restart();
    if (!await hasKey) return;
    _set(AgentMicState.thinking);
    final session = await _ensureSession();
    session?.sendText('（用户正在试听你的声音。用一句自然、简短的话跟他打个招呼。）');
  }

  /// Ends the current session so the next one picks up changed settings.
  Future<void> restart() async {
    _endSession();
    final old = _session;
    _session = null;
    _stopMic();
    _live = _holding = false;
    await old?.close();
    unawaited(audio.stopPlayback());
    _set(AgentMicState.idle);
  }

  void _settingsChanged() {
    // Applies from the next turn; never cut a reply or an open microphone.
    if (state == AgentMicState.idle) unawaited(restart());
  }

  /// Receives what was said in a session when it ends (for memory).
  final void Function(List<(AgentSpeaker, String)> transcript)? onSessionEnd;
  final _log = <(AgentSpeaker, String)>[];

  void _logAppend(AgentSpeaker speaker, String text) {
    if (_log.isNotEmpty && _log.last.$1 == speaker) {
      _log[_log.length - 1] = (speaker, _log.last.$2 + text);
    } else {
      _log.add((speaker, text));
    }
  }

  void _endSession() {
    if (_log.isEmpty) return;
    final transcript = List.of(_log);
    _log.clear();
    onSessionEnd?.call(transcript);
  }

  /// What the agent has said so far in its current reply (from the live
  /// transcript), for visuals that wait for their words.
  final saying = ValueNotifier<String>('');

  final lines = <(AgentSpeaker, String)>[];
  AgentMicState state = AgentMicState.idle;
  String? notice;

  GeminiLiveSession? _session;
  Future<GeminiLiveSession?>? _connecting;
  StreamSubscription<Uint8List>? _mic;
  final _pending = <Uint8List>[];
  bool _live = false;
  bool _holding = false;
  bool _disposed = false;

  /// The finger is on the button; [_releasedAsTap] records a release that
  /// came while [micDown] was still waiting for the permission check.
  bool _pressed = false;
  bool? _releasedAsTap;
  int? _youLine;
  int? _agentLine;

  bool get live => _live;

  void _set(AgentMicState next, {String? note}) {
    state = next;
    notice = note;
    if (!_disposed) notifyListeners();
  }

  /// A line from the app itself (local summaries, errors).
  void say(AgentSpeaker speaker, String text) {
    _youLine = _agentLine = null;
    lines.add((speaker, text));
    _trim();
    if (!_disposed) notifyListeners();
  }

  void _trim() {
    if (lines.length <= 20) return;
    final drop = lines.length - 20;
    lines.removeRange(0, drop);
    if (_youLine != null) _youLine = _youLine! - drop;
    if (_agentLine != null) _agentLine = _agentLine! - drop;
  }

  void _append(AgentSpeaker speaker, String text) {
    final isYou = speaker == AgentSpeaker.you;
    final index = isYou ? _youLine : _agentLine;
    if (index != null && index >= 0 && index < lines.length) {
      lines[index] = (speaker, lines[index].$2 + text);
    } else {
      lines.add((speaker, text.trimLeft()));
      _trim();
      if (isYou) {
        _youLine = lines.length - 1;
      } else {
        _agentLine = lines.length - 1;
      }
    }
    // A new speaker closes the other side's line.
    if (isYou) {
      _agentLine = null;
    } else {
      _youLine = null;
    }
    if (!_disposed) notifyListeners();
  }

  /// Whether a voice key exists; text falls back to local intents without.
  Future<bool> get hasKey async => (await key.read()) != null;

  Future<GeminiLiveSession?> _ensureSession() {
    if (_session?.connected ?? false) return Future.value(_session);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<GeminiLiveSession?> _connect() async {
    await beforeConnect?.call();
    final apiKey = await key.read();
    if (apiKey == null) {
      _set(AgentMicState.idle, note: '还没有 Gemini Key：点右上角扫码填入');
      return null;
    }
    final session = GeminiLiveSession(
      apiKey: apiKey,
      voice: AgentVoiceSettings.instance.voice,
      systemPrompt: systemPrompt(),
      tools: tools,
      onToolCall: (name, args) async {
        // A screen operation while the agent is talking (non-blocking) must
        // not turn "speaking" into "thinking".
        if (!_live && !_holding && state != AgentMicState.speaking) {
          _set(AgentMicState.thinking);
        }
        return onToolCall(name, args);
      },
      onAudio: (pcm) {
        if (!audio.supported) return;
        unawaited(audio.play(pcm));
        if (!_live && !_holding && state != AgentMicState.speaking) {
          _set(AgentMicState.speaking);
        }
      },
      onInputText: (text) {
        // The person speaking starts a new reply.
        if (saying.value.isNotEmpty) saying.value = '';
        _logAppend(AgentSpeaker.you, text);
        _append(AgentSpeaker.you, text);
      },
      onOutputText: (text) {
        saying.value += text;
        _logAppend(AgentSpeaker.agent, text);
        _append(AgentSpeaker.agent, text);
      },
      onTurnComplete: () {
        _youLine = _agentLine = null;
        if (state == AgentMicState.thinking) _set(AgentMicState.idle);
      },
      onInterrupted: () {
        _agentLine = null;
        unawaited(audio.stopPlayback());
      },
      onClosed: (reason) {
        _endSession();
        _session = null;
        _stopMic();
        _live = _holding = false;
        _set(AgentMicState.idle, note: '语音连接断开：$reason');
      },
    );
    try {
      await session.connect();
    } catch (e) {
      final model = GeminiLiveSession.pickedModel;
      _set(
        AgentMicState.idle,
        note: '连接失败${model == null ? '' : '（${model.split('/').last}）'}：$e',
      );
      return null;
    }
    if (_disposed) {
      await session.close();
      return null;
    }
    _session = session;
    return session;
  }

  void _startMic() {
    _mic ??= audio.microphone().listen(
      (chunk) {
        final s = _session;
        if (s != null && s.connected) {
          s.sendAudio(chunk);
        } else if (_pending.length < 80) {
          _pending.add(chunk);
        }
      },
      onError: (Object e) {
        _stopMic();
        _live = _holding = false;
        _set(AgentMicState.idle, note: '麦克风不可用：$e');
      },
    );
  }

  void _stopMic() {
    unawaited(_mic?.cancel());
    _mic = null;
  }

  Future<void> micDown() async {
    if (_live) return; // Ending live is decided on release.
    _pressed = true;
    _releasedAsTap = null;
    if (!audio.supported) {
      _set(AgentMicState.idle, note: '这台设备还不支持语音，先点左边的键盘');
      return;
    }
    if (!await audio.requestPermission()) {
      _set(AgentMicState.idle, note: '需要麦克风权限');
      return;
    }
    final early = _releasedAsTap;
    if (!_pressed && early != true) return; // Released during a prompt.
    unawaited(audio.stopPlayback());
    _holding = _pressed;
    _live = early == true;
    _pending.clear();
    _startMic();
    _set(
      _session?.connected ?? false
          ? AgentMicState.holding
          : AgentMicState.connecting,
    );
    final session = await _ensureSession();
    if (session == null) {
      _stopMic();
      _holding = false;
      return;
    }
    for (final chunk in _pending) {
      session.sendAudio(chunk);
    }
    _pending.clear();
    if (_holding) {
      _set(AgentMicState.holding);
    } else if (_live) {
      _set(AgentMicState.live);
    } else {
      // Released while connecting: the buffered speech is the whole turn.
      session.endAudio();
      _set(AgentMicState.thinking);
    }
  }

  void micUp(Duration held) {
    final wasPressed = _pressed;
    _pressed = false;
    if (wasPressed && !_holding && !_live) {
      _releasedAsTap = held < tapLimit;
      return;
    }
    if (_live) {
      if (held < tapLimit) stopLive();
      return;
    }
    if (!_holding) return;
    _holding = false;
    if (held < tapLimit) {
      _live = true;
      _set(AgentMicState.live);
      return;
    }
    _stopMic();
    _session?.endAudio();
    _set(
      _session?.connected ?? false
          ? AgentMicState.thinking
          : AgentMicState.connecting,
    );
  }

  void stopLive() {
    _live = false;
    _stopMic();
    _session?.endAudio();
    _set(AgentMicState.idle);
  }

  /// Sends typed text to the voice session; false when there is no key.
  Future<bool> sendText(String text) async {
    if (!await hasKey) return false;
    say(AgentSpeaker.you, text);
    saying.value = '';
    _logAppend(AgentSpeaker.you, text);
    _set(AgentMicState.thinking);
    final session = await _ensureSession();
    if (session == null) return true;
    session.sendText(text);
    return true;
  }

  void _playbackIdle() {
    if (state == AgentMicState.speaking) _set(AgentMicState.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _endSession();
    saying.dispose();
    AgentVoiceSettings.instance.removeListener(_settingsChanged);
    _stopMic();
    unawaited(_session?.close());
    _session = null;
    if (audio.onPlaybackIdle == _playbackIdle) audio.onPlaybackIdle = null;
    unawaited(audio.release());
    super.dispose();
  }
}
