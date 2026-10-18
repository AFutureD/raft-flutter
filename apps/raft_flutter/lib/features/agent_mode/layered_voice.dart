import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'agent_engine.dart';
import 'agent_steering.dart';
import 'agent_thinking.dart';
import 'agent_voice_settings.dart' show AgentVoiceSettings;
import '../agent_orb/orb_preference.dart' show AgentOrbPreference;
import 'app_speech.dart';
import 'gemini_agent.dart';
import 'genkit_agent.dart';
import 'gemini_live.dart';
import 'key_info.dart';
import 'layered_listen.dart';
import 'layered_voice_mode.dart';
import 'voice_provider.dart';

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

/// [text] as the voice model is given it to say. A number written "#136"
/// often ends Live's answer right there, so it reads "136": the same number
/// to the ear.
String layeredForVoice(String text) =>
    text.replaceAllMapped(RegExp(r'#(\d)'), (m) => m[1]!);

/// The instruction of the voice layer: it listens and speaks, and gives
/// everything about Raft to `ask_agent`.
const layeredVoicePrompt =
    '你是用户在 Raft 里的语音助手，以一个悬浮球的形态待在 App 里。你只负责听和说：所有和 Raft 有关的事，都交给 ask_agent。\n'
    '\n'
    '【交给 Agent】用户说的任何和 Raft、App、消息、任务、频道、简报、驾驶模式有关的话——读、查、去哪里、回复、改、"下一件"，'
    '包括只说"确认""好""取消""算了"——都调用 ask_agent，request 填他的原话，不要改写，不要自己回答，不要自己判断做没做。\n'
    '\n'
    '【说出来】ask_agent 返回 say 之后，把 say 的意思如实、自然地说给用户，像朋友说话那样：'
    '人名、数字、要做的事、要他确认的问题都要说到，不要漏，也不要加 say 里没有的信息；措辞可以口语一点，不用逐字照念。say 是空的就不说话。\n'
    '\n'
    '【不要先说话】调用 ask_agent 之前、等它的时候，都不要说任何话，一个字也不要说：马上调用。等的时候 App 自己会提示用户。'
    '你只说 ask_agent 返回的 say。\n'
    '\n'
    '【App 请你说】收到以“（App 请你说）”开头的话，把后面的意思如实、自然地说给用户，不要加别的信息，不要调用工具。\n'
    '\n'
    '【闲聊】打招呼、问你是谁、谢谢这类和 Raft 无关的话，自己用一两句简短回答，不调用工具。\n'
    '\n'
    '【没听清就问】如果转写出来的话乱码、几种语言混在一起、被截断，不要猜着回答；用他的语言简短说一句没听清，请他再说一遍。这样的话不要调用 ask_agent。\n'
    '\n'
    '【语言】用户说什么语言就用什么语言回答，说中文用自然的口语中文，默认中文；“Agent”这个词任何语言里都照写 Agent。温暖、简短，像很熟的朋友。';

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
    this.mode = LayeredVoiceMode.liveRelays,
    this.speech,
    this.listen = true,
    this.confirmGrace = const Duration(milliseconds: 700),
    this.confirmWait = const Duration(seconds: 3),
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
    VoiceSession Function(LiveParts parts)? liveBuilder,
    VoiceSession Function(AgentParts parts)? agentBuilder,
  }) : _liveBuilder = liveBuilder ?? geminiLive,
       _agentBuilder = agentBuilder ?? _agentGemini {
    final speaks = mode == LayeredVoiceMode.appSpeaks;
    if (speaks && speech == null) {
      throw ArgumentError('appSpeaks needs a speech');
    }
    _forwarder = UserTurnForwarder(
      forward: _forward,
      onChunk: onInputText,
      onBargeIn: _bargeIn,
      guarding: () => _speaking || (_echoTail?.isActive ?? false),
      echoOf: _echoOf,
    );
    _live = !listen
        ? null
        : _liveBuilder(
            speaks
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
                    systemPrompt: layeredVoicePrompt,
                    tools: const [askAgentDeclaration],
                    onToolCall: _liveTool,
                    voice: voice,
                    reasoning: reasoning,
                    liveModel: liveModel,
                    onAudio: _relayAudio,
                    onInputText: onInputText,
                    onOutputText: _relayOutput,
                    onTurnComplete: _relayTurnComplete,
                    onInterrupted: _relayInterrupted,
                    onClosed: onClosed,
                  ),
          );
    _agent = _makeAgent();
  }

  @visibleForTesting
  static VoiceSession geminiLive(LiveParts p) => GeminiLiveSession(
    apiKey: p.apiKey,
    voice: p.voice,
    reasoning: p.reasoning,
    preferredModel: p.liveModel,
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
      onTurnComplete: p.onTurnComplete,
      onClosed: p.onClosed,
    ),
  };

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
  final _asks = Queue<Completer<String>>();
  final _words = StringBuffer();

  VoiceSession _makeAgent() => _agentBuilder(
    AgentParts(
      apiKey: apiKey,
      systemPrompt: systemPrompt,
      tools: tools,
      steering: steering,
      thinking: thinking,
      engine: engine,
      model: agentModelId,
      onToolCall: onToolCall,
      onOutputText: _words.write,
      onTurnComplete: _agentFinished,
      onClosed: _agentClosed,
    ),
  );

  void _agentFinished() {
    final text = '$_words'.trim();
    _words.clear();
    if (_asks.isNotEmpty) _asks.removeFirst().complete(text);
  }

  void _agentClosed(String reason) {
    if (kDebugMode) debugPrint('layered agent closed: $reason');
    _words.clear();
    while (_asks.isNotEmpty) {
      _asks.removeFirst().completeError(StateError('agent closed'));
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
  Future<String> _runAgent(String text) async {
    if (!_agent.connected) await _revive();
    final done = Completer<String>();
    _asks.add(done);
    _agent.sendText(text);
    return done.future;
  }

  /// One ask to the agent: what it says, and how long it took; null when the
  /// person spoke over it and it was cut short.
  Future<String?> _ask(String request) async {
    final watch = Stopwatch()..start();
    _askingIs(_asking + 1);
    var acked = false;
    final ack = Timer(ackAfter, () {
      acked = _acknowledge();
    });
    final slow = Timer(slowAfter, () {
      if (!acked) onSlow?.call();
    });
    String? say;
    try {
      say = await _runAgent(request);
    } on _Cancelled {
      say = null;
    } catch (_) {
      say = '我这边出了点问题，你再说一次。';
    } finally {
      ack.cancel();
      slow.cancel();
    }
    if (say != null) onAsk?.call(request, say, watch.elapsedMilliseconds);
    // Out of flight as the answer goes on, to Live or to the voice: the turn
    // is not over before it has it.
    if (!_closed) _askingIs(_asking - 1);
    return say;
  }

  Future<Map<String, Object?>> _liveTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (name != 'ask_agent') return {'error': '没有这个工具：$name'};
    final request = '${args['request'] ?? ''}'.trim();
    if (request.isEmpty) return {'say': ''};
    final say = await _ask(request) ?? '';
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

  void _relayOutput(String text) {
    _endAck();
    _watch?.heard.write(text);
    onOutputText?.call(text);
  }

  void _relayAudio(Uint8List pcm24k) {
    _endAck();
    onAudio?.call(pcm24k);
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
    final generation = _speechGeneration;
    for (final sentence in orbSentences(say)) {
      if (_closed || generation != _speechGeneration) return;
      onSpoken?.call(sentence);
      await voice.speak(sentence, onStart: () => _speakingIs(true));
    }
    _speakingIs(false);
  }

  // ---- the app speaks -----------------------------------------------------

  /// The person's turn is over: the agent is asked, and the answer is said.
  /// The same whether the words were heard (the transcript) or typed.
  void _forward(String text) {
    if (_closed || text.trim().isEmpty) return;
    _recentSpoken = '';
    unawaited(_answer(text));
  }

  Future<void> _answer(String request) async {
    final say = await _ask(request);
    if (say == null || _closed) return;
    await _sayOut(say);
  }

  /// Live generated something while it only listens: dropped, but logged.
  void _ignored(String text) {
    if (kDebugMode) {
      debugPrint('layered live output ignored (${text.length} chars)');
    }
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

  /// Says [say] a sentence at a time, after what is being said. When it is
  /// over (or there is nothing to say) the turn is over.
  Future<void> _sayOut(String say) {
    final generation = _speechGeneration;
    return _speechTail = _speechTail.then((_) => _sayNow(say, generation));
  }

  Future<void> _sayNow(String say, int generation) async {
    if (_closed || generation != _speechGeneration) return;
    final sentences = orbSentences(say);
    for (final sentence in sentences) {
      if (_closed || generation != _speechGeneration) return;
      _recentSpoken += UserTurnForwarder.compact(sentence);
      onSpoken?.call(sentence);
      await speech!.speak(
        sentence,
        onStart: () {
          if (generation != _speechGeneration) return;
          _speakingIs(true);
          // The caption follows the voice.
          onOutputText?.call(sentence);
        },
      );
    }
    if (_closed || generation != _speechGeneration) return;
    _speakingIs(false);
    onTurnComplete?.call();
  }

  // What the app says while the agent works, in turn.
  static const _acks = ['我看一下。', '好，我查查。', '稍等，我看看。', '嗯，我找一下。'];
  int _ackNext = 0;
  bool _acking = false;

  /// Says one short acknowledgment in the app's voice, queued like any other
  /// speech so that an answer follows it and does not overlap. Not reported to
  /// [onSpoken] or the captions (it is not part of the answer), but it counts
  /// as the voice's echo. Whether it is said: not without a voice, and not
  /// over a voice already sounding.
  bool _acknowledge() {
    if (_closed || speech == null || _speaking) return false;
    final text = _acks[_ackNext++ % _acks.length];
    _recentSpoken += UserTurnForwarder.compact(text);
    _acking = true;
    final generation = _speechGeneration;
    late final Future<void> mine;
    mine = _speechTail = _speechTail.then((_) async {
      if (_closed || generation != _speechGeneration) return;
      await speech!.speak(
        text,
        onStart: () {
          if (generation == _speechGeneration) _speakingIs(true);
        },
      );
      if (_closed || generation != _speechGeneration) return;
      _acking = false;
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
    unawaited(speech?.stop());
  }

  /// The person speaks over the app: the voice stops, and an ask the agent
  /// has not answered yet is cut short (what it was doing stops at its next
  /// step, and nothing of it is said).
  void _bargeIn() {
    if (_closed || !_appSpeaks) return;
    final active = _speaking || _asking > 0;
    if (!active) return;
    stopSpeech();
    final agent = _agent;
    if (_asks.isNotEmpty && agent is CancellableTurn) {
      (agent as CancellableTurn).cancelTurn();
    }
    _words.clear();
    while (_asks.isNotEmpty) {
      _asks.removeFirst().completeError(const _Cancelled());
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
      if (_appSpeaks) {
        _bargeIn();
        _forward(text);
      } else {
        _live!.sendText(text);
      }
      return;
    }
    unawaited(
      _runAgent(text).then((say) {
        if (_closed || say.isEmpty) return;
        if (_appSpeaks) {
          unawaited(_sayOut(say));
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
    if (_appSpeaks) {
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

/// What the voice layer's session is built from.
class LiveParts {
  const LiveParts({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    required this.voice,
    required this.reasoning,
    this.liveModel,
    this.listenOnly = false,
    this.onGenerating,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
  });

  final String apiKey, systemPrompt, voice;

  /// Live only listens (see `GeminiLiveSession.listenOnly`).
  final bool listenOnly;
  final void Function()? onGenerating;
  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;
  final AgentReasoning reasoning;

  /// The Live model the person chose; null lets the app pick.
  final String? liveModel;
  final void Function(Uint8List pcm24k)? onAudio;
  final void Function(String text)? onInputText;
  final void Function(String text)? onOutputText;
  final void Function()? onTurnComplete;
  final void Function()? onInterrupted;
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
  final void Function() onTurnComplete;
  final void Function(String reason) onClosed;
}

/// The factory of the layered voice: the same arguments as
/// [createVoiceSession]; the provider is Gemini whatever the settings say
/// (the agent is a Gemini model).
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
}) => LayeredVoiceSession(
  // Live relays unless the person chose the app's own voice (and the platform
  // has one).
  mode: appSpeechSupported
      ? AgentOrbPreference.instance.layeredVoiceMode
      : LayeredVoiceMode.liveRelays,
  // Also while Live relays: the line that asks to confirm a card is said by
  // the app when Live's words for it miss something.
  speech: appSpeechSupported ? FlutterTtsSpeech() : null,
  apiKey: apiKey,
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
  liveModel: AgentVoiceSettings.instance.liveModel,
  onAudio: onAudio,
  onInputText: onInputText,
  onOutputText: onOutputText,
  onTurnComplete: onTurnComplete,
  onInterrupted: onInterrupted,
  onClosed: onClosed,
);
