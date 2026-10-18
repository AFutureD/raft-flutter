import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'agent_audio.dart';
import 'agent_live_guard.dart';
import 'agent_steering.dart';
import 'agent_summary.dart';
import 'agent_voice_settings.dart';
import 'gemini_live.dart';
import 'layered_voice.dart' show LayeredVoiceSession;
import 'voice_provider.dart';
import 'voice_turn_log.dart';

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
    this.steering,
    this.provider,
    this.slowCue = platformSlowCue,
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
    VoiceSessionFactory? sessionFactory,
    this.fastPath,
    VoiceLog? log,
  }) : _voiceLog = log ?? printVoiceLog,
       sessionFactory = sessionFactory ?? createVoiceSession,
       audio = audio ?? AgentAudio.instance,
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

  /// Where the `voice-turn` lines go.
  final VoiceLog _voiceLog;

  /// The command the app did without the model in the turn just asked, if
  /// any (told to a layered voice for its `ask` log line).
  final String? Function()? fastPath;

  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;

  /// Built when a session starts, so it can include the latest context.
  final String Function() systemPrompt;

  /// Awaited before a session is built (e.g. the shared memory still loading).
  final Future<void> Function()? beforeConnect;

  /// How the app steers a text agent session (the realtime ones ignore it).
  final AgentSteering? steering;

  /// The voice service to use whatever the settings say (the layered voice
  /// needs Gemini); null: the one in the settings.
  final AgentVoiceProvider? provider;

  /// The cue the person gets when the agent behind a layered voice is slow:
  /// the voice model says nothing while it waits, so the app does.
  final void Function() slowCue;

  /// A silent tap and the system click: no speech, nothing to load.
  static void platformSlowCue() {
    unawaited(HapticFeedback.lightImpact());
    unawaited(SystemSound.play(SystemSoundType.click));
  }

  /// The layered voice has asked its agent and waits for the answer.
  bool get asking => _asking;
  bool _asking = false;

  void _askingIs(bool now) {
    if (_asking == now) return;
    _asking = now;
    if (!_disposed) notifyListeners();
  }

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

  /// Builds the realtime session; [createVoiceSession] unless a test says so.
  final VoiceSessionFactory sessionFactory;

  /// Plays a short greeting in [voice] so it can be heard at once; the
  /// voice is already saved in [AgentVoiceSettings].
  Future<void> preview(String voice) async {
    await restart();
    if (!await hasKey) return;
    _set(AgentMicState.thinking);
    final session = await _ensureSession();
    session?.sendText('（用户正在试听你的声音。用一句自然、简短的话跟他打个招呼。）');
  }

  /// Ends the current session at once: capture stops, speech is cut, the
  /// provider session is closed (also one still connecting: it is closed as
  /// soon as it exists and never revived), and the mic is idle. This is what a
  /// tap on the mic does while a call is connecting, listening or speaking.
  /// It also lets the next session pick up changed settings.
  Future<void> restart() async {
    _epoch++;
    _callHold?.cancel();
    _callHold = null;
    _callPress = _callHoldFired = false;
    final wasListening = _live || _holding;
    _endSession();
    final old = _session;
    final building = _building;
    _session = _building = _connecting = null;
    _stopMic();
    _guard.stop();
    _pending.clear();
    _live = _holding = _pressed = false;
    _releasedAsTap = null;
    _youLine = _agentLine = null;
    saying.value = '';
    _cutVoice(old);
    if (wasListening) onListeningEnded?.call();
    _set(AgentMicState.idle);
    await Future.wait([
      ?old?.close(),
      if (building != null && !identical(building, old)) building.close(),
    ]);
  }

  /// Stops the voice now: the model's audio, or the app's own voice.
  void _cutVoice(VoiceSession? session) {
    unawaited(audio.stopPlayback());
    if (session is LayeredVoiceSession) session.stopSpeech();
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

  /// How loud the person is right now, 0..1, from the microphone's chunks
  /// (0 when the microphone is off). The orb's rings follow it.
  final micLevel = ValueNotifier<double>(0);

  final lines = <(AgentSpeaker, String)>[];
  AgentMicState state = AgentMicState.idle;
  // ignore: raft_lints/avoid_imperative_notice_state -- Replaced by every state change (_set) and cleared with the next successful one; shown only in the dock.
  String? notice;

  late final AgentLiveGuard _guard;
  int _toolsRunning = 0;

  VoiceSession? _session;
  Future<VoiceSession?>? _connecting;

  /// The session being connected, so a hang up can close it at once.
  VoiceSession? _building;

  /// Bumped by every hang up: what was started before it must not go on.
  int _epoch = 0;

  /// A press that began while a call was on (connecting, live, or the model
  /// speaking): a tap hangs up; a hold while the model speaks interrupts it
  /// (see [_callHold]).
  bool _callPress = false;
  bool _callHoldFired = false;
  Timer? _callHold;
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
      switch (provider ?? AgentVoiceSettings.instance.provider) {
        AgentVoiceProvider.gemini => key.read(),
        AgentVoiceProvider.openai => OpenAiVoiceKey.instance.read(),
        AgentVoiceProvider.grok => GrokVoiceKey.instance.read(),
      };

  Future<VoiceSession?> _ensureSession() {
    if (_session?.connected ?? false) return Future.value(_session);
    final existing = _connecting;
    if (existing != null) return existing;
    late final Future<VoiceSession?> next;
    next = _connect().whenComplete(() {
      if (identical(_connecting, next)) _connecting = null;
    });
    return _connecting = next;
  }

  Future<VoiceSession?> _connect() async {
    final epoch = _epoch;
    await beforeConnect?.call();
    if (epoch != _epoch || _disposed) return null;
    final settings = AgentVoiceSettings.instance;
    final provider = this.provider ?? settings.provider;
    final apiKey = await _activeKey();
    if (epoch != _epoch || _disposed) return null;
    if (apiKey == null) {
      _set(
        AgentMicState.idle,
        note: '还没有 ${agentVoiceProviderLabels[provider]} Key：点右上角扫码填入',
      );
      return null;
    }
    final session = sessionFactory(
      provider: provider,
      apiKey: apiKey,
      voice: settings.voiceOf(provider),
      reasoning: settings.reasoning,
      playbackPending: audio.pending,
      systemPrompt: systemPrompt(),
      tools: tools,
      steering: steering,
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
        if (epoch != _epoch) return; // A call that was hung up.
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
        if (epoch != _epoch) return; // A call that was hung up.
        _voiceLog(voiceTurnLine('closed', {'reason': reason}));
        _endSession();
        _session = null;
        _stopMic();
        _guard.stop();
        _live = _holding = false;
        _set(AgentMicState.idle, note: '语音连接断开：$reason');
      },
    );
    if (session is LayeredVoiceSession) {
      session
        ..addAskingListener((n) => _askingIs(n > 0))
        ..addSpeakingListener((on) {
          if (epoch != _epoch || _disposed) return;
          // The app's own voice is the speech: the mic state follows it like
          // it follows the model's audio.
          _guard.touch();
          if (on) {
            if (!_live && !_holding && state != AgentMicState.speaking) {
              _set(AgentMicState.speaking);
            }
          } else {
            _playbackIdle();
          }
        })
        ..onSlow = slowCue
        ..fastPathOf = fastPath;
    }
    _building = session;
    try {
      await session.connect();
    } catch (e) {
      if (identical(_building, session)) _building = null;
      // Hung up meanwhile: nothing to report.
      if (epoch != _epoch) return null;
      final model = session.model;
      _set(
        AgentMicState.idle,
        // ignore: raft_lints/avoid_caught_exception_text -- The voice demo's developer-facing connection note (provider and error), shown in the dock until the next state change.
        note: '连接失败${model == null ? '' : '（${model.split('/').last}）'}：$e',
      );
      return null;
    }
    if (identical(_building, session)) _building = null;
    if (session is! LayeredVoiceSession) {
      // A layered session says its own (it knows its two models).
      _voiceLog(
        voiceTurnLine('session', {
          'mode': 'voice-only',
          'provider': provider.name,
          'model': session.model?.split('/').last,
          'voice': settings.voiceOf(provider),
          'reasoning': settings.reasoning.name,
          'thinking': session is GeminiLiveSession
              ? session.thinkingUsed
              : null,
        }),
      );
    }
    if (_disposed || epoch != _epoch) {
      await session.close();
      return null;
    }
    _session = session;
    return session;
  }

  void _startMic() {
    _mic ??= audio.microphone().listen(
      (chunk) {
        _measure(chunk);
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
        // ignore: raft_lints/avoid_caught_exception_text -- The voice demo's developer-facing microphone note, shown in the dock until the next state change.
        _set(AgentMicState.idle, note: '麦克风不可用：$e');
      },
    );
  }

  void _stopMic() {
    unawaited(_mic?.cancel());
    _mic = null;
    if (!_disposed) micLevel.value = 0;
  }

  /// The loudness of a PCM16 little-endian chunk, eased down so the rings do
  /// not flicker between chunks.
  void _measure(Uint8List chunk) {
    final samples = chunk.lengthInBytes ~/ 2;
    if (samples == 0 || _disposed) return;
    final data = ByteData.sublistView(chunk);
    var sum = 0.0;
    for (var i = 0; i < samples; i++) {
      final v = data.getInt16(i * 2, Endian.little).toDouble();
      sum += v * v;
    }
    final rms = math.sqrt(sum / samples) / 6000;
    micLevel.value = math.max(rms.clamp(0.0, 1.0), micLevel.value * .6);
  }

  /// A call is on: connecting, listening (live), or the model is speaking. A
  /// press on the mic then is not a new turn: a tap hangs up.
  bool get _inCall =>
      _live ||
      state == AgentMicState.connecting ||
      state == AgentMicState.speaking;

  Future<void> micDown() async {
    if (_inCall) {
      // The mic toggles the call: this press is a hang up unless it is held
      // while the model speaks, which interrupts it (and talks, as before).
      _callPress = true;
      _callHoldFired = false;
      _callHold?.cancel();
      if (!_live && state == AgentMicState.speaking) {
        _callHold = Timer(tapLimit, () {
          _callHoldFired = true;
          if (_callPress) unawaited(_press());
        });
      }
      return;
    }
    await _press();
  }

  Future<void> _press() async {
    final epoch = _epoch;
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
    _cutVoice(_session);
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
    if (epoch != _epoch) return; // Hung up meanwhile: nothing is left to do.
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
    if (_callPress) {
      _callPress = false;
      _callHold?.cancel();
      _callHold = null;
      if (!_callHoldFired) {
        unawaited(restart());
        return;
      }
      _callHoldFired = false; // A hold while speaking: handled as before.
    }
    final wasPressed = _pressed;
    _pressed = false;
    if (wasPressed && !_holding && !_live) {
      _releasedAsTap = held < tapLimit;
      return;
    }
    if (_live) return;
    if (!_holding) return;
    _holding = false;
    if (held < tapLimit) {
      // A tap starts the call; it is "connecting" until the session is up.
      _live = true;
      _guard.start();
      _set(
        _session?.connected ?? false
            ? AgentMicState.live
            : AgentMicState.connecting,
      );
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

  @override
  void stopSpeaking() {
    _agentLine = null;
    saying.value = '';
    _cutVoice(_session);
    if (state == AgentMicState.speaking || state == AgentMicState.thinking) {
      _set(_live ? AgentMicState.live : AgentMicState.idle);
    }
  }

  /// Sends typed text to the voice session; false when there is no key.
  /// [context] (what is on screen, the card just tapped) goes to the model
  /// in front of the words, not into the captions.
  Future<bool> sendText(
    String text, {
    String? context,
    String? silentContext,
  }) async {
    if (!await hasKey) return false;
    say(AgentSpeaker.you, text);
    _voiceLog(voiceTurnLine('user', {'src': 'typed', 'text': text}));
    saying.value = '';
    _logAppend(AgentSpeaker.you, text);
    _set(AgentMicState.thinking);
    final session = await _ensureSession();
    if (session == null) return true;
    // [silentContext] is its own item, ahead of the words: the model knows
    // it, the words stay the person's own.
    if (silentContext != null && silentContext.isNotEmpty) {
      session.addContext(silentContext);
    }
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

  /// Says [text] as the agent's own words, verbatim, when the session is one
  /// the app can speak through (the text agent). False when it is not, or
  /// when there is no session.
  Future<bool> speak(String text) async {
    if (_disposed || !await hasKey) return false;
    final session = await _ensureSession();
    if (session is AppSpeaker) {
      // A new line of its own, not the end of the one before.
      saying.value = '';
      (session as AppSpeaker).speak(text);
      return true;
    }
    return false;
  }

  /// Context for the session that is open now (none is started for it):
  /// the model knows it, nothing is answered.
  void addContext(String text) => _session?.addContext(text);

  void _playbackIdle() {
    if (state == AgentMicState.speaking) _set(AgentMicState.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _guard.stop();
    _endSession();
    saying.dispose();
    micLevel.dispose();
    AgentVoiceSettings.instance.removeListener(_settingsChanged);
    _stopMic();
    unawaited(_session?.close());
    _session = null;
    if (audio.onPlaybackIdle == _playbackIdle) audio.onPlaybackIdle = null;
    unawaited(audio.release());
    super.dispose();
  }
}
