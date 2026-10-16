import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_audio.dart';
import 'agent_live_guard.dart';
import 'agent_summary.dart';
import 'agent_voice_settings.dart';
import 'gemini_live.dart';
import 'voice_provider.dart';

/// What the runtime needs of the model's side: to tell it something the app
/// saw, and to silence it.
abstract interface class AgentModelLink {
  /// Tells the model something the app saw (a card was pressed), outside the
  /// captions. False when there is no session to tell.
  Future<bool> tell(String note);

  /// Stops what the model is saying at once.
  void stopSpeaking();
}

/// The conversation of agent mode: captions, the mic state and the realtime
/// voice session. Push-to-talk on hold, live conversation on tap.
///
/// It reports what happens in the conversation (the person starts or stops
/// speaking, the model is interrupted, speaks, finishes); the
/// [AgentRuntime] decides what that means for the turn.
class AgentVoiceController extends ChangeNotifier implements AgentModelLink {
  AgentVoiceController({
    required this.tools,
    required this.onToolCall,
    required this.systemPrompt,
    this.beforeConnect,
    this.onSessionEnd,
    this.onUserSaid,
    this.onListening,
    this.onListeningEnded,
    this.onModelInterrupted,
    this.onModelSpoke,
    this.onModelTurnComplete,
    this.muted,
    Duration liveIdleLimit = agentLiveIdleLimit,
    AgentAudio? audio,
    AgentVoiceKey? key,
  }) : audio = audio ?? AgentAudio.instance,
       key = key ?? AgentVoiceKey.instance {
    _guard = AgentLiveGuard(
      limit: liveIdleLimit,
      onIdle: _liveIdle,
      busy: () => _toolsRunning > 0 || state == AgentMicState.speaking,
    );
    this.audio.onPlaybackIdle = _playbackIdle;
    AgentVoiceSettings.instance.addListener(_settingsChanged);
    unawaited(AgentVoiceSettings.instance.applyOutput());
    unawaited(AgentVoiceSettings.instance.applyRecordingMode());
  }

  static const tapLimit = Duration(milliseconds: 300);

  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;

  /// Built when a session starts, so it can include the latest context.
  final String Function() systemPrompt;

  /// Awaited before a session is built (e.g. the shared memory still loading).
  final Future<void> Function()? beforeConnect;

  /// The transcript of what the person said, chunk by chunk. [fresh] is true
  /// for the first chunk of a new utterance. Never called with what the
  /// agent says: this is the one stream a confirmation may be read from.
  final void Function(String text, {required bool fresh})? onUserSaid;

  /// The mic opened for the person (held, or live): a turn starts.
  final void Function()? onListening;

  /// The person let go, or live mode ended: they are done speaking.
  final void Function()? onListeningEnded;

  /// The server cut the model off because the person spoke over it.
  final void Function()? onModelInterrupted;

  /// The model began to answer (audio or words).
  final void Function()? onModelSpoke;

  /// The model finished its turn.
  final void Function()? onModelTurnComplete;

  /// True while what the model says is not wanted (the person just said 停):
  /// its audio and words are dropped.
  final bool Function()? muted;
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
    _guard.stop();
    _live = _holding = false;
    await old?.close();
    unawaited(audio.stopPlayback());
    _set(AgentMicState.idle);
  }

  void _settingsChanged() {
    // Applies from the next turn; never cut a reply or an open microphone.
    if (state == AgentMicState.idle) unawaited(restart());
  }

  /// Receives what was said in a session, and the tools that ran in it, when
  /// it ends (for memory).
  final AgentSessionEnd? onSessionEnd;
  final _log = <(AgentSpeaker, String)>[];
  final _outcomes = <AgentToolOutcome>[];

  /// The most tool outcomes kept for one session.
  static const _maxOutcomes = 80;

  void _recordOutcome(
    String name,
    Map<String, Object?> args,
    Map<String, Object?> result,
  ) {
    if (_outcomes.length >= _maxOutcomes) _outcomes.removeAt(0);
    _outcomes.add(AgentToolOutcome(name: name, args: args, result: result));
  }

  void _logAppend(AgentSpeaker speaker, String text) {
    if (_log.isNotEmpty && _log.last.$1 == speaker) {
      _log[_log.length - 1] = (speaker, _log.last.$2 + text);
    } else {
      _log.add((speaker, text));
    }
  }

  void _endSession() {
    if (_log.isEmpty) {
      _outcomes.clear();
      return;
    }
    final transcript = List.of(_log);
    final outcomes = List.of(_outcomes);
    _log.clear();
    _outcomes.clear();
    onSessionEnd?.call(transcript, outcomes);
  }

  /// What the agent has said so far in its current reply (from the live
  /// transcript), for visuals that wait for their words.
  final saying = ValueNotifier<String>('');

  final lines = <(AgentSpeaker, String)>[];
  AgentMicState state = AgentMicState.idle;
  String? notice;

  late final AgentLiveGuard _guard;
  int _toolsRunning = 0;

  VoiceSession? _session;
  Future<VoiceSession?>? _connecting;
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
  Future<bool> get hasKey async => (await _activeKey()) != null;

  /// The key of the voice service chosen in the settings.
  Future<String?> _activeKey() =>
      switch (AgentVoiceSettings.instance.provider) {
        AgentVoiceProvider.gemini => key.read(),
        AgentVoiceProvider.openai => OpenAiVoiceKey.instance.read(),
        AgentVoiceProvider.grok => GrokVoiceKey.instance.read(),
      };

  Future<VoiceSession?> _ensureSession() {
    if (_session?.connected ?? false) return Future.value(_session);
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<VoiceSession?> _connect() async {
    await beforeConnect?.call();
    final settings = AgentVoiceSettings.instance;
    final provider = settings.provider;
    final apiKey = await _activeKey();
    if (apiKey == null) {
      _set(
        AgentMicState.idle,
        note: '还没有 ${agentVoiceProviderLabels[provider]} Key：点右上角扫码填入',
      );
      return null;
    }
    final session = createVoiceSession(
      provider: provider,
      apiKey: apiKey,
      voice: settings.voiceOf(provider),
      reasoning: settings.reasoning,
      playbackPending: audio.pending,
      systemPrompt: systemPrompt(),
      tools: tools,
      onToolCall: (name, args) async {
        // A screen operation while the agent is talking (non-blocking) must
        // not turn "speaking" into "thinking".
        if (!_live && !_holding && state != AgentMicState.speaking) {
          _set(AgentMicState.thinking);
        }
        _toolsRunning++;
        _guard.touch();
        try {
          final result = await onToolCall(name, args);
          _recordOutcome(name, args, result);
          return result;
        } catch (_) {
          _recordOutcome(name, args, {'error': '工具出错'});
          rethrow;
        } finally {
          _toolsRunning--;
          _guard.touch();
        }
      },
      onAudio: (pcm) {
        _guard.touch();
        onModelSpoke?.call();
        if (muted?.call() ?? false) return;
        if (!audio.supported) return;
        unawaited(audio.play(pcm));
        if (!_live && !_holding && state != AgentMicState.speaking) {
          _set(AgentMicState.speaking);
        }
      },
      onInputText: (text) {
        _guard.touch();
        onUserSaid?.call(text, fresh: _youLine == null);
        // The person speaking starts a new reply.
        if (saying.value.isNotEmpty) saying.value = '';
        _logAppend(AgentSpeaker.you, text);
        _append(AgentSpeaker.you, text);
      },
      onOutputText: (text) {
        _guard.touch();
        onModelSpoke?.call();
        if (muted?.call() ?? false) return;
        saying.value += text;
        _logAppend(AgentSpeaker.agent, text);
        _append(AgentSpeaker.agent, text);
      },
      onTurnComplete: () {
        _guard.touch();
        _youLine = _agentLine = null;
        if (state == AgentMicState.thinking) _set(AgentMicState.idle);
        onModelTurnComplete?.call();
      },
      onInterrupted: () {
        _agentLine = null;
        unawaited(audio.stopPlayback());
        onModelInterrupted?.call();
      },
      onClosed: (reason) {
        _endSession();
        _session = null;
        _stopMic();
        _guard.stop();
        _live = _holding = false;
        _set(AgentMicState.idle, note: '语音连接断开：$reason');
      },
    );
    try {
      await session.connect();
    } catch (e) {
      final model = session.model;
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
        _guard.stop();
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
    if (_live) _guard.start();
    _pending.clear();
    _startMic();
    onListening?.call();
    _set(
      _session?.connected ?? false
          ? AgentMicState.holding
          : AgentMicState.connecting,
    );
    final session = await _ensureSession();
    if (session == null) {
      _stopMic();
      _guard.stop();
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
      onListeningEnded?.call();
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
      _guard.start();
      _set(AgentMicState.live);
      return;
    }
    _stopMic();
    _session?.endAudio();
    onListeningEnded?.call();
    _set(
      _session?.connected ?? false
          ? AgentMicState.thinking
          : AgentMicState.connecting,
    );
  }

  /// Nobody spoke for [agentLiveIdleLimit]: the microphone stops (the model
  /// is told the audio ended) and the person is told why.
  void _liveIdle() {
    if (!_live || _disposed) return;
    _live = false;
    _stopMic();
    _session?.endAudio();
    onListeningEnded?.call();
    _set(AgentMicState.idle, note: agentLiveIdleNotice);
  }

  void stopLive() {
    _guard.stop();
    _live = false;
    _stopMic();
    _session?.endAudio();
    onListeningEnded?.call();
    _set(AgentMicState.idle);
  }

  @override
  void stopSpeaking() {
    _agentLine = null;
    saying.value = '';
    unawaited(audio.stopPlayback());
    if (state == AgentMicState.speaking || state == AgentMicState.thinking) {
      _set(_live ? AgentMicState.live : AgentMicState.idle);
    }
  }

  /// Sends typed text to the voice session; false when there is no key.
  /// [context] (what is on screen, the card just tapped) goes to the model
  /// in front of the words, not into the captions.
  Future<bool> sendText(String text, {String? context}) async {
    if (!await hasKey) return false;
    say(AgentSpeaker.you, text);
    saying.value = '';
    _logAppend(AgentSpeaker.you, text);
    _set(AgentMicState.thinking);
    final session = await _ensureSession();
    if (session == null) return true;
    session.sendText(
      context == null || context.isEmpty ? text : '$context\n$text',
    );
    return true;
  }

  /// Tells the model something the app saw (a card was pressed), outside the
  /// captions. It is the app speaking, not the person: it never counts as
  /// their words. False when there is no session to tell.
  @override
  Future<bool> tell(String note) async {
    if (_disposed || !await hasKey) return false;
    final session = await _ensureSession();
    if (session == null) return false;
    session.sendText(note);
    return true;
  }

  void _playbackIdle() {
    if (state == AgentMicState.speaking) _set(AgentMicState.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _guard.stop();
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
