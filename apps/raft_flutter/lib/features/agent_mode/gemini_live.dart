import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_tool_output.dart';
import 'voice_provider.dart';
import 'voice_turn_log.dart';

/// A tool the model may call: [declaration] is a Gemini FunctionDeclaration.
typedef AgentToolHandler = Future<Map<String, Object?>> Function(
  String name,
  Map<String, Object?> args,
);

/// One Gemini Live session over WebSocket: streams microphone audio in and
/// receives speech, transcripts and tool calls.
///
/// Uses automatic voice activity detection. Push-to-talk sends audio only while
/// held and then [endAudio]; live mode keeps sending.
class GeminiLiveSession implements VoiceSession {
  GeminiLiveSession({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.voice = 'Sulafat',
    this.reasoning = AgentReasoning.low,
    this.fast = false,
    this.preferredModel,
    this.languageCode,
    this.listenOnly = false,
    this.onGenerating,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
    VoiceLog? log,
  }) : _log = log ?? printVoiceLog;

  /// Where the `voice-turn` lines go.
  final VoiceLog _log;

  /// How hard the model thinks (`thinkingConfig.thinkingLevel`). Gemini Live
  /// models accept `low`, `medium` and `high` (3.1 Flash Live also `minimal`;
  /// the plain 3.8 Live takes none at all). A model that refuses the level
  /// gets the next lower one, and none when `low` is refused too.
  /// https://ai.google.dev/gemini-api/docs/live-api/capabilities
  final AgentReasoning reasoning;
  late AgentReasoning? _level = reasoning;

  /// The level after a refusal of [level]: the next one down, then none.
  static AgentReasoning? lowerThinking(AgentReasoning level) => switch (level) {
    AgentReasoning.high => AgentReasoning.medium,
    AgentReasoning.medium => AgentReasoning.low,
    AgentReasoning.low => null,
  };

  /// What a relaying ([fast]) session asks for, the least first, whatever the
  /// voice settings say: the minimal level, then low, then no thinking budget,
  /// then no setting at all. A model that refuses one gets the next.
  static const relayThinking = <Map<String, Object?>?>[
    {'thinkingLevel': 'minimal'},
    {'thinkingLevel': 'low'},
    {'thinkingBudget': 0},
    null,
  ];
  int _relayStep = 0;

  Map<String, Object?>? get _thinkingConfig => fast
      ? relayThinking[_relayStep]
      : (_level == null ? null : {'thinkingLevel': _level!.name});

  /// The thinking this session asks for now, as a word for a report.
  String get thinkingUsed {
    final c = _thinkingConfig;
    if (c == null) return 'none';
    return c['thinkingLevel'] as String? ?? 'budget ${c['thinkingBudget']}';
  }

  /// The model refused the thinking setting: the next lower one. False when
  /// there is none lower.
  @visibleForTesting
  bool lowerThinkingSetting() {
    if (fast) {
      if (_relayStep >= relayThinking.length - 1) return false;
      _relayStep++;
      _setup.relayStep = _relayStep;
      return true;
    }
    if (_level == null) return false;
    _level = lowerThinking(_level!);
    _setup
      ..levelKnown = true
      ..levelCeiling = _level;
    return true;
  }

  /// What the model [model] refused at setup before, by model (and the kind
  /// of session), for the life of the app: the next session sends the setup
  /// that was accepted first, instead of walking the refusals again (three
  /// failed setups, 4-5 s, every session on gemini-3.8-live). Written when a
  /// setup succeeds; a model not seen before starts with everything.
  static final _remembered = <String, SetupMemory>{};

  static String _memoryKey(String model, bool fast, bool listenOnly) =>
      '${_bare(model)}|${fast ? 'fast' : 'full'}|'
      '${listenOnly ? 'listen' : 'talk'}';

  /// Forgets the refusals remembered so far (tests).
  @visibleForTesting
  static void forgetSetups() => _remembered.clear();

  /// What is remembered of [model], or null.
  @visibleForTesting
  static SetupMemory? rememberedSetup(
    String model, {
    bool fast = false,
    bool listenOnly = false,
  }) => _remembered[_memoryKey(model, fast, listenOnly)];

  /// This session's working copy: what is remembered of its model, plus what
  /// it has found out since. Only a setup that succeeds writes it back, so a
  /// failed network never makes the app forget a feature for good.
  SetupMemory _setup = SetupMemory();

  /// The features this session sends now.
  SetupMemory get setupFlags => _setup;

  /// Starts from what is remembered of [model]: the features it refused, and
  /// no more thinking than it accepted.
  @visibleForTesting
  void useModel(String model) {
    _used = model;
    final known = _remembered[_memoryKey(model, fast, listenOnly)];
    _setup = known?.copy() ?? SetupMemory();
    if (fast) {
      if (_setup.relayStep > _relayStep) _relayStep = _setup.relayStep;
    } else if (_setup.levelKnown) {
      _level = _capped(_level, _setup.levelCeiling);
    }
  }

  /// The lower of [wanted] and [ceiling] (null: none at all).
  static AgentReasoning? _capped(AgentReasoning? wanted, AgentReasoning? top) =>
      wanted == null || top == null
      ? null
      : (wanted.index <= top.index ? wanted : top);

  /// The setup worked: remember what it took.
  @visibleForTesting
  void rememberSetup() {
    final model = _used;
    if (model == null) return;
    _remembered[_memoryKey(model, fast, listenOnly)] = _setup.copy();
  }

  static const _host = 'generativelanguage.googleapis.com';
  static String _path(String version) =>
      '/ws/google.ai.generativelanguage.$version.GenerativeService.BidiGenerateContent';

  // Optional setup features, each dropped after the model refuses it (see
  // [SetupMemory]): affective dialog (tone follows the person's tone) needs
  // the v1alpha endpoint and a model that supports it; functions declared
  // `NON_BLOCKING` let the model keep talking while a screen is composed (a
  // model that refuses them gets blocking functions, answered just as fast);
  // a listening session asks for text instead of audio.

  /// The tokens of context at which the session starts dropping its oldest
  /// turns, and what it keeps (`ContextWindowCompressionConfig.triggerTokens`
  /// and `SlidingWindow.targetTokens` of the Live API). The whole context is
  /// billed again at every turn, so it must not grow towards the model's
  /// limit (the default trigger is 80% of it). The system instruction stays
  /// at the start whatever is dropped; the setup is about 20k tokens (the
  /// instruction and the function declarations), so the target leaves a
  /// room for the conversation above it. What the model must still know of
  /// the dropped turns is in the 【回合】 line the app sends with each turn.
  static const compressionTriggerTokens = 40000;
  static const compressionTargetTokens = 30000;

  /// The `contextWindowCompression` of the setup message.
  static Map<String, Object?> contextCompression() => {
    'triggerTokens': compressionTriggerTokens,
    'slidingWindow': {'targetTokens': compressionTargetTokens},
  };

  /// Whether this session declared its UI functions non-blocking.
  bool get nonBlocking => _declaredNonBlocking;
  bool _declaredNonBlocking = false;

  /// The function declarations as sent: [tools] as they are while
  /// [nonBlocking], else without `behavior` (every function blocks).
  static List<Map<String, Object?>> declarations(
    List<Map<String, Object?>> tools, {
    required bool nonBlocking,
  }) => [
    for (final t in tools)
      if (nonBlocking) t else {...t}..remove('behavior'),
  ];

  /// The names declared non-blocking in [tools].
  static Set<String> nonBlockingNames(List<Map<String, Object?>> tools) => {
    for (final t in tools)
      if (t['behavior'] == 'NON_BLOCKING') '${t['name']}',
  };

  /// The response of a non-blocking function. A success is absorbed quietly
  /// (`SILENT`: the model goes on with what it was saying); an error is
  /// told when the model is next idle (`WHEN_IDLE`), never by interrupting.
  static Map<String, Object?> quietResponse(Map<String, Object?> result) => {
    ...result,
    'scheduling': result['error'] != null ? 'WHEN_IDLE' : 'SILENT',
  };

  final String apiKey;
  final String systemPrompt;
  final List<Map<String, Object?>> tools;
  @override
  final AgentToolHandler onToolCall;
  final String voice;
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

  /// The server closed the session.
  @override
  final void Function(String reason)? onClosed;

  /// The voice layer only relays: take the quickest Live model, without
  /// extended thinking.
  final bool fast;

  /// The session only listens: it hears and transcribes, and what it
  /// generates is not wanted. It answers in text (no voice, no tools) where
  /// the model allows that, and in audio that is dropped where it does not.
  final bool listenOnly;

  /// Told each time the model produces something (a word, a sound, the end of
  /// its generation): for a session that only listens, the sign that the
  /// person's turn is over.
  final void Function()? onGenerating;

  /// The response modality this session asks for.
  String get responseModality =>
      listenOnly && _setup.textOnly ? 'TEXT' : 'AUDIO';

  /// The Live model the person chose (`models/gemini-3.8-live` or without
  /// the prefix), or null to let the app pick (see [sortModels]). Used when
  /// the key has it; otherwise the automatic pick stands in for it.
  final String? preferredModel;

  /// The language of the voice (`speechConfig.languageCode`, a BCP-47 code
  /// such as `cmn-CN`), or null to leave it to the model. Not every Live model
  /// takes it (the native-audio ones choose the language themselves): a model
  /// that refuses it has it dropped and is remembered ([SetupMemory]).
  final String? languageCode;

  /// Models picked so far, by [_pickKey]: the choice is part of the key, so a
  /// changed setting never gets the model of the old one.
  static final _picked = <String, String>{};
  static final _missing = <String, String>{};
  static String _pickKey(String? wanted, bool fast) =>
      '${fast ? 'fast' : 'full'}|${_bare(wanted ?? '')}';
  String? _used;

  /// A note about the model for a log or a report: the wanted model was not
  /// on the key, so the automatic pick runs instead. Null when all is well.
  String? modelNote;
  WebSocket? _socket;
  String? _resumeHandle;

  @override
  bool get connected => _socket != null;
  @override
  String? get model => _used ?? _picked[_pickKey(preferredModel, fast)];

  /// The automatic pick for this key, once known.
  static String? get pickedModel => _picked[_pickKey(null, false)];

  /// The Live models a person can choose, by model name. The automatic pick
  /// is not in it. Add a model here to offer it.
  static const selectableModels = {
    'models/gemini-3.8-live': 'Gemini 3.8 Live',
    'models/gemini-3.1-flash-live-preview': 'Gemini 3.1 Flash Live',
    // Not affected by the newer models' occasional switch to another voice
    // for a whole reply (Google forum, 2026-10-07), for comparing.
    'models/gemini-2.5-flash-native-audio-latest': 'Gemini 2.5 Flash 原生音频',
  };

  static String _bare(String name) =>
      name.startsWith('models/') ? name.substring(7) : name;

  /// Which model to use of the [available] ones: [wanted] when it is there
  /// (with or without the `models/` prefix), otherwise the automatic pick
  /// ([sortModels]) with [missing] set to what was wanted.
  @visibleForTesting
  static ({String model, String? missing}) selectModel(
    Iterable<String> available, {
    String? wanted,
    bool fast = false,
  }) {
    final want = wanted == null || wanted.isEmpty ? null : wanted;
    if (want != null) {
      for (final m in available) {
        if (_bare(m) == _bare(want)) return (model: m, missing: null);
      }
    }
    return (model: sortModels(available, fast: fast).first, missing: want);
  }

  /// Lists the models of the key that support Live; tests replace it.
  @visibleForTesting
  static Future<List<String>> Function(String key) modelLister = _listModels;

  /// Forgets the models picked so far (tests).
  @visibleForTesting
  static void forgetModels() {
    _picked.clear();
    _missing.clear();
  }

  /// Picks the model of a session for [key] (see [selectModel]).
  @visibleForTesting
  static Future<String> pick(
    String key, {
    bool fast = false,
    String? wanted,
  }) async => (await _pickModel(key, fast: fast, wanted: wanted)).model;

  /// The Live model both voice modes use when the key has it (Kevin,
  /// 2026-10-18: Google's recommended one), in its plain form.
  static const preferredFamily = 'gemini-3.8-live';

  /// The Live models in the order they are preferred: [preferredFamily]
  /// first, then native audio and "live", stable before preview, newest
  /// first. A model with "thinking" in its name is left out when any other is
  /// there: it thinks before each sentence, which costs the voice its pace
  /// (the unnatural voice of the voice-only mode). For a [fast] session (it
  /// only relays) a Flash one comes first after the preferred one.
  static List<String> sortModels(Iterable<String> names, {bool fast = false}) {
    var models = [...names];
    final quick = [
      for (final m in models)
        if (!m.contains('thinking')) m,
    ];
    if (quick.isNotEmpty) models = quick;
    int rank(String name) =>
        (name.contains(preferredFamily) ? 16 : 0) +
        (name.contains('native-audio') || name.contains('live') ? 2 : 0) +
        (name.contains('preview') || name.contains('exp') ? 0 : 1) +
        (fast && name.contains('flash') ? 4 : 0);
    models.sort((a, b) {
      final r = rank(b) - rank(a);
      return r != 0 ? r : b.compareTo(a);
    });
    return models;
  }

  /// Picks the model for this key: [wanted] when it is available, else the
  /// newest one that supports Live sessions. The answer is kept per [wanted].
  static Future<({String model, String? missing})> _pickModel(
    String key, {
    bool fast = false,
    String? wanted,
  }) async {
    final cacheKey = _pickKey(wanted, fast);
    final known = _picked[cacheKey];
    if (known != null) return (model: known, missing: _missing[cacheKey]);
    final models = await modelLister(key);
    final choice = selectModel(models, wanted: wanted, fast: fast);
    _debug(
      'live model ${choice.model}${fast ? ' (relay: fast)' : ''}'
      '${choice.missing == null ? '' : ' (wanted ${choice.missing}, not available)'}',
    );
    _picked[cacheKey] = choice.model;
    final missing = choice.missing;
    if (missing != null) {
      _missing[cacheKey] = missing;
    } else {
      _missing.remove(cacheKey);
    }
    return choice;
  }

  static Future<List<String>> _listModels(String key) async {
    // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the OpenAI voice session's socket.
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.https(_host, '/v1beta/models', {'pageSize': '1000'}),
      );
      request.headers.set('x-goog-api-key', key);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) {
        throw GeminiLiveException(_errorMessage(body, response.statusCode));
      }
      final models = [
        for (final m in (jsonDecode(body)['models'] as List? ?? const []))
          if ((m['supportedGenerationMethods'] as List? ?? const []).contains(
            'bidiGenerateContent',
          ))
            '${m['name']}',
      ];
      if (models.isEmpty) {
        throw const GeminiLiveException('这个 Key 没有可用的实时语音模型');
      }
      return models;
    } finally {
      client.close();
    }
  }

  static String _errorMessage(String body, int status) {
    try {
      return '${jsonDecode(body)['error']['message']}';
    } catch (_) {
      return 'HTTP $status';
    }
  }

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    final hasNonBlocking = nonBlockingNames(tools).isNotEmpty;
    // The model first: what it refused before is not sent again.
    final picked = await _pickModel(apiKey, fast: fast, wanted: preferredModel);
    useModel(picked.model);
    final watch = Stopwatch()..start();
    var tries = 0;
    while (true) {
      tries++;
      final nb = _setup.nonBlocking && hasNonBlocking;
      try {
        await _connect(affective: _setup.affective, nonBlocking: nb);
        rememberSetup();
        _log(
          voiceTurnLine('live-setup', {
            'model': _bare(picked.model),
            'modality': responseModality,
            if (responseModality == 'AUDIO') 'voice': voice,
            'thinking': thinkingUsed,
            if (_sendsLanguage) 'language': languageCode,
            'affective': _setup.affective && !listenOnly,
            'nonBlocking': nb,
            'tries': tries,
            'ms': watch.elapsedMilliseconds,
          }),
        );
        return;
      } catch (e) {
        // ignore: raft_lints/avoid_caught_exception_text -- Matched against the feature names to pick which to drop; clipped into the debug log, never shown.
        final refusal = '$e';
        final dropped = dropRefused(refusal, nonBlocking: nb);
        if (dropped == null) rethrow;
        _log(
          voiceTurnLine('live-setup-refused', {
            'model': _bare(picked.model),
            'dropped': dropped,
            'reason': refusal,
          }),
        );
      }
    }
  }

  /// The model refused its setup with [refusal]: drops the feature it names,
  /// else the next in line, and says which ('thinking' when only the thinking
  /// went a step down). Null when there is nothing left to drop.
  @visibleForTesting
  String? dropRefused(String refusal, {required bool nonBlocking}) {
    bool names(String pattern) =>
        RegExp(pattern, caseSensitive: false).hasMatch(refusal);
    if (names(r'thinking|thought') && lowerThinkingSetting()) {
      return 'thinking(now $thinkingUsed)';
    }
    if (nonBlocking && names(r'behavior|non_?blocking|scheduling')) {
      _setup.nonBlocking = false;
      return 'nonBlocking';
    }
    if (names(r'language') && _sendsLanguage) {
      _setup.languageCode = false;
      return 'languageCode';
    }
    if (names('affective') && _setup.affective) {
      _setup.affective = false;
      return 'affective';
    }
    if (listenOnly && _setup.textOnly) {
      _setup.textOnly = false;
      return 'textOnly';
    }
    // A refusal that names nothing: the newest ask goes first.
    if (_sendsLanguage) {
      _setup.languageCode = false;
      return 'languageCode';
    }
    if (_setup.affective) {
      _setup.affective = false;
      return 'affective';
    }
    if (nonBlocking) {
      _setup.nonBlocking = false;
      return 'nonBlocking';
    }
    return null;
  }

  /// Whether the setup asks for a language now.
  bool get _sendsLanguage =>
      languageCode != null &&
      _setup.languageCode &&
      responseModality == 'AUDIO';

  Future<void> _connect({
    required bool affective,
    required bool nonBlocking,
  }) async {
    _declaredNonBlocking = nonBlocking;
    final picked = await _pickModel(apiKey, fast: fast, wanted: preferredModel);
    final model = picked.model;
    _used = model;
    modelNote = picked.missing == null
        ? null
        : '这个 Key 没有 ${picked.missing}，改用 $model';
    // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the OpenAI voice session's socket.
    final socket = await WebSocket.connect(
      Uri(
        scheme: 'wss',
        host: _host,
        path: _path(affective ? 'v1alpha' : 'v1beta'),
      ).toString(),
      headers: {'x-goog-api-key': apiKey},
    ).timeout(const Duration(seconds: 15));
    final ready = Completer<void>();
    socket.listen(
      (raw) {
        final text = raw is String ? raw : utf8.decode(raw as List<int>);
        final message = jsonDecode(text) as Map<String, dynamic>;
        if (message.containsKey('setupComplete')) {
          if (!ready.isCompleted) ready.complete();
          return;
        }
        _handle(message);
      },
      onDone: () {
        // A socket we replaced or closed ourselves, or one refused during
        // setup (reported to connect), ends quietly.
        final established = ready.isCompleted;
        final remote = _socket == socket;
        if (remote) _socket = null;
        final reason = (socket.closeReason?.isNotEmpty ?? false)
            ? socket.closeReason!
            : '连接已断开（${socket.closeCode ?? '-'}）';
        _debug(
          'socket done code=${socket.closeCode} '
          'reason="${socket.closeReason ?? ''}" lastSent=$_lastSent '
          'sent=${_sentEvents}ev/${_sentBytes}B',
        );
        if (!ready.isCompleted) {
          ready.completeError(GeminiLiveException(reason));
        }
        if (remote && established) onClosed?.call(reason);
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
      },
      cancelOnError: true,
    );
    _socket = socket;
    _send(setupMessage(model, affective: affective, nonBlocking: nonBlocking));
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  /// The first message of the session.
  Map<String, Object?> setupMessage(
    String model, {
    required bool affective,
    required bool nonBlocking,
  }) => {
    'setup': {
      'model': model,
      'generationConfig': {
        'responseModalities': [responseModality],
        // Gemini 3 Live models want a level (low keeps replies quick, and is
        // what is sent unless the person chose another in the voice
        // settings).
        if (_thinkingConfig != null) 'thinkingConfig': _thinkingConfig,
        if (responseModality == 'AUDIO')
          'speechConfig': {
            if (languageCode != null && _setup.languageCode)
              'languageCode': languageCode,
            'voiceConfig': {
              'prebuiltVoiceConfig': {'voiceName': voice},
            },
          },
      },
      'systemInstruction': {
        'parts': [
          {'text': systemPrompt},
        ],
      },
      if (!listenOnly || tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': declarations(
              tools,
              nonBlocking: nonBlocking,
            ),
          },
        ],
      // End the turn soon after the person stops talking.
      'realtimeInputConfig': {
        'automaticActivityDetection': {
          'endOfSpeechSensitivity': 'END_SENSITIVITY_HIGH',
          'silenceDurationMs': 500,
        },
      },
      'inputAudioTranscription': <String, Object?>{},
      if (responseModality == 'AUDIO')
        'outputAudioTranscription': <String, Object?>{},
      'contextWindowCompression': contextCompression(),
      if (affective && !listenOnly) 'enableAffectiveDialog': true,
      'sessionResumption': {'handle': ?_resumeHandle},
    },
  };

  // What was heard and said in this turn, logged once when the turn moves on
  // (the transcripts come in pieces). A session that only listens leaves it
  // to its owner: its own words are thrown away.
  final _heard = StringBuffer();
  final _said = StringBuffer();

  void _logHeard() {
    if (_heard.isEmpty) return;
    final text = '$_heard'.trim();
    _heard.clear();
    if (text.isNotEmpty) {
      _log(voiceTurnLine('user', {'src': 'voice', 'text': text}));
    }
  }

  void _logSaid({bool cut = false}) {
    if (_said.isEmpty) return;
    final text = '$_said'.trim();
    _said.clear();
    if (text.isEmpty) return;
    _log(
      voiceTurnLine('speak', {
        'who': 'live',
        'voice': voice,
        'text': text,
        'cut': cut ? true : null,
      }),
    );
  }

  /// A server message, as if it had come over the socket (tests).
  @visibleForTesting
  void handleMessage(Map<String, dynamic> message) => _handle(message);

  void _handle(Map<String, dynamic> message) {
    final content = message['serverContent'] as Map<String, dynamic>?;
    if (content != null) {
      if (content['interrupted'] == true) {
        if (!listenOnly) {
          _logHeard();
          _logSaid(cut: true);
          _log(voiceTurnLine('interrupted', {'by': 'person', 'who': 'live'}));
        }
        onInterrupted?.call();
      }
      final input = content['inputTranscription']?['text'];
      if (input is String && input.isNotEmpty) {
        if (!listenOnly) _heard.write(input);
        onInputText?.call(input);
      }
      final output = content['outputTranscription']?['text'];
      if (output is String && output.isNotEmpty) {
        if (!listenOnly) {
          _logHeard();
          _said.write(output);
        }
        onGenerating?.call();
        onOutputText?.call(output);
      }
      for (final part
          in (content['modelTurn']?['parts'] as List? ?? const [])) {
        if (!listenOnly) _logHeard();
        onGenerating?.call();
        final data = part['inlineData']?['data'];
        if (data is String) onAudio?.call(base64Decode(data));
        final text = part['text'];
        if (text is String && text.isNotEmpty && listenOnly) {
          onOutputText?.call(text);
        }
      }
      if (content['generationComplete'] == true) onGenerating?.call();
      if (content['turnComplete'] == true) {
        if (!listenOnly) {
          _logHeard();
          _logSaid();
          _log(voiceTurnLine('turn-complete', {'who': 'live'}));
        }
        onTurnComplete?.call();
      }
    }
    final calls = message['toolCall']?['functionCalls'] as List?;
    if (calls != null) {
      if (!listenOnly) _logHeard();
      onGenerating?.call();
      unawaited(_answer(calls));
    }
    final cancelled = message['toolCallCancellation']?['ids'];
    if (cancelled is List) _responder.cancel(cancelled);
    final update = message['sessionResumptionUpdate'];
    if (update is Map && update['resumable'] == true) {
      _resumeHandle = update['newHandle'] as String?;
    }
    if (message.containsKey('goAway')) unawaited(_reconnect());
  }

  /// Answers the calls of one message (see [AgentToolResponder]).
  Future<void> _answer(List<dynamic> calls) => _responder.answer(calls);

  late final _responder = AgentToolResponder(
    handler: onToolCall,
    quietNames: () =>
        _declaredNonBlocking ? nonBlockingNames(tools) : const <String>{},
    send: (response) => _send({
      'toolResponse': {
        'functionResponses': [response],
      },
    }),
  );

  Future<void> _reconnect() async {
    final old = _socket;
    _socket = null;
    await old?.close();
    await connect();
  }

  // What went over the socket, for the log line at its close.
  String _lastSent = '-';
  int _sentEvents = 0;
  int _sentBytes = 0;

  static void _debug(String message) {
    if (!kReleaseMode) debugPrint('agent-gemini $message');
  }

  /// False when there was no open socket (the message is lost).
  bool _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return false;
    final text = jsonEncode(message);
    _sentEvents++;
    _sentBytes += text.length;
    final type = message.keys.first;
    if (type != 'realtimeInput' ||
        !(message['realtimeInput'] as Map).containsKey('audio')) {
      // Type and size only: never the content, never the key.
      _lastSent = type;
      _debug('send $type ${utf8.encode(text).length}B');
    }
    socket.add(text);
    return true;
  }

  @override
  void sendAudio(Uint8List pcm16k) => _send({
    'realtimeInput': {
      'audio': {
        'mimeType': 'audio/pcm;rate=16000',
        'data': base64Encode(pcm16k),
      },
    },
  });

  /// The microphone stopped (push-to-talk released): answer now.
  @override
  void endAudio() => _send({
    'realtimeInput': {'audioStreamEnd': true},
  });

  @override
  void sendText(String text) => _send({
    'realtimeInput': {'text': text},
  });

  /// A turn that does not complete: context, nothing answered.
  @override
  void addContext(String text) => _send({
    'clientContent': {
      'turns': [
        {
          'role': 'user',
          'parts': [
            {'text': text},
          ],
        },
      ],
      'turnComplete': false,
    },
  });

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

/// The optional setup features of one Live model, as far as it has shown which
/// it takes (see `GeminiLiveSession.useModel`). Everything is on until the
/// model refuses it.
class SetupMemory {
  SetupMemory();

  /// Affective dialog (`enableAffectiveDialog`, the v1alpha endpoint).
  bool affective = true;

  /// Functions declared `NON_BLOCKING`.
  bool nonBlocking = true;

  /// A listening session's text-only response.
  bool textOnly = true;

  /// `speechConfig.languageCode` (the model may not take one).
  bool languageCode = true;

  /// A relaying session's step in `GeminiLiveSession.relayThinking` that the
  /// model took (0: the first, as asked).
  int relayStep = 0;

  /// For the other sessions: whether the model refused a thinking level, and
  /// the highest level it took after that (null: none at all).
  bool levelKnown = false;
  AgentReasoning? levelCeiling;

  SetupMemory copy() => SetupMemory()
    ..affective = affective
    ..nonBlocking = nonBlocking
    ..textOnly = textOnly
    ..languageCode = languageCode
    ..relayStep = relayStep
    ..levelKnown = levelKnown
    ..levelCeiling = levelCeiling;
}

class GeminiLiveException implements Exception {
  const GeminiLiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How long a tool may run before the model gets an error instead.
const agentToolTimeout = Duration(seconds: 8);

/// Tools that read the app and then ask a text model (the orb's briefing, and
/// `navigate`, which brings the briefing of the place it opens) are given
/// longer than a plain call before the model is told "too slow". Only when the
/// responder runs with the default [agentToolTimeout].
const agentSlowToolTimeouts = <String, Duration>{
  'navigate': Duration(seconds: 20),
  'get_briefing': Duration(seconds: 25),
  // The voice layer's only tool: a whole turn of the text agent.
  'ask_agent': Duration(seconds: 90),
};

void _toolLog(String message) => printVoiceLog('agent-tool $message');

/// Answers the function calls of a Live session: every call id gets exactly
/// one response, in blocking and non-blocking mode alike. A handler that
/// throws or runs longer than [timeout] is answered with a structured error
/// (a model whose call is never answered just keeps saying it is waiting).
///
/// Functions run in the order they came (a screen is built by calls that
/// depend on each other); a non-blocking one is answered at once, while a
/// read answers when it is done and never holds the screen operations
/// behind it.
class AgentToolResponder {
  AgentToolResponder({
    required this.handler,
    required this.send,
    Set<String> Function()? quietNames,
    this.timeout = agentToolTimeout,
    void Function(String message)? log,
    VoiceLog? turnLog,
  }) : quietNames = quietNames ?? (() => const <String>{}),
       log = log ?? _toolLog,
       turnLog = turnLog ?? printVoiceLog;

  /// Where the one `voice-turn tool` line of each call goes.
  final VoiceLog turnLog;

  final AgentToolHandler handler;

  /// Sends one `functionResponses` entry; false when it could not be sent.
  final bool Function(Map<String, Object?> response) send;

  /// The functions declared non-blocking in this session.
  final Set<String> Function() quietNames;
  final Duration timeout;
  final void Function(String message) log;

  /// How long [name] may run: [timeout], or its longer allowance when the
  /// responder has the default.
  Duration timeoutOf(String name) => timeout == agentToolTimeout
      ? agentSlowToolTimeouts[name] ?? timeout
      : timeout;

  final _seen = <String>{};
  final _cancelled = <String>{};

  /// Screen operations answered immediately even when the model rejected
  /// non-blocking functions (blocking, but never kept waiting by a read).
  static const _ui = {
    'begin_surface',
    'add_component',
    'update_component',
    'end_surface',
    'spotlight',
    'release_spotlight',
    'mark',
    'set_mood',
  };

  Future<void> answer(List<dynamic> calls) async {
    final quiet = quietNames();
    final slow = <Future<void>>[];
    for (final call in calls.cast<Map<String, dynamic>>()) {
      final name = '${call['name']}';
      final id = call['id'];
      if (id != null && !_seen.add('$id')) {
        log('duplicate call $name id=$id ignored');
        continue;
      }
      final run = _run(call, name, quiet.contains(name));
      if (quiet.contains(name) || _ui.contains(name)) {
        await run;
      } else {
        slow.add(run);
      }
    }
    await Future.wait(slow);
  }

  /// The server cancelled these calls: they need no response.
  void cancel(List<dynamic> ids) {
    for (final id in ids) {
      log('call id=$id cancelled by the server');
      _cancelled.add('$id');
    }
  }

  Future<void> _run(
    Map<String, dynamic> call,
    String name,
    bool nonBlocking,
  ) async {
    final id = call['id'];
    final watch = Stopwatch()..start();
    log('call $name id=$id ${nonBlocking ? 'non-blocking' : 'blocking'}');
    Map<String, Object?> result;
    final args = (call['args'] as Map?)?.cast<String, Object?>() ?? const {};
    var status = 'ok';
    try {
      result = await handler(name, args).timeout(timeoutOf(name));
    } on TimeoutException {
      status = 'timeout';
      result = {
        'error':
            '$name 超过 ${timeoutOf(name).inSeconds} 秒没有返回：现在读不到，'
            '请如实告诉用户稍后再试，不要重复调用。',
      };
    } catch (e) {
      status = 'threw';
      // ignore: raft_lints/avoid_caught_exception_text -- A tool result for the model, never shown in the UI.
      result = {'error': '$e'};
    }
    if (id != null && _cancelled.remove('$id')) {
      log('response id=$id dropped (cancelled)');
      turnLog(
        voiceTurnLine('tool', {
          'name': name,
          'args': _argsSummary(args),
          'status': 'cancelled',
          'ms': watch.elapsedMilliseconds,
        }),
      );
      return;
    }
    if (status == 'ok' && result['error'] != null) status = 'error';
    // Whatever the tool returned, only valid JSON of a safe size goes out.
    final guarded = guardToolOutput(result);
    result = guarded.result;
    final delivered = send({
      'id': id,
      'name': name,
      'response': nonBlocking
          ? GeminiLiveSession.quietResponse(result)
          : result,
    });
    log(
      'response $name id=$id ${result['error'] == null ? 'ok' : 'error'} '
      '${watch.elapsedMilliseconds}ms ${guarded.bytes}B'
      '${guarded.truncated ? ' (cut from ${guarded.originalBytes}B)' : ''}'
      '${delivered ? '' : ' NOT SENT (no socket)'}',
    );
    turnLog(
      voiceTurnLine('tool', {
        'name': name,
        'args': _argsSummary(args),
        'status': status,
        'err': status == 'ok' ? null : clipForLog('${result['error']}', 80),
        'ms': watch.elapsedMilliseconds,
        'bytes': guarded.bytes,
        'sent': delivered ? null : false,
      }),
    );
  }

  /// The arguments of a call on one short line (clipped by the line).
  static String _argsSummary(Map<String, Object?> args) {
    if (args.isEmpty) return '{}';
    try {
      return jsonEncode(args);
    } catch (_) {
      return args.keys.join(',');
    }
  }
}
