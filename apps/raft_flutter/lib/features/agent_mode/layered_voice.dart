import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'agent_engine.dart';
import 'agent_language.dart';
import 'agent_steering.dart';
import 'agent_thinking.dart';
import 'agent_audio.dart' show AgentVoiceKey;
import 'agent_voice_settings.dart' show AgentVoiceSettings;
import '../agent_orb/orb_preference.dart' show AgentOrbPreference;
import 'app_speech.dart';
import 'gemini_agent.dart';
import 'genkit_agent.dart';
import 'gemini_live.dart';
import 'key_info.dart';
import 'layered_listen.dart';
import 'layered_voice_mode.dart';
import 'openai_realtime.dart';
import 'realtime_voice_out.dart';
import 'voice_clip_store.dart';
import 'voice_layer_text.dart';
export 'voice_layer_text.dart' show layeredForVoice;
import 'voice_provider.dart';
import 'voice_turn_log.dart';

/// The one tool of the voice layer.
const askAgentDeclaration = <String, Object?>{
  'name': 'ask_agent',
  'description':
      '把用户的话交给 Agent，由它去 Raft 里读、去页面、回复、改任务、驾驶模式。request 填用户的原话。'
      '返回 say：就是要对用户说的话，把它的意思如实、自然地说给用户。say 是空的就不说话。',
  'parameters': {
    'type': 'object',
    'properties': {
      'request': {'type': 'string', 'description': '用户的原话（语音识别出来的字），不要改写'},
    },
    'required': ['request'],
  },
};

/// What a note from the app starts with: it is for the agent, not for the
/// person's ear.
const _appNote = '（App';

/// What the voice model is asked to tell the person: the app's own words.
String layeredVerbatim(String text) => '（App 请你说）${layeredForVoice(text)}';

/// The instruction of the voice layer: it listens and speaks, and gives
/// everything about Raft to `ask_agent`. Before it calls the tool it may say
/// one short line in its own words (so the person is not left waiting in
/// silence), and the style of that line is part of the instruction.
String layeredVoicePromptFor(AgentLanguage language) =>
    '你是用户在 Raft 里的语音助手，以一个悬浮球的形态待在 App 里。你只负责听和说：所有和 Raft 有关的事，都交给 ask_agent。\n'
    '\n'
    '【交给 Agent】用户说的任何和 Raft、App、消息、任务、频道、简报、驾驶模式有关的话——读、查、去哪里、回复、改、"下一件"，'
    '包括只说"确认""好""取消""算了"——都调用 ask_agent，request 填他的原话，不要改写，不要自己回答，不要自己判断做没做。\n'
    '\n'
    '【先接一句】调用 ask_agent 之前，可以先用一句很短的口语接住他，然后在同一轮里马上调用，不要停下来等：\n'
    '${leadStyleRules(language)}\n'
    '只有要去 Raft 里查、做的事才接；闲聊、没听清不用接。接的这句不是答案，不要说任何结果。\n'
    '\n'
    '【说出来】ask_agent 返回 say 之后，把 say 的意思如实、自然地说给用户，像朋友说话那样：'
    '人名、数字、要做的事、要他确认的问题都要说到，不要漏，也不要加 say 里没有的信息；措辞可以口语一点，不用逐字照念。say 是空的就不说话。\n'
    '\n'
    '【App 请你说】收到以“（App 请你说）”开头的话，把后面的意思如实、自然地说给用户，不要加别的信息，不要调用工具。\n'
    '\n'
    '【闲聊】打招呼、问你是谁、谢谢这类和 Raft 无关的话，自己用一两句简短回答，不调用工具。\n'
    '\n'
    '【没听清就问】如果转写出来的话乱码、几种语言混在一起、被截断，不要猜着回答；用他的语言简短说一句没听清，请他再说一遍。这样的话不要调用 ask_agent。\n'
    '\n'
    '【语言】${language.relayLine}“Agent”这个词任何语言里都照写 Agent。温暖、简短，像很熟的朋友。';

/// [layeredVoicePromptFor] for the default language.
final layeredVoicePrompt = layeredVoicePromptFor(AgentLanguage.zh);

/// The instruction of Live when it only listens ([LayeredVoiceMode.appSpeaks]):
/// what it generates is thrown away, so it is asked to generate nothing.
const layeredListenPrompt =
    '你只负责听。不要回答，不要说话，不要调用工具，不要输出任何文字：用户说什么都不要回应，保持安静。'
    '你听到的话由 App 自己处理。';

/// The agent layer behind a voice: a Gemini Live session that only listens and
/// speaks, and a [GeminiAgentSession] that does the work.
///
/// Live has one tool, `ask_agent`; what it is asked is run as one turn of the
/// agent (all its tools, its state-scoped instruction and the app's rules) and
/// the words come back as `say` for Live to speak. Nothing the agent says
/// reaches the person except through Live. The app's silent context goes to
/// the agent, not to Live; a note from the app is a turn of the agent whose
/// answer Live speaks; [speak] has Live say the app's own words.
///
/// With [LayeredVoiceMode.appSpeaks] Live does not relay: it only listens
/// (hearing, end of speech, the transcript), and the app does the rest. When
/// the person's turn is over ([UserTurnForwarder]) the app sends the
/// transcript to the agent itself, so nothing depends on the voice model
/// choosing to call a tool or copying words right; the agent's `say` is spoken
/// by [speech], a sentence at a time, exactly as it is. The person speaking
/// over it stops the voice and cuts short a turn of the agent that has not
/// answered yet. What Live generates is thrown away.
///
/// The voice layer can also be OpenAI Realtime or Grok Voice ([voiceProvider]).
/// They are always driven by the app, like [LayeredVoiceMode.appSpeaks], but
/// with [LayeredVoiceMode.liveRelays] the voice that says things is the
/// service itself: it never calls a tool or answers on its own; the app asks
/// it, line by line, to say a short lead-in it phrases from what the person
/// asked, the acknowledgment, and the agent's answer (see
/// [OpenAiRealtimeSession] with `relay`). With [LayeredVoiceMode.appSpeaks]
/// the service only listens and the device's own voice speaks.
class LayeredVoiceSession implements VoiceSession, AppSpeaker {
  LayeredVoiceSession({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    required this.steering,
    this.thinking = AgentThinking.low,
    this.engine = AgentEngine.genkit,
    this.agentModelId,
    this.slowAfter = const Duration(milliseconds: 800),
    this.ackAfter = const Duration(milliseconds: 350),
    this.voice = 'Sulafat',
    this.reasoning = AgentReasoning.low,
    this.liveModel,
    this.language = AgentLanguage.zh,
    this.mode = LayeredVoiceMode.liveRelays,
    this.speech,
    this.listen = true,
    this.confirmGrace = const Duration(milliseconds: 700),
    this.confirmWait = const Duration(seconds: 3),
    this.voiceProvider = AgentVoiceProvider.gemini,
    this.agentApiKey,
    this.preambleAfter = const Duration(milliseconds: 80),
    this.ackTarget = const Duration(milliseconds: 600),
    this.leadGrace = const Duration(milliseconds: 700),
    this.liveLeadGrace = const Duration(milliseconds: 450),
    this.playbackPending,
    this.onTimed,
    this.nowMs,
    math.Random? random,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
    VoiceSession Function(LiveParts parts)? liveBuilder,
    VoiceSession Function(AgentParts parts)? agentBuilder,
    VoiceLog? log,
  }) : _liveBuilder = liveBuilder ?? defaultLive,
       _agentBuilder = agentBuilder ?? _agentGemini,
       _acks = AckPicker(random: random),
       _log = log ?? printVoiceLog {
    final speaks = mode == LayeredVoiceMode.appSpeaks;
    final realtime = voiceProvider != AgentVoiceProvider.gemini;
    if (speaks && speech == null) {
      throw ArgumentError('appSpeaks needs a speech');
    }
    if (realtime && !listen && speech == null) {
      throw ArgumentError('a voice that is not listening needs a speech');
    }
    _forwarder = UserTurnForwarder(
      forward: _forward,
      onChunk: onInputText,
      onBargeIn: _bargeIn,
      onDropped: (text, why) =>
          _log(voiceTurnLine('user-dropped', {'why': why, 'text': text})),
      guarding: () => _speaking || (_echoTail?.isActive ?? false),
      echoOf: _echoOf,
      // The transcript of a relay voice is final when it says so: no time to
      // wait for more.
      settle: realtime
          ? const Duration(milliseconds: 20)
          : const Duration(milliseconds: 80),
    );
    _live = !listen
        ? null
        : _liveBuilder(
            realtime
                ? LiveParts(
                    provider: voiceProvider,
                    relay: true,
                    apiKey: apiKey,
                    // The voice only listens and says what the app asks it
                    // to: its instruction says so, and it has no tools.
                    systemPrompt: relayVoicePromptFor(language),
                    tools: const [],
                    onToolCall: _refuseTool,
                    voice: voice,
                    reasoning: reasoning,
                    liveModel: liveModel,
                    language: language,
                    playbackPending: playbackPending,
                    onAudio: _realtimeAudio,
                    onInputText: _forwarder.heard,
                    onInputDone: _inputDone,
                    onTiming: _segment,
                    onOutputText: _ignored,
                    onSpeechStarted: _voiceSpeechStarted,
                    onSpeechStopped: _userSpeechStopped,
                    onClosed: onClosed,
                  )
                : speaks
                ? LiveParts(
                    apiKey: apiKey,
                    systemPrompt: layeredListenPrompt,
                    tools: const [],
                    onToolCall: _liveTool,
                    voice: voice,
                    reasoning: reasoning,
                    liveModel: liveModel,
                    listenOnly: true,
                    // Everything Live generates is dropped; that it generates
                    // anything is the sign of the end of the person's turn.
                    onGenerating: _forwarder.modelActed,
                    onInputText: _forwarder.heard,
                    onOutputText: _ignored,
                    onTurnComplete: _forwarder.modelActed,
                    onInterrupted: _bargeIn,
                    onClosed: onClosed,
                  )
                : LiveParts(
                    apiKey: apiKey,
                    systemPrompt: layeredVoicePromptFor(language),
                    tools: const [askAgentDeclaration],
                    onToolCall: _liveTool,
                    voice: voice,
                    reasoning: reasoning,
                    liveModel: liveModel,
                    languageCode: language.speechCode,
                    onAudio: _relayAudio,
                    onInputText: _relayInput,
                    onOutputText: _relayOutput,
                    onTurnComplete: _relayTurnComplete,
                    onInterrupted: _relayInterrupted,
                    onClosed: onClosed,
                  ),
          );
    final live = _live;
    if (realtime &&
        mode == LayeredVoiceMode.liveRelays &&
        live is RealtimeVoiceOut) {
      // The voice service itself says the acknowledgment, the lead-in and the
      // agent's answer, one line at a time.
      _voiceSpeech = RealtimeSpeech(
        live as RealtimeVoiceOut,
        provider: voiceProvider,
        voice: voice,
        language: language,
      );
    }
    if (realtime && _voiceSpeech == null && speech == null) {
      throw ArgumentError('no voice to speak with');
    }
    _agent = _makeAgent();
  }

  /// The session of the voice layer's provider: Gemini Live, or OpenAI
  /// Realtime / Grok Voice as a relay voice.
  @visibleForTesting
  static VoiceSession defaultLive(LiveParts p) => switch (p.provider) {
    AgentVoiceProvider.gemini => geminiLive(p),
    AgentVoiceProvider.openai || AgentVoiceProvider.grok => realtimeLive(p),
  };

  /// OpenAI Realtime or Grok Voice as the voice of the layered brain: it
  /// listens, and says what the app gives it (see [OpenAiRealtimeSession]).
  @visibleForTesting
  static VoiceSession realtimeLive(LiveParts p) {
    // The sound of the canned lines is kept between runs, in the cache.
    OpenAiRealtimeSession.clipStore ??= FileVoiceClipStore();
    return _realtimeLive(p);
  }

  static VoiceSession _realtimeLive(LiveParts p) => OpenAiRealtimeSession(
    service: p.provider == AgentVoiceProvider.grok
        ? RealtimeService.grok
        : RealtimeService.openai,
    relay: true,
    apiKey: p.apiKey,
    modelId: p.liveModel,
    voice: p.voice,
    reasoning: p.reasoning,
    language: p.language,
    systemPrompt: p.systemPrompt,
    tools: const [],
    onToolCall: p.onToolCall,
    playbackPending: p.playbackPending,
    onAudio: p.onAudio,
    onInputText: p.onInputText,
    onInputDone: p.onInputDone,
    onTiming: p.onTiming,
    onOutputText: p.onOutputText,
    onSpeechStarted: p.onSpeechStarted,
    onSpeechStopped: p.onSpeechStopped,
    onClosed: p.onClosed,
  );

  @visibleForTesting
  static VoiceSession geminiLive(LiveParts p) => GeminiLiveSession(
    apiKey: p.apiKey,
    voice: p.voice,
    reasoning: p.reasoning,
    preferredModel: p.liveModel,
    languageCode: p.languageCode,
    systemPrompt: p.systemPrompt,
    tools: p.tools,
    onToolCall: p.onToolCall,
    onAudio: p.onAudio,
    onInputText: p.onInputText,
    onOutputText: p.onOutputText,
    onTurnComplete: p.onTurnComplete,
    onInterrupted: p.onInterrupted,
    onClosed: p.onClosed,
    onGenerating: p.onGenerating,
    listenOnly: p.listenOnly,
    // Live only relays or listens here: the quickest model, no extended
    // thinking.
    fast: true,
  );

  /// The agent on the engine of the setting: Genkit, or the direct calls.
  static VoiceSession _agentGemini(AgentParts p) => switch (p.engine) {
    AgentEngine.genkit => GenkitAgentSession(
      apiKey: p.apiKey,
      modelId: p.model,
      systemPrompt: p.systemPrompt,
      tools: p.tools,
      steering: p.steering,
      thinking: p.thinking,
      onToolCall: p.onToolCall,
      onOutputText: p.onOutputText,
      onDraft: p.onDraft,
      onTurnComplete: p.onTurnComplete,
      onClosed: p.onClosed,
    ),
    AgentEngine.direct => GeminiAgentSession(
      apiKey: p.apiKey,
      modelName: p.model,
      systemPrompt: p.systemPrompt,
      tools: p.tools,
      steering: p.steering,
      thinking: p.thinking,
      onToolCall: p.onToolCall,
      onOutputText: p.onOutputText,
      onDraft: p.onDraft,
      onTurnComplete: p.onTurnComplete,
      onClosed: p.onClosed,
    ),
  };

  /// Where the `voice-turn` lines go (one per event, in the logcat).
  final VoiceLog _log;

  /// The command the app did without the model in the turn just asked, if any
  /// (the orb sets it): named in the `ask` line.
  String? Function()? fastPathOf;

  final String apiKey;

  /// The agent's, when it has no steering to give another.
  final String systemPrompt;
  final List<Map<String, Object?>> tools;

  /// How long an ask may take before [onSlow] is told.
  final Duration slowAfter;

  /// How long an ask may take before the app says a short acknowledgment in
  /// its own voice ([speech]). The agent's quick answers come well within it
  /// and get none; the voice model says nothing while it waits, so without it
  /// the person hears nothing for seconds.
  final Duration ackAfter;

  /// The agent is taking its time: the app gives the person a cue of its own
  /// (the voice model says nothing while it waits). Not told for an ask whose
  /// acknowledgment was spoken: that is the cue.
  void Function()? onSlow;

  /// How many asks to the agent are in flight. The orb is thinking while it is
  /// above zero, and an evaluation does not call a turn over before it is
  /// back to zero.
  int get asking => _asking;
  int _asking = 0;
  final _askingListeners = <void Function(int inFlight)>[];

  /// Told each time the number of asks in flight changes.
  void addAskingListener(void Function(int inFlight) listener) =>
      _askingListeners.add(listener);

  void _askingIs(int n) {
    if (n == _asking) return;
    _asking = n;
    for (final f in [..._askingListeners]) {
      f(n);
    }
  }

  /// How the voice layer speaks: Live relays, or the app speaks.
  final LayeredVoiceMode mode;

  /// The voice service of the voice layer. The text agent is Gemini
  /// whichever it is.
  final AgentVoiceProvider voiceProvider;

  /// The Gemini key of the text agent when it is not [apiKey] (the voice
  /// service's key).
  final String? agentApiKey;

  /// How much of the speech received is still to be played (the realtime
  /// voices cut the unheard part off with it).
  final Future<Duration> Function()? playbackPending;

  /// How long after the person's turn is forwarded the voice is asked for its
  /// own lead-in (a quick fast-path answer comes before and has none).
  final Duration preambleAfter;

  /// When a voice service speaks (OpenAI, Grok), the time from the end of the
  /// person's speech by which the acknowledgment should be heard: a kept clip
  /// of a canned line is instant, a response of the service takes about a
  /// second to start to sound.
  final Duration ackTarget;

  /// How long the app waits for a lead-in that was asked for before it falls
  /// back on a canned acknowledgment.
  final Duration leadGrace;

  /// With Gemini Live relaying: the extra time its own lead-in is given
  /// before the app's acknowledgment steps in.
  final Duration liveLeadGrace;

  /// Told the time from the end of the person's speech to the first sound of
  /// the voice (`voice`, whatever it says) and to the first sentence of the
  /// answer (`answer`), in milliseconds, once each turn.
  void Function(String what, int ms)? onTimed;

  /// The clock of the timings, in milliseconds (the wall clock by default).
  final int Function()? nowMs;

  /// Told where the time of a turn goes, a piece at a time, in milliseconds:
  /// `rtt`, `transcribe`, `say.created`, `say.firstAudio`, `lead.created`,
  /// `lead.firstAudio` (from the voice service, see `OpenAiRealtimeSession`),
  /// `forward` (the transcript complete to the agent being asked: our own
  /// settling) and `request` (that to the first line asked of the voice: our
  /// own timers). The evaluation puts the medians in its report.
  void Function(String segment, int ms)? onSegment;

  /// Told what the voice said while the agent worked: `lead` (the voice's own
  /// words) or `ack` (the app's canned line), with the words (the evaluation
  /// records it).
  void Function(String kind, String text)? onFeedback;

  /// The app's voice ([LayeredVoiceMode.appSpeaks]).
  final SpeechOut? speech;

  /// With Live relaying: how long after its turn is over the words it said
  /// are checked against a confirmation card (late transcripts), and how long
  /// it is waited for when it has said nothing yet.
  final Duration confirmGrace, confirmWait;

  /// Whether Live is connected and listened to. An evaluation types the
  /// person's words instead of speaking them: the same path, without a
  /// microphone, and nothing of Live in it.
  final bool listen;

  bool get _appSpeaks => mode == LayeredVoiceMode.appSpeaks;

  /// Whether the app decides what is said and when (the voice only listens):
  /// the app speaks, or the voice service is a relay voice.
  bool get _appDriven =>
      _appSpeaks || voiceProvider != AgentVoiceProvider.gemini;

  /// The voice service saying the app's lines (OpenAI / Grok relaying).
  RealtimeSpeech? _voiceSpeech;

  /// The voice that says the lines of the app: the service itself or the
  /// device's.
  SpeechOut? get _voice => _voiceSpeech ?? speech;

  /// The app's tools: the agent's, never Live's.
  @override
  final AgentToolHandler onToolCall;
  final AgentSteering steering;

  /// How hard the agent behind the voice thinks.
  final AgentThinking thinking;

  /// What makes the agent's model calls.
  final AgentEngine engine;

  /// The agent's model, when one is asked for (else its own discovery).
  final String? agentModelId;
  final String voice;
  final AgentReasoning reasoning;

  /// The Live model the person chose; null lets the app pick.
  final String? liveModel;

  /// The language the voice is pinned to (the prompt says it; Live is also
  /// asked for it, where the model takes that).
  final AgentLanguage language;
  @override
  final void Function(Uint8List pcm24k)? onAudio;
  @override
  final void Function(String text)? onInputText;
  @override
  final void Function(String text)? onOutputText;
  @override
  final void Function()? onTurnComplete;
  @override
  final void Function()? onInterrupted;
  @override
  final void Function(String reason)? onClosed;

  final VoiceSession Function(LiveParts) _liveBuilder;
  final VoiceSession Function(AgentParts) _agentBuilder;
  late final VoiceSession? _live;
  late VoiceSession _agent;
  late final UserTurnForwarder _forwarder;

  /// The agent session now in use (tests look at what engine it is on).
  @visibleForTesting
  VoiceSession get agent => _agent;
  bool _closed = false;

  /// The turns the agent has been given and not yet finished, oldest first.
  final _asks = Queue<_Ask>();
  final _words = StringBuffer();

  VoiceSession _makeAgent() => _agentBuilder(
    AgentParts(
      apiKey: agentApiKey ?? apiKey,
      systemPrompt: systemPrompt,
      tools: tools,
      steering: steering,
      thinking: thinking,
      engine: engine,
      model: agentModelId,
      onToolCall: onToolCall,
      onOutputText: _words.write,
      onDraft: _agentDraft,
      onTurnComplete: _agentFinished,
      onClosed: _agentClosed,
    ),
  );

  void _agentFinished() {
    // Whatever of the prompt's language lines the model repeated is not said.
    final text = AgentLanguage.scrub('$_words').trim();
    _words.clear();
    if (_asks.isNotEmpty) _asks.removeFirst().done.complete(text);
  }

  /// Words of the agent's answer as they stream (a draft of what it ends the
  /// turn with): handed to the voice sentence by sentence when the ask is one
  /// the app speaks the answer of.
  void _agentDraft(String delta) {
    if (_closed || _asks.isEmpty) return;
    _asks.first.draft?.add(delta);
  }

  void _agentClosed(String reason) {
    _log(voiceTurnLine('agent-closed', {'reason': reason}));
    _words.clear();
    while (_asks.isNotEmpty) {
      _asks.removeFirst().done.completeError(StateError('agent closed'));
    }
  }

  @override
  bool get connected => (!listen || _live!.connected) && _agent.connected;

  @override
  String? get model => _live?.model;

  /// The agent's model, once it is known.
  String? get agentModel => _agent.model;

  /// The thinking the voice model runs with (the least it accepts), once
  /// connected.
  String? get liveThinking {
    final live = _live;
    return live is GeminiLiveSession ? live.thinkingUsed : null;
  }

  /// Told each time Live asked the agent: what it asked, what came back to
  /// say, how long it took (the evaluation records it).
  void Function(String request, String say, int millis)? onAsk;

  /// Told each sentence the app's voice is asked to speak, as it is asked
  /// (the evaluation records it).
  void Function(String sentence)? onSpoken;

  @override
  Future<void> connect() async {
    await Future.wait([if (listen) _live!.connect(), _agent.connect()]);
    final live = _live;
    _log(
      voiceTurnLine('session', {
        'mode': 'layered',
        'live': _appSpeaks ? 'appSpeaks' : 'liveRelays',
        'voiceProvider': voiceProvider.name,
        'liveModel': live?.model?.split('/').last,
        // The voice Live speaks with; the app's own voice is `tts-voice`.
        'liveVoice': _appSpeaks ? null : voice,
        'language': language.name,
        'liveThinking': liveThinking,
        'agent': engine.name,
        'agentModel': _agent.model,
        'agentThinking': thinking.name,
      }),
    );
    // The sound of the canned acknowledgments is made once, in the
    // background: afterwards they are said at once.
    final speaker = _voiceSpeech;
    if (speaker != null) unawaited(speaker.prewarm(ackPhrases(language)));
    final Object? info = speech;
    if (info is SpeechVoiceInfo) {
      unawaited(
        info.prepare().then(
          (_) => _log(voiceTurnLine('tts-voice', info.voiceInfo)),
        ),
      );
    }
  }

  /// The agent after a failure: a new one, with a new history.
  Future<void> _revive() async {
    if (_closed || _agent.connected) return;
    final fresh = _makeAgent();
    await fresh.connect();
    _agent = fresh;
  }

  /// One turn of the agent: the words it ended with, or throws when it could
  /// not answer.
  Future<String> _runAgent(String text, {_Draft? draft}) async {
    if (!_agent.connected) await _revive();
    final ask = _Ask(draft);
    _asks.add(ask);
    _agent.sendText(text);
    return ask.done.future;
  }

  /// One ask to the agent: what it says, and how long it took; null when the
  /// person spoke over it and it was cut short.
  ///
  /// While it waits the person is not left in silence: with a relay voice
  /// ([speaksLead]) the voice phrases one short lead-in of its own from the
  /// request, and when nothing has been said soon after, the app says a short
  /// acknowledgment itself, in the voice that is active. [draft] is handed the
  /// agent's words as they stream.
  Future<String?> _ask(
    String request, {
    bool speaksLead = false,
    _Draft? draft,
  }) async {
    final watch = Stopwatch()..start();
    _askingIs(_asking + 1);
    var acked = false;
    SpeechHandle? leading;
    var leadAt = 0;
    Timer? lead;
    // With the sound of the acknowledgments kept, the acknowledgment is the
    // first thing heard (instant), and the voice's own lead-in goes on from
    // it; otherwise the lead-in is asked for at once and the acknowledgment
    // steps in when it does not come.
    final cachedAck = speaksLead && _ackIsInstant;
    if (speaksLead && _voiceSpeech != null && !cachedAck) {
      lead = Timer(preambleAfter, () {
        leading = _startLead(request);
        leadAt = _now();
        acked = leading != null;
      });
    }
    Timer? ack;
    void tryAck() {
      if (_closed) return;
      final l = leading;
      if (l != null && !l.cancelled && !l.failed) {
        if (l.started) {
          acked = true;
          return;
        }
        // Its own lead-in is on the way: it is given a moment.
        final waited = Duration(milliseconds: _now() - leadAt);
        if (waited < leadGrace) {
          ack = Timer(leadGrace - waited, tryAck);
          return;
        }
        // It never sounded: it is taken back, so that it does not stand in
        // front of the acknowledgment in the voice's queue.
        if (!l.started) l.cancel();
      }
      acked = _acknowledge();
      if (acked && cachedAck && !_closed) {
        _stage('lead-requested');
        leading = _startLead(request, after: _lastAck);
        leadAt = _now();
      }
    }

    // The time the acknowledgment is due: after the ask has been out for
    // [ackAfter]; for a voice service, by [ackTarget] after the person's
    // speech ended when that is later.
    Duration ackDue() {
      if (!_appDriven) return ackAfter + liveLeadGrace;
      if (_voiceSpeech == null) return ackAfter;
      // The floor leaves a fast path (a command the app does without a model,
      // answered in well under that) its chance to answer first.
      const floor = Duration(milliseconds: 200);
      final least = ackAfter < floor ? ackAfter : floor;
      final late = ackTarget - Duration(milliseconds: _now() - _userEndedAt);
      return late > least ? late : least;
    }

    ack = Timer(ackDue(), tryAck);
    final slow = Timer(slowAfter, () {
      // A voice already sounding (a lead-in, a streamed sentence) is the cue.
      if (!acked && !_turnVoiced) onSlow?.call();
    });
    String? say;
    try {
      say = await _runAgent(request, draft: draft);
    } on _Cancelled {
      say = null;
    } catch (_) {
      say = agentFailedLine(language);
    } finally {
      lead?.cancel();
      ack?.cancel();
      slow.cancel();
      // A lead-in that has not begun to sound is not wanted any more: the
      // answer is here.
      final l = leading;
      if (l != null && !l.started) l.cancel();
    }
    if (say != null) {
      _log(
        voiceTurnLine('ask', {
          'request': request,
          'say': say,
          'ms': watch.elapsedMilliseconds,
          'fastPath': fastPathOf?.call(),
        }),
      );
      onAsk?.call(request, say, watch.elapsedMilliseconds);
    } else {
      _log(
        voiceTurnLine('ask', {
          'request': request,
          'cut': true,
          'ms': watch.elapsedMilliseconds,
        }),
      );
    }
    // Out of flight as the answer goes on, to Live or to the voice: the turn
    // is not over before it has it.
    if (!_closed) _askingIs(_asking - 1);
    return say;
  }

  /// The voice service of a relay voice has no tools; if it calls one it is
  /// not run (the agent, never the voice, calls the app's tools).
  Future<Map<String, Object?>> _refuseTool(
    String name,
    Map<String, Object?> args,
  ) async {
    _log(
      voiceTurnLine('tool-refused', {'name': name, 'who': voiceProvider.name}),
    );
    return {'error': '语音层不调用工具：$name'};
  }

  Future<Map<String, Object?>> _liveTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (name != 'ask_agent') return {'error': '没有这个工具：$name'};
    final request = '${args['request'] ?? ''}'.trim();
    if (request.isEmpty) return {'say': ''};
    final say = await _ask(request) ?? '';
    _liveAnswerWaiting = say.isNotEmpty;
    // The answer that asks the person to confirm a card is the one thing
    // whose speech is checked.
    final info = say.isEmpty ? null : steering.confirmation?.call();
    _watch = info == null ? null : _Watch(say, info);
    return {'say': layeredForVoice(say)};
  }

  // ---- Live relays: the safety net for a confirmation ----------------------

  _Watch? _watch;
  Timer? _watchTimer;

  /// Told when the voice's words for a card missed something and the app
  /// said the line itself: the line and what was missing.
  void Function(String say, List<String> missing)? onCorrection;

  // When the person was last heard and Live last spoke: Live has spoken for
  // this turn (a lead-in of its own) when it did so after the person.
  int? _heardAt, _liveSpokeAt;

  bool get _liveVoicedThisTurn =>
      _liveSpokeAt != null && (_heardAt == null || _liveSpokeAt! >= _heardAt!);

  void _relayInput(String text) {
    final now = _now();
    // A new utterance after a pause: a new turn for the timing.
    if (_heardAt == null || now - _heardAt! > 3000) {
      _timedVoice = _timedAnswer = false;
    }
    _heardAt = now;
    // The last piece of the transcript is the nearest to the end of speech.
    _userEndedAt = now;
    onInputText?.call(text);
  }

  void _relayOutput(String text) {
    _endAck();
    _liveSpoke();
    _watch?.heard.write(text);
    onOutputText?.call(text);
  }

  void _relayAudio(Uint8List pcm24k) {
    _endAck();
    _liveSpoke();
    onAudio?.call(pcm24k);
  }

  /// The agent has answered and Live has not said it yet.
  bool _liveAnswerWaiting = false;

  void _liveSpoke() {
    _timed(_liveAnswerWaiting ? 'answer' : 'live');
    _liveAnswerWaiting = false;
    _liveSpokeAt = _now();
  }

  void _relayInterrupted() {
    _endAck();
    // The person spoke over it: nothing is corrected.
    final waiting = _watch?.waiting ?? false;
    _watch = null;
    _watchTimer?.cancel();
    onInterrupted?.call();
    if (waiting) onTurnComplete?.call();
  }

  void _relayTurnComplete() {
    final w = _watch;
    if (w == null) {
      onTurnComplete?.call();
      return;
    }
    // Its turn is over: its last words may still be on the way.
    w.waiting = true;
    _scheduleCheck(w, confirmGrace);
  }

  void _scheduleCheck(_Watch w, Duration after) {
    _watchTimer?.cancel();
    _watchTimer = Timer(after, () => unawaited(_checkWatch(w)));
  }

  Future<void> _checkWatch(_Watch w) async {
    if (_closed || !identical(_watch, w)) return;
    // Said nothing yet: the turn that ended may have been an earlier one
    // (a filler); the real one gets its time.
    if (w.heard.isEmpty && !w.extended) {
      w.extended = true;
      _scheduleCheck(w, confirmWait);
      return;
    }
    _watch = null;
    final missing = w.info.missingIn('${w.heard}');
    if (missing.isNotEmpty) {
      onCorrection?.call(w.say, missing);
      await _correct(w.say);
    }
    if (!_closed) onTurnComplete?.call();
  }

  /// The app says the confirmation line itself: deterministic. Without a
  /// voice of its own, Live is asked to say it once more.
  Future<void> _correct(String say) async {
    final voice = speech;
    if (voice == null) {
      _live!.sendText(layeredVerbatim(say));
      return;
    }
    // What of Live's voice is still playing is cut.
    onInterrupted?.call();
    _voiceSpeech?.out.cancelSpeech();
    final generation = _speechGeneration;
    for (final sentence in orbSentences(say)) {
      if (_closed || generation != _speechGeneration) return;
      onSpoken?.call(sentence);
      await _appSay(
        sentence,
        'confirm',
        onStart: () => _speakingIs(true),
        voice: voice,
      );
    }
    _speakingIs(false);
  }

  /// Asks the voice to say [sentence] and logs who says it ([kind]: `ack`,
  /// `lead`, `answer`, or `confirm` for the line that asks to confirm a
  /// card), with the engine and voice once the sound begins. A sentence that
  /// never began (cut off, or no engine) is logged as such. Whether it began.
  Future<bool> _appSay(
    String sentence,
    String kind, {
    void Function()? onStart,
    SpeechOut? voice,
  }) async {
    final out = voice ?? _voice!;
    final who = out is RealtimeSpeech ? voiceProvider.name : 'app-tts';
    var started = false;
    final watch = Stopwatch()..start();
    Map<String, Object?> info() => out is SpeechVoiceInfo
        ? (out as SpeechVoiceInfo).voiceInfo
        : const <String, Object?>{};
    await out.speak(
      sentence,
      onStart: () {
        started = true;
        _timed(kind);
        _log(
          voiceTurnLine('speak', {
            'who': who,
            'kind': kind,
            'text': sentence,
            ...info(),
          }),
        );
        onStart?.call();
      },
    );
    if (!started) {
      _log(
        voiceTurnLine('speak-none', {
          'who': who,
          'kind': kind,
          'text': sentence,
          'ms': watch.elapsedMilliseconds,
          ...info(),
        }),
      );
    }
    return started;
  }

  // ---- timing ---------------------------------------------------------------

  // The time since the person stopped speaking (the server's voice activity
  // detection says when; for typed text, when it was sent), and whether the
  // first sound of the voice and the first sentence of the answer have been
  // told for this turn.
  int _userEndedAt = 0;
  bool _timedVoice = false;
  bool _timedAnswer = false;

  bool _stopPending = false;

  /// The time now, in milliseconds (a test gives its own clock).
  int _now() => (nowMs ?? () => DateTime.now().millisecondsSinceEpoch)();

  void _userSpeechStopped() {
    _userEndedAt = _now();
    _timedVoice = _timedAnswer = false;
    _stopPending = true;
    _stage('speech-stopped');
  }

  int? _inputDoneAt, _forwardedAt;
  bool _requestTimed = false;

  /// The transcript of the person's words is complete.
  void _inputDone() {
    _inputDoneAt = _now();
    _forwarder.modelActed();
  }

  void _segment(String name, int ms) {
    _log(voiceTurnLine('segment', {'name': name, 'ms': ms}));
    onSegment?.call(name, ms);
  }

  /// The turn of the person is forwarded: the clock runs from the end of
  /// their speech (known for a realtime voice) or from now.
  void _turnBegan() {
    if (!_stopPending) _userSpeechStopped();
    _stopPending = false;
    _turnVoiced = false;
  }

  /// One line of the log for the timeline of a turn: how long after the end of
  /// the person's speech each step happened (speech stopped, transcript done
  /// and forwarded, the acknowledgment and the lead-in asked for, the first
  /// sound).
  void _stage(String name) {
    _log(voiceTurnLine('stage', {'name': name, 'ms': _now() - _userEndedAt}));
  }

  /// A sound began: [kind] is `ack`, `lead`, `answer`, `confirm` (the app's
  /// voice), or `live` (Gemini Live's own).
  void _timed(String kind) {
    final ms = _now() - _userEndedAt;
    if (!_timedVoice && kind != 'confirm') {
      _timedVoice = true;
      _log(voiceTurnLine('latency', {'what': 'voice', 'kind': kind, 'ms': ms}));
      onTimed?.call('voice', ms);
    }
    if (!_timedAnswer && kind == 'answer') {
      _timedAnswer = true;
      _log(voiceTurnLine('latency', {'what': 'answer', 'ms': ms}));
      onTimed?.call('answer', ms);
    }
  }

  // ---- the app speaks -----------------------------------------------------

  /// Whether something of the turn under way has been heard by the person
  /// already (a lead-in, an acknowledgment, a streamed sentence).
  bool _turnVoiced = false;

  /// The person's turn is over: the agent is asked, and the answer is said.
  /// The same whether the words were heard (the transcript) or typed.
  void _forward(String text, {bool heard = true}) {
    if (_closed || text.trim().isEmpty) return;
    // Typed text is logged by whoever took it; what was heard, here.
    if (heard) _log(voiceTurnLine('user', {'src': 'voice', 'text': text}));
    // What was still being said is stale now: the person has spoken again.
    if (_speaking) _bargeIn();
    _recentSpoken = '';
    _turnBegan();
    _stage('forwarded');
    _forwardedAt = _now();
    _requestTimed = false;
    final done = _inputDoneAt;
    if (done != null) _segment('forward', _forwardedAt! - done);
    _inputDoneAt = null;
    unawaited(_answer(text));
  }

  Future<void> _answer(String request) async {
    final draft = _Draft(_speakDraft);
    final say = await _ask(request, speaksLead: true, draft: draft);
    if (say == null || _closed) return;
    await _sayOut(say, drafted: draft.handed, info: _confirmInfo(say));
  }

  /// What the answer has to carry when it asks to confirm a card (null for
  /// every other answer).
  KeyInfo? _confirmInfo(String say) =>
      say.isEmpty ? null : steering.confirmation?.call();

  /// Live generated something while it only listens: dropped, but logged.
  void _ignored(String text) {
    _log(voiceTurnLine('live-output-ignored', {'chars': text.length}));
  }

  // What the voice said last, to tell its echo from the person.
  String _recentSpoken = '';
  bool _speaking = false;
  Timer? _echoTail;
  int _speechGeneration = 0;
  Future<void> _speechTail = Future.value();
  final _speakingListeners = <void Function(bool speaking)>[];

  /// Whether the voice is sounding.
  bool get speaking => _speaking;

  /// Told each time the voice starts or stops sounding.
  void addSpeakingListener(void Function(bool speaking) listener) =>
      _speakingListeners.add(listener);

  void _speakingIs(bool now) {
    if (_speaking == now) return;
    _speaking = now;
    if (!now) {
      // The room still carries the end of the voice for a moment.
      _echoTail?.cancel();
      _echoTail = Timer(const Duration(milliseconds: 1200), () {});
    }
    for (final f in [..._speakingListeners]) {
      f(now);
    }
  }

  /// Whether [heard] (letters and digits) is mostly what the voice just said.
  bool _echoOf(String heard) {
    final said = _recentSpoken;
    if (said.isEmpty || heard.length < 4) return false;
    if (said.contains(heard)) return true;
    String grams(String t, int i) => t.substring(i, i + 2);
    final mine = {for (var i = 0; i + 2 <= said.length; i++) grams(said, i)};
    var shared = 0;
    var total = 0;
    for (var i = 0; i + 2 <= heard.length; i++) {
      total++;
      if (mine.contains(grams(heard, i))) shared++;
    }
    return total > 0 && shared / total >= .8;
  }

  /// A sentence of the agent's answer, while the agent is still going: queued
  /// behind what is being said, like the rest of the answer.
  void _speakDraft(String sentence) {
    if (_closed) return;
    // The answer itself has begun: a lead-in that has not sounded is not
    // wanted any more.
    final lead = _leadHandle;
    if (lead != null && !lead.started) lead.cancel();
    final generation = _speechGeneration;
    _speechTail = _speechTail.then((_) => _speakSentence(sentence, generation));
  }

  /// Says [say] a sentence at a time, after what is being said. When it is
  /// over (or there is nothing to say) the turn is over. [drafted] are the
  /// sentences of it that were already handed to the voice while the agent
  /// went on; only the rest is said. [info] is what an answer that asks to
  /// confirm a card has to carry.
  Future<void> _sayOut(
    String say, {
    List<String> drafted = const [],
    KeyInfo? info,
  }) {
    final generation = _speechGeneration;
    return _speechTail = _speechTail.then(
      (_) => _sayNow(say, generation, drafted: drafted, info: info),
    );
  }

  /// What of [finalSentences] is still to be said after [spoken] (the
  /// sentences of the draft that were said first, in order). Sentences before
  /// the first one said are narration of an earlier step of the agent that
  /// was never drafted: it is too late for them. A final text that does not
  /// hold what was said at all still has all of it said: nothing the app
  /// wants heard is lost.
  @visibleForTesting
  static List<String> afterDraft(
    List<String> finalSentences,
    List<String> spoken,
  ) {
    if (spoken.isEmpty) return finalSentences;
    String c(String t) => UserTurnForwarder.compact(t);
    final first = finalSentences.indexWhere((s) => c(s) == c(spoken.first));
    if (first < 0) return finalSentences;
    final out = <String>[];
    var i = 0;
    for (final s in finalSentences.skip(first)) {
      if (i < spoken.length && c(s) == c(spoken[i])) {
        i++;
      } else {
        out.add(s);
      }
    }
    return out;
  }

  // What the voice service read of the answer (a model reads a line, it does
  // not play it: it may drop a word), to check against a confirmation.
  final _read = StringBuffer();

  Future<void> _speakSentence(String sentence, int generation) async {
    if (_closed || generation != _speechGeneration) return;
    _recentSpoken += UserTurnForwarder.compact(sentence);
    _turnVoiced = true;
    onSpoken?.call(sentence);
    await _appSay(
      sentence,
      'answer',
      onStart: () {
        if (generation != _speechGeneration) return;
        _speakingIs(true);
        // The caption follows the voice.
        onOutputText?.call(sentence);
      },
    );
    final voice = _voiceSpeech;
    if (voice != null && !voice.exact) _read.write(voice.lastTranscript);
  }

  Future<void> _sayNow(
    String say,
    int generation, {
    List<String> drafted = const [],
    KeyInfo? info,
  }) async {
    if (_closed || generation != _speechGeneration) return;
    final all = orbSentences(say);
    final rest = drafted.isEmpty ? all : afterDraft(all, drafted);
    if (drafted.isNotEmpty && rest.length != all.length - drafted.length) {
      _log(
        voiceTurnLine('stream-diverged', {
          'drafted': drafted.length,
          'final': all.length,
          'said': rest.length,
        }),
      );
    }
    if (drafted.isEmpty) _read.clear();
    for (final sentence in rest) {
      if (_closed || generation != _speechGeneration) return;
      await _speakSentence(sentence, generation);
    }
    if (_closed || generation != _speechGeneration) return;
    // The voice service has the last words in its buffer still.
    await _voiceSpeech?.drained();
    if (_closed || generation != _speechGeneration) return;
    _speakingIs(false);
    await _checkReading(say, info);
    if (_closed || generation != _speechGeneration) return;
    _log(
      voiceTurnLine('turn-complete', {
        'who': _voiceSpeech == null ? 'app-tts' : voiceProvider.name,
      }),
    );
    onTurnComplete?.call();
  }

  /// A voice model reads the line it is given; when the line asks the person
  /// to confirm a card and its reading left something out, the device's voice
  /// says the line (the same net as Gemini Live's).
  Future<void> _checkReading(String say, KeyInfo? info) async {
    final voice = _voiceSpeech;
    final text = '$_read';
    _read.clear();
    if (voice == null || voice.exact || info == null || speech == null) return;
    final missing = info.missingIn(text);
    if (missing.isEmpty) return;
    onCorrection?.call(say, missing);
    await _correct(say);
  }

  // What the app says while the agent works, in turn.
  final AckPicker _acks;
  String? _lastAck;

  /// The first line asked of the voice in this turn: how long after the
  /// agent was asked.
  bool _timeRequest() {
    final at = _forwardedAt;
    if (!_requestTimed && at != null) _segment('request', _now() - at);
    return true;
  }

  /// Whether the acknowledgment of a voice service is said at once (the sound
  /// of some canned line is kept).
  bool get _ackIsInstant {
    final voice = _voiceSpeech;
    return voice != null && ackPhrases(language).any(voice.hasClip);
  }

  final _recentLeads = <String>[];
  bool _acking = false;

  /// The voice phrases a short lead-in of its own from [request] and says it,
  /// queued like any other speech so that the answer follows and does not
  /// overlap. Not reported to [onSpoken] or the captions (it is not part of
  /// the answer), but it counts as the voice's echo.
  SpeechHandle? _leadHandle;

  SpeechHandle? _startLead(String request, {String? after}) {
    final voice = _voiceSpeech;
    // (A lead-in that goes on from the acknowledgment is not stopped by it.)
    if (_closed || voice == null || (_turnVoiced && after == null)) return null;
    final generation = _speechGeneration;
    _requestTimed = _timeRequest();
    final handle = voice.lead(
      request,
      avoid: [..._recentLeads],
      after: after,
      onStart: () {
        if (generation != _speechGeneration) return;
        _turnVoiced = true;
        _timed('lead');
        _speakingIs(true);
      },
      onTranscript: (piece) =>
          _recentSpoken += UserTurnForwarder.compact(piece),
    );
    _leadHandle = handle;
    late final Future<void> mine;
    mine = _speechTail = _speechTail.then((_) async {
      if (_closed || generation != _speechGeneration) return;
      await handle.done;
      if (_closed || generation != _speechGeneration) return;
      final said = handle.transcript.trim();
      if (handle.started && said.isNotEmpty) {
        _recentLeads.add(said);
        if (_recentLeads.length > 3) _recentLeads.removeAt(0);
        onFeedback?.call('lead', said);
        _log(
          voiceTurnLine('speak', {
            'who': voiceProvider.name,
            'kind': 'lead',
            'text': said,
            ...voice.voiceInfo,
          }),
        );
      }
      if (identical(_speechTail, mine)) _speakingIs(false);
    });
    return handle;
  }

  /// Says one short acknowledgment, queued like any other speech so that an
  /// answer follows it and does not overlap, in the voice that is active:
  /// the voice service's (OpenAI, Grok), the device's, or Gemini Live's when
  /// the device has none (or says nothing). Not reported to [onSpoken] or the
  /// captions (it is not part of the answer), but it counts as the voice's
  /// echo. Whether it is said: not when something of this turn has been
  /// heard already.
  bool _acknowledge() {
    if (_closed || _turnVoiced) return false;
    if (!_appDriven && _liveVoicedThisTurn) return false;
    final out = _voice;
    final voiceSpeech = _voiceSpeech;
    // A line whose sound is kept is said at once.
    final text = voiceSpeech == null
        ? _acks.next(language)
        : (_acks.nextWhere(language, voiceSpeech.hasClip) ??
              _acks.next(language));
    _lastAck = text;
    _stage('ack-requested');
    _requestTimed = _timeRequest();
    _recentSpoken += UserTurnForwarder.compact(text);
    if (out == null) {
      // Gemini Live relaying with no voice of the device's: Live says it, as
      // it says the app's other lines.
      final live = _live;
      if (_appDriven || live == null) return false;
      live.sendText(layeredVerbatim(text));
      _turnVoiced = true;
      onFeedback?.call('ack', text);
      return true;
    }
    _acking = true;
    _turnVoiced = true;
    final generation = _speechGeneration;
    late final Future<void> mine;
    mine = _speechTail = _speechTail.then((_) async {
      if (_closed || generation != _speechGeneration) return;
      final started = await _appSay(
        text,
        'ack',
        onStart: () {
          if (generation == _speechGeneration) _speakingIs(true);
        },
      );
      if (_closed || generation != _speechGeneration) return;
      _acking = false;
      if (started) onFeedback?.call('ack', text);
      // A device without a voice says nothing: Live says it instead.
      final live = _live;
      if (!started && !_appDriven && live != null && !_liveVoicedThisTurn) {
        live.sendText(layeredVerbatim(text));
      }
      // An answer queued behind it carries the voice on.
      if (identical(_speechTail, mine)) _speakingIs(false);
    });
    return true;
  }

  /// Live starts to answer (or the person spoke over it): the acknowledgment
  /// is cut, so that the two voices do not overlap.
  void _endAck() {
    if (_acking) stopSpeech();
  }

  /// Stops the voice now, and what is queued to be said.
  void stopSpeech() {
    _acking = false;
    _speechGeneration++;
    _speakingIs(false);
    unawaited(_voice?.stop());
    // The device's voice may also have been speaking (a confirmation line).
    if (_voiceSpeech != null) unawaited(speech?.stop());
  }

  /// The realtime voice's sound: handed on as it is.
  void _realtimeAudio(Uint8List pcm24k) => onAudio?.call(pcm24k);

  /// The person began to speak. While the voice is sounding that is a
  /// barge-in (the service's own voice activity detection; the device cancels
  /// the echo of the voice, as it does for the voice-only mode).
  void _voiceSpeechStarted() {
    if (_closed) return;
    if (_speaking) _bargeIn();
  }

  /// The person speaks over the app: the voice stops, and an ask the agent
  /// has not answered yet is cut short (what it was doing stops at its next
  /// step, and nothing of it is said).
  void _bargeIn() {
    if (_closed || !_appDriven) return;
    final active = _speaking || _asking > 0;
    if (!active) return;
    _log(
      voiceTurnLine('interrupted', {
        'by': 'person',
        'speaking': _speaking,
        'asking': _asking,
      }),
    );
    stopSpeech();
    final agent = _agent;
    if (_asks.isNotEmpty && agent is CancellableTurn) {
      (agent as CancellableTurn).cancelTurn();
    }
    _words.clear();
    while (_asks.isNotEmpty) {
      _asks.removeFirst().done.completeError(const _Cancelled());
    }
    onInterrupted?.call();
  }

  @override
  void sendAudio(Uint8List pcm16k) {
    if (listen) _live!.sendAudio(pcm16k);
  }

  @override
  void endAudio() {
    if (listen) _live!.endAudio();
  }

  /// Typed text is the person's: with Live relaying it hears it as if it were
  /// said; when the app speaks it is a turn like a heard one. A note from the
  /// app is for the agent; what it answers is spoken.
  @override
  void sendText(String text) {
    if (_closed) return;
    if (!text.startsWith(_appNote)) {
      if (_appDriven) {
        _bargeIn();
        _forward(text, heard: false);
      } else {
        _userSpeechStopped();
        _live!.sendText(text);
      }
      return;
    }
    unawaited(
      _runAgent(text).then((say) {
        if (_closed || say.isEmpty) return;
        if (_appDriven) {
          unawaited(_sayOut(say, info: _confirmInfo(say)));
        } else {
          _live!.sendText(layeredVerbatim(say));
        }
      }, onError: (Object _) {}),
    );
  }

  /// Context belongs to the agent; the voice layer is not told.
  @override
  void addContext(String text) => _agent.addContext(text);

  /// The app's own words, word for word; the agent knows they were said.
  @override
  void speak(String text) {
    if (_closed || text.isEmpty) return;
    _agent.addContext('（App 已经替你对用户说了：“$text”）');
    if (_appDriven) {
      unawaited(_sayOut(text));
    } else {
      _live!.sendText(layeredVerbatim(text));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _forwarder.dispose();
    _echoTail?.cancel();
    _watchTimer?.cancel();
    stopSpeech();
    _askingIs(0);
    _agentClosed('closed');
    await Future.wait([if (listen) _live!.close(), _agent.close()]);
  }
}

/// A confirmation line given to Live to say, and what it said of it.
class _Watch {
  _Watch(this.say, this.info);
  final String say;
  final KeyInfo info;
  final heard = StringBuffer();
  bool waiting = false;
  bool extended = false;
}

/// An ask the person spoke over.
class _Cancelled implements Exception {
  const _Cancelled();
}

/// A turn handed to the agent, and the words of its answer that stream.
class _Ask {
  _Ask(this.draft);
  final done = Completer<String>();
  final _Draft? draft;
}

/// The sentences of the agent's answer as its words stream in: each complete
/// sentence is handed to [speak] at once (the last, unfinished one waits).
class _Draft {
  _Draft(this.speak);

  /// What a sentence ends with (and the quotes and brackets that close with
  /// it).
  static const _stops = '。！？!?；;….”’」』）)"\'';
  final void Function(String sentence) speak;

  /// The sentences handed to the voice so far, in order.
  final handed = <String>[];
  final _text = StringBuffer();

  void add(String delta) {
    _text.write(delta);
    // A language line of the prompt that the model repeats is not an answer.
    final text = AgentLanguage.scrub('$_text');
    final sentences = orbSentences(text);
    // The last one is complete only if the text ends with its stop.
    final last = text.trimRight();
    final done = last.isNotEmpty && _stops.contains(last[last.length - 1])
        ? sentences.length
        : sentences.length - 1;
    while (handed.length < done) {
      final sentence = sentences[handed.length];
      handed.add(sentence);
      speak(sentence);
    }
  }
}

/// What the voice layer's session is built from.
class LiveParts {
  const LiveParts({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    required this.voice,
    required this.reasoning,
    this.provider = AgentVoiceProvider.gemini,
    this.relay = false,
    this.liveModel,
    this.languageCode,
    this.language = AgentLanguage.zh,
    this.playbackPending,
    this.listenOnly = false,
    this.onGenerating,
    this.onAudio,
    this.onInputText,
    this.onInputDone,
    this.onTiming,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onSpeechStarted,
    this.onSpeechStopped,
    this.onClosed,
  });

  final String apiKey, systemPrompt, voice;

  /// The voice service. OpenAI and Grok are always relay voices (`relay`):
  /// they listen and say what the app asks, with no tools of their own.
  final AgentVoiceProvider provider;
  final bool relay;

  /// Live only listens (see `GeminiLiveSession.listenOnly`).
  final bool listenOnly;
  final void Function()? onGenerating;
  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;
  final AgentReasoning reasoning;

  /// The model the person chose for the voice service; null lets the app
  /// pick.
  final String? liveModel;

  /// The language of the voice (see `GeminiLiveSession.languageCode`).
  final String? languageCode;

  /// The language the voice is pinned to (a relay voice's own prompts).
  final AgentLanguage language;
  final Future<Duration> Function()? playbackPending;
  final void Function(Uint8List pcm24k)? onAudio;
  final void Function(String text)? onInputText;

  /// The transcript of one thing the person said is complete (a relay voice).
  final void Function()? onInputDone;

  /// Where the time goes (see `OpenAiRealtimeSession.onTiming`).
  final void Function(String segment, int ms)? onTiming;
  final void Function(String text)? onOutputText;
  final void Function()? onTurnComplete;
  final void Function()? onInterrupted;

  /// The person began, or stopped, speaking (a relay voice).
  final void Function()? onSpeechStarted;
  final void Function()? onSpeechStopped;
  final void Function(String reason)? onClosed;
}

/// What the agent's session is built from.
class AgentParts {
  const AgentParts({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.steering,
    required this.thinking,
    required this.engine,
    this.model,
    required this.onToolCall,
    required this.onOutputText,
    this.onDraft,
    required this.onTurnComplete,
    required this.onClosed,
  });

  final String apiKey, systemPrompt;
  final List<Map<String, Object?>> tools;
  final AgentSteering steering;
  final AgentThinking thinking;
  final AgentEngine engine;
  final String? model;
  final AgentToolHandler onToolCall;
  final void Function(String text) onOutputText;

  /// Words of the answer as they stream, a draft of [onOutputText]'s.
  final void Function(String delta)? onDraft;
  final void Function() onTurnComplete;
  final void Function(String reason) onClosed;
}

/// The factory of the layered voice: the same arguments as
/// [createVoiceSession]. [provider] is the voice service of the voice layer
/// (Gemini Live, OpenAI Realtime or Grok Voice); [apiKey] is its key. The
/// text agent is a Gemini model whichever it is: with another voice service
/// its key is the stored Gemini key (read before the session is made).
VoiceSession createLayeredSession({
  required AgentVoiceProvider provider,
  required String apiKey,
  required String systemPrompt,
  required List<Map<String, Object?>> tools,
  required AgentToolHandler onToolCall,
  required String voice,
  AgentReasoning reasoning = AgentReasoning.low,
  void Function(Uint8List pcm24k)? onAudio,
  void Function(String text)? onInputText,
  void Function(String text)? onOutputText,
  void Function()? onTurnComplete,
  void Function()? onInterrupted,
  void Function(String reason)? onClosed,
  Future<Duration> Function()? playbackPending,
  AgentSteering? steering,
}) {
  final settings = AgentVoiceSettings.instance;
  final language = settings.language;
  return LayeredVoiceSession(
    voiceProvider: provider,
    // Live relays unless the person chose the app's own voice (and the
    // platform has one). OpenAI and Grok say the lines of the app with their
    // own voice in the same setting.
    mode: appSpeechSupported
        ? AgentOrbPreference.instance.layeredVoiceMode
        : LayeredVoiceMode.liveRelays,
    // Also while the voice relays: the line that asks to confirm a card is
    // said by the app when the voice's words for it miss something.
    speech: appSpeechSupported
        ? FlutterTtsSpeech(language: language.ttsCode)
        : null,
    apiKey: apiKey,
    agentApiKey: provider == AgentVoiceProvider.gemini
        ? null
        : AgentVoiceKey.instance.loaded,
    playbackPending: playbackPending,
    systemPrompt: systemPrompt,
    tools: tools,
    onToolCall: onToolCall,
    steering: steering!,
    // Read now: a change of the setting reaches the next session.
    thinking: AgentOrbPreference.instance.agentThinking,
    engine: AgentOrbPreference.instance.agentEngine,
    agentModelId: AgentOrbPreference.instance.agentModel,
    voice: voice,
    reasoning: reasoning,
    liveModel: settings.realtimeModelOf(provider),
    language: language,
    onAudio: onAudio,
    onInputText: onInputText,
    onOutputText: onOutputText,
    onTurnComplete: onTurnComplete,
    onInterrupted: onInterrupted,
    onClosed: onClosed,
  );
}
