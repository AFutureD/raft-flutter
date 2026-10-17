import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'agent_steering.dart';
import 'agent_thinking.dart';
import '../agent_orb/orb_preference.dart' show AgentOrbPreference;
import 'gemini_agent.dart';
import 'gemini_live.dart';
import 'voice_provider.dart';

/// The one tool of the voice layer.
const askAgentDeclaration = <String, Object?>{
  'name': 'ask_agent',
  'description':
      '把用户的话交给 Agent，由它去 Raft 里读、去页面、回复、改任务、驾驶模式。request 填用户的原话。'
      '返回 say：就是要对用户说的话，一字不差地说出来。say 是空的就不说话。',
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

/// What the voice model is asked to say word for word.
String layeredVerbatim(String text) => '（App 请你说）$text';

/// The instruction of the voice layer: it listens and speaks, and gives
/// everything about Raft to `ask_agent`.
const layeredVoicePrompt =
    '你是用户在 Raft 里的语音助手，以一个悬浮球的形态待在 App 里。你只负责听和说：所有和 Raft 有关的事，都交给 ask_agent。\n'
    '\n'
    '【交给 Agent】用户说的任何和 Raft、App、消息、任务、频道、简报、驾驶模式有关的话——读、查、去哪里、回复、改、"下一件"，'
    '包括只说"确认""好""取消""算了"——都调用 ask_agent，request 填他的原话，不要改写，不要自己回答，不要自己判断做没做。\n'
    '\n'
    '【说出来】ask_agent 返回 say 之后，一字不差地把 say 说出来：不加、不删、不解释、不换说法。say 是空的就不说话。\n'
    '\n'
    '【等的时候】要读或要去哪里的事，调用之前可以先说一句很短的“我看一下”；用户只是答“确认”“好”“取消”时不要说，直接调用。'
    '一次只说这一句。\n'
    '\n'
    '【App 请你说】收到以“（App 请你说）”开头的话，一字不差地说出后面的话，什么都不要加，不要调用工具。\n'
    '\n'
    '【闲聊】打招呼、问你是谁、谢谢这类和 Raft 无关的话，自己用一两句简短回答，不调用工具。\n'
    '\n'
    '【没听清就问】如果转写出来的话乱码、几种语言混在一起、被截断，不要猜着回答；用他的语言简短说一句没听清，请他再说一遍。这样的话不要调用 ask_agent。\n'
    '\n'
    '【语言】用户说什么语言就用什么语言回答，说中文用自然的口语中文，默认中文；“Agent”这个词任何语言里都照写 Agent。温暖、简短，像很熟的朋友。';

/// The agent layer behind a voice: a Gemini Live session that only listens and
/// speaks, and a [GeminiAgentSession] that does the work.
///
/// Live has one tool, `ask_agent`; what it is asked is run as one turn of the
/// agent (all its tools, its state-scoped instruction and the app's rules) and
/// the words come back as `say` for Live to speak. Nothing the agent says
/// reaches the person except through Live. The app's silent context goes to
/// the agent, not to Live; a note from the app is a turn of the agent whose
/// answer Live speaks; [speak] has Live say the app's own words.
class LayeredVoiceSession implements VoiceSession, AppSpeaker {
  LayeredVoiceSession({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    required this.steering,
    this.thinking = AgentThinking.low,
    this.voice = 'Sulafat',
    this.reasoning = AgentReasoning.low,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
    VoiceSession Function(LiveParts parts)? liveBuilder,
    GeminiAgentSession Function(AgentParts parts)? agentBuilder,
  }) : _liveBuilder = liveBuilder ?? _gemini,
       _agentBuilder = agentBuilder ?? _agentGemini {
    _live = _liveBuilder(
      LiveParts(
        apiKey: apiKey,
        systemPrompt: layeredVoicePrompt,
        tools: const [askAgentDeclaration],
        onToolCall: _liveTool,
        voice: voice,
        reasoning: reasoning,
        onAudio: onAudio,
        onInputText: onInputText,
        onOutputText: onOutputText,
        onTurnComplete: onTurnComplete,
        onInterrupted: onInterrupted,
        onClosed: onClosed,
      ),
    );
    _agent = _makeAgent();
  }

  static VoiceSession _gemini(LiveParts p) => GeminiLiveSession(
    apiKey: p.apiKey,
    voice: p.voice,
    reasoning: p.reasoning,
    systemPrompt: p.systemPrompt,
    tools: p.tools,
    onToolCall: p.onToolCall,
    onAudio: p.onAudio,
    onInputText: p.onInputText,
    onOutputText: p.onOutputText,
    onTurnComplete: p.onTurnComplete,
    onInterrupted: p.onInterrupted,
    onClosed: p.onClosed,
  );

  static GeminiAgentSession _agentGemini(AgentParts p) => GeminiAgentSession(
    apiKey: p.apiKey,
    systemPrompt: p.systemPrompt,
    tools: p.tools,
    steering: p.steering,
    thinking: p.thinking,
    onToolCall: p.onToolCall,
    onOutputText: p.onOutputText,
    onTurnComplete: p.onTurnComplete,
    onClosed: p.onClosed,
  );

  final String apiKey;

  /// The agent's, when it has no steering to give another.
  final String systemPrompt;
  final List<Map<String, Object?>> tools;

  /// The app's tools: the agent's, never Live's.
  @override
  final AgentToolHandler onToolCall;
  final AgentSteering steering;

  /// How hard the agent behind the voice thinks.
  final AgentThinking thinking;
  final String voice;
  final AgentReasoning reasoning;
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
  final GeminiAgentSession Function(AgentParts) _agentBuilder;
  late final VoiceSession _live;
  late GeminiAgentSession _agent;
  bool _closed = false;

  /// The turns the agent has been given and not yet finished, oldest first.
  final _asks = Queue<Completer<String>>();
  final _words = StringBuffer();

  GeminiAgentSession _makeAgent() => _agentBuilder(
    AgentParts(
      apiKey: apiKey,
      systemPrompt: systemPrompt,
      tools: tools,
      steering: steering,
      thinking: thinking,
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
  bool get connected => _live.connected && _agent.connected;

  @override
  String? get model => _live.model;

  @override
  Future<void> connect() async {
    await Future.wait([_live.connect(), _agent.connect()]);
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

  Future<Map<String, Object?>> _liveTool(
    String name,
    Map<String, Object?> args,
  ) async {
    if (name != 'ask_agent') return {'error': '没有这个工具：$name'};
    final request = '${args['request'] ?? ''}'.trim();
    if (request.isEmpty) return {'say': ''};
    try {
      final say = await _runAgent(request);
      return {'say': say};
    } catch (_) {
      return {'say': '我这边出了点问题，你再说一次。'};
    }
  }

  @override
  void sendAudio(Uint8List pcm16k) => _live.sendAudio(pcm16k);

  @override
  void endAudio() => _live.endAudio();

  /// Typed text is the person's: Live hears it as if it were said. A note
  /// from the app is for the agent; what it answers is spoken.
  @override
  void sendText(String text) {
    if (_closed) return;
    if (!text.startsWith(_appNote)) {
      _live.sendText(text);
      return;
    }
    unawaited(
      _runAgent(text).then((say) {
        if (!_closed && say.isNotEmpty) _live.sendText(layeredVerbatim(say));
      }, onError: (Object _) {}),
    );
  }

  /// Context belongs to the agent; the voice layer is not told.
  @override
  void addContext(String text) => _agent.addContext(text);

  /// Live says [text] word for word; the agent knows it was said.
  @override
  void speak(String text) {
    if (_closed || text.isEmpty) return;
    _agent.addContext('（App 已经替你对用户说了：“$text”）');
    _live.sendText(layeredVerbatim(text));
  }

  @override
  Future<void> close() async {
    _closed = true;
    _agentClosed('closed');
    await Future.wait([_live.close(), _agent.close()]);
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
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
  });

  final String apiKey, systemPrompt, voice;
  final List<Map<String, Object?>> tools;
  final AgentToolHandler onToolCall;
  final AgentReasoning reasoning;
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
    required this.onToolCall,
    required this.onOutputText,
    required this.onTurnComplete,
    required this.onClosed,
  });

  final String apiKey, systemPrompt;
  final List<Map<String, Object?>> tools;
  final AgentSteering steering;
  final AgentThinking thinking;
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
  apiKey: apiKey,
  systemPrompt: systemPrompt,
  tools: tools,
  onToolCall: onToolCall,
  steering: steering!,
  // Read now: a change of the setting reaches the next session.
  thinking: AgentOrbPreference.instance.agentThinking,
  voice: voice,
  reasoning: reasoning,
  onAudio: onAudio,
  onInputText: onInputText,
  onOutputText: onOutputText,
  onTurnComplete: onTurnComplete,
  onInterrupted: onInterrupted,
  onClosed: onClosed,
);
