import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:genkit/lite.dart' as gk;
import 'package:genkit/plugin.dart'
    as gk
    show CancellationController, Model, StatusCode;
import 'package:genkit_google_genai/genkit_google_genai.dart' show googleAI;
import 'package:schemantic/schemantic.dart' show SchemanticType;

import 'agent_audio.dart';
import 'agent_steering.dart';
import 'agent_thinking.dart';
import 'gemini_agent.dart';
import 'gemini_live.dart';
import 'gemini_text.dart';
import 'voice_provider.dart';

/// The provider part of a Genkit model reference for the Gemini API.
const genkitGoogleProvider = 'googleai';

/// The Genkit reference of a model named in a setting or a link: `provider/
/// model`. A bare name (`gemini-3.5-flash-lite`, `models/gemini-...`) is a
/// Gemini API model.
String genkitModelRef(String id) {
  final name = id.trim().replaceFirst(RegExp('^models/'), '');
  return name.contains('/') ? name : '$genkitGoogleProvider/$name';
}

/// Finds the Genkit model of a reference (`provider/model`) and gives it
/// [apiKey]. This is the one place that knows which providers the app has:
/// another provider is its Genkit plugin package plus one line here.
typedef GenkitModelResolver = gk.Model Function(String ref, String apiKey);

/// The app's providers: the Gemini API.
gk.Model genkitResolveModel(String ref, String apiKey) {
  final slash = ref.indexOf('/');
  final provider = slash < 0 ? '' : ref.substring(0, slash);
  final name = slash < 0 ? ref : ref.substring(slash + 1);
  return switch (provider) {
    genkitGoogleProvider => googleAI(apiKey: apiKey).model(name),
    _ => throw FormatException('没有 "$provider" 的 Genkit 插件'),
  };
}

/// A model call that failed: the HTTP status it maps to. Only that is told
/// to [VoiceSession.onClosed]; the message of the provider can name the
/// request, so it stays out.
class GenkitAgentFailure implements Exception {
  const GenkitAgentFailure(this.status);

  final int status;

  String get message => 'generate $status';

  @override
  String toString() => 'GenkitAgentFailure($message)';
}

/// The text agent of [GeminiAgentSession] on Genkit: the same loop with the
/// same rules of the app (a scope asked for before every model request, the
/// app's own words from a tool end the turn, review of the final words, tools
/// run through [onToolCall]), but the model call itself is Genkit's
/// `generate`, so the model is a `provider/model` string.
///
/// Genkit is asked for exactly one model step at a time
/// (`returnToolRequests`): it never runs a tool or loops, so the tools and the
/// instruction can change between steps, and the history (with each Gemini 3
/// `thoughtSignature` in the metadata of its part) is ours.
class GenkitAgentSession implements VoiceSession, AppSpeaker {
  GenkitAgentSession({
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.steering,
    this.thinking = AgentThinking.low,
    this.modelId,
    this.apiKey,
    AgentVoiceKey? key,
    GeminiTransport? transport,
    GenkitModelResolver? resolver,
    this.maxSteps = 8,
    this.retryDelay = const Duration(seconds: 1),
    this.requestTimeout = const Duration(seconds: 60),
    this.onOutputText,
    this.onTurnComplete,
    this.onClosed,
  }) : _key = key ?? AgentVoiceKey.instance,
       _transport = transport ?? geminiHttpTransport,
       _resolver = resolver ?? genkitResolveModel;

  final String systemPrompt;
  final List<Map<String, Object?>> tools;

  /// When given, every model request takes its instruction and tools from it
  /// and [systemPrompt] and [tools] are not used.
  final AgentSteering? steering;

  /// How hard a Gemini model thinks (other providers: not used).
  final AgentThinking thinking;

  /// The model, as `provider/model` or a bare Gemini name; a Flash Lite one
  /// is picked from the Gemini model list when null.
  final String? modelId;
  @override
  final AgentToolHandler onToolCall;

  /// The key of the provider; the stored Gemini key unless one is given.
  final String? apiKey;
  final AgentVoiceKey _key;
  final GeminiTransport _transport;
  final GenkitModelResolver _resolver;

  /// The most model calls one turn may take.
  final int maxSteps;

  /// How long a model call waits before it is tried again after a 429 or a
  /// 5xx (twice at most).
  final Duration retryDelay;

  /// The longest one model call may take.
  final Duration requestTimeout;

  @override
  final void Function(String text)? onOutputText;
  @override
  final void Function()? onTurnComplete;
  @override
  final void Function(String reason)? onClosed;

  // Text only: these never fire.
  @override
  void Function(Uint8List pcm24k)? get onAudio => null;
  @override
  void Function(String text)? get onInputText => null;
  @override
  void Function()? get onInterrupted => null;

  String? _ref;
  gk.Model? _genkitModel;
  bool _connected = false;
  bool _closed = false;

  /// Whether the model takes a thinking setting; off once it refused one.
  bool _thinking = true;

  /// Everything said so far, as Genkit messages: the model's own messages
  /// stay as they came.
  final _history = <gk.Message>[];
  final _context = <String>[];
  Future<void> _tail = Future.value();
  gk.CancellationController? _inflight;

  @override
  bool get connected => _connected;

  @override
  String? get model => _ref;

  bool get _google => _ref?.startsWith('$genkitGoogleProvider/') ?? false;

  static void _debug(String message) {
    if (!kReleaseMode) debugPrint('genkit-agent $message');
  }

  @override
  Future<void> connect() async {
    final key = apiKey ?? await _key.read();
    if (key == null) throw const FormatException('没有 Gemini Key');
    final want = modelId?.trim();
    if (want == null || want.isEmpty) {
      final reply = await _transport(
        Uri.https('generativelanguage.googleapis.com', '/v1beta/models', {
          'pageSize': '1000',
        }),
        key,
        null,
      );
      if (reply.status != 200) throw GenkitAgentFailure(reply.status);
      _ref = genkitModelRef(
        GeminiText.pickModelFrom(reply.body, lite: GeminiAgentSession.lite),
      );
    } else {
      _ref = genkitModelRef(want);
    }
    _genkitModel = _resolver(_ref!, key);
    _closed = false;
    _connected = true;
  }

  @override
  void sendAudio(Uint8List pcm16k) {}

  @override
  void endAudio() {}

  @override
  void sendText(String text) {
    if (_closed) return;
    _tail = _tail.then((_) => _turn(text));
  }

  @override
  void addContext(String text) {
    if (!_closed) _context.add(text);
  }

  @override
  void speak(String text) {
    if (_closed || text.isEmpty) return;
    _tail = _tail.then((_) {
      if (_closed || !_connected) return;
      _context.add('（App 已经替你对用户说了：“$text”）');
      onOutputText?.call(text);
      onTurnComplete?.call();
    });
  }

  @override
  Future<void> close() async {
    _closed = true;
    _connected = false;
    _context.clear();
    _inflight?.cancel();
  }

  Future<void> _turn(String text) async {
    if (_closed || !_connected) return;
    try {
      final said = await _loop(text);
      if (said == null) return;
      if (said.isNotEmpty) onOutputText?.call(said);
      onTurnComplete?.call();
    } catch (e) {
      if (_closed) return;
      _closed = true;
      _connected = false;
      _context.clear();
      // ignore: raft_lints/avoid_caught_exception_text -- The reason of a developer tool's session end (status or exception type); never the key or a body.
      onClosed?.call(e is GenkitAgentFailure ? e.message : '${e.runtimeType}');
    }
  }

  /// The tools one turn has run (what the steering's review is shown).
  final _runs = <AgentToolRun>[];

  static gk.Message _user(List<String> texts) => gk.Message(
    role: gk.Role.user,
    content: [for (final t in texts) gk.TextPart(text: t)],
  );

  static gk.Message _model(String text) => gk.Message(
    role: gk.Role.model,
    content: [gk.TextPart(text: text)],
  );

  /// One tool, with the timeout and the size guard of a Live session's tools.
  Future<Map<String, Object?>> _callOne(
    String name,
    Map<String, Object?> args,
  ) async {
    final r = await runAgentTool(onToolCall, name, args);
    _runs.add(AgentToolRun(name, args, r));
    return r;
  }

  /// One turn: the model and its tools until it answers with words only, or
  /// a tool brings the app's own words ([agentAppSays]). Those words, or null
  /// when the session was closed meanwhile.
  Future<String?> _loop(String text) async {
    final context = [..._context];
    _context.clear();
    _runs.clear();
    _history.add(_user([...context, text]));
    final intercept = steering?.intercept;
    if (intercept != null) {
      final answer = await intercept(text, _callOne);
      if (_closed) return null;
      if (answer != null) {
        _history.add(_model(answer));
        return answer;
      }
    }
    final said = <String>[];
    var retried = false;
    for (var step = 1; step <= maxSteps; step++) {
      final message = await _generate(step);
      if (_closed) return null;
      final parts = [for (final p in message?.content ?? const <gk.Part>[]) p];
      // An empty reply stays out: a model turn without parts is refused.
      if (parts.isNotEmpty) _history.add(message!);
      for (final p in parts) {
        // A reasoning part has no `text` key: only the words come through.
        final t = p.text;
        if (t != null && t.isNotEmpty) said.add(t);
      }
      final calls = [
        for (final p in parts)
          if (p.toolRequest != null) p.toolRequest!,
      ];
      if (calls.isEmpty) {
        final review = await steering?.review?.call(said.join('\n'), [
          ..._runs,
        ], _callOne);
        if (_closed) return null;
        final retry = review?.retry;
        if (retry != null && !retried && step < maxSteps) {
          retried = true;
          said.clear();
          _history.add(_user([retry]));
          continue;
        }
        final replaced = review?.text;
        if (replaced != null) return replaced;
        break;
      }
      final responses = step == maxSteps
          ? _refused(calls)
          : await _runTools(calls);
      if (_closed) return null;
      // A tool brought the app's own words: they end the turn, the model is
      // not asked again.
      final own = <String>[];
      for (final r in responses) {
        final output = r.toolResponse.output as Map;
        final line = output.remove(agentAppSays);
        if (line is String && line.isNotEmpty) own.add(line);
      }
      _history.add(gk.Message(role: gk.Role.tool, content: responses));
      if (own.isNotEmpty) {
        final line = own.join('');
        _history.add(_model(line));
        return line;
      }
      if (step == maxSteps) _debug('step cap $maxSteps reached');
    }
    return said.join('\n');
  }

  gk.ToolResponsePart _response(
    gk.ToolRequest call,
    Map<String, Object?> result,
  ) => gk.ToolResponsePart(
    toolResponse: gk.ToolResponse(
      ref: call.ref,
      name: call.name,
      output: {...result},
    ),
  );

  /// The calls answered without being run: the turn is out of steps, and the
  /// history still needs an answer to every call.
  List<gk.ToolResponsePart> _refused(List<gk.ToolRequest> calls) => [
    for (final c in calls)
      _response(c, {'error': '这一轮的步数用完了，没有执行这个工具。请根据已有的信息回答。'}),
  ];

  /// Runs [calls] in order; one response part per call. Once a tool has the
  /// app's own words the rest are not run: the turn is over.
  Future<List<gk.ToolResponsePart>> _runTools(
    List<gk.ToolRequest> calls,
  ) async {
    final out = <gk.ToolResponsePart>[];
    var over = false;
    for (final call in calls) {
      if (_closed) break;
      if (over) {
        out.add(_response(call, {'error': '这一轮已经结束，没有执行这个工具。'}));
        continue;
      }
      final input = call.input;
      final args = <String, Object?>{
        if (input is Map) ...Map<String, Object?>.from(input),
      };
      final result = await runAgentTool(onToolCall, call.name, args);
      _runs.add(AgentToolRun(call.name, args, result));
      over = result[agentAppSays] is String;
      out.add(_response(call, result));
    }
    return out;
  }

  /// A function declaration of the app as a Genkit tool that is only
  /// declared: the model may ask for it and the session runs it itself.
  static gk.Tool<Map<String, dynamic>, Object?> _declared(
    Map<String, Object?> declaration,
  ) {
    final parameters = declaration['parameters'];
    return gk.Tool<Map<String, dynamic>, Object?>(
      name: '${declaration['name']}',
      description: '${declaration['description'] ?? ''}',
      inputSchema: parameters is Map
          ? SchemanticType.from<Map<String, dynamic>>(
              jsonSchema: Map<String, Object?>.from(parameters),
              parse: (json) => Map<String, dynamic>.from(json as Map),
            )
          : null,
      fn: (input, context) =>
          throw StateError('the session runs its tools, not Genkit'),
    );
  }

  /// The HTTP status a failed Genkit response stands for.
  static int _statusOf(gk.GenerateResult<Object?> result) {
    final wire = result.error?.status;
    if (wire == null) return 500;
    return gk.StatusCode.fromWireName(wire).httpStatus;
  }

  /// The model's next message for the history so far; null when it sent none.
  Future<gk.Message?> _generate(int step) async {
    final ref = _ref!;
    final scope = steering?.scope();
    final declarations = GeminiLiveSession.declarations(
      scope?.tools ?? tools,
      nonBlocking: false,
    );
    for (var attempt = 0; ; attempt++) {
      final watch = Stopwatch()..start();
      final cancel = _inflight = gk.CancellationController();
      final timer = Timer(requestTimeout, () => cancel.cancel('timeout'));
      gk.GenerateResult<Object?> result;
      try {
        result = await gk.generate<Object?, dynamic>(
          model: _genkitModel!,
          system: scope?.systemPrompt ?? systemPrompt,
          messages: [..._history],
          tools: [for (final d in declarations) _declared(d)],
          returnToolRequests: true,
          config: _google
              ? GeminiAgentSession.generationConfig(
                  ref.substring(genkitGoogleProvider.length + 1),
                  thinking: _thinking,
                  level: thinking,
                )
              : null,
          cancel: cancel.token,
        );
      } finally {
        timer.cancel();
        if (identical(_inflight, cancel)) _inflight = null;
      }
      final failed = result.error != null || result.message == null;
      final status = failed ? _statusOf(result) : 200;
      final message = failed ? null : result.message;
      _debug(
        '$ref thinking=${_thinking && _google ? thinking.name : 'none'} '
        'step=$step $status ${watch.elapsedMilliseconds}ms '
        'tools=${[for (final p in message?.content ?? const <gk.Part>[]) ?p.toolRequest?.name].join(',')}',
      );
      if (_closed) return null;
      if (!failed) return message;
      // A model that rejects the thinking setting is asked again without.
      if (status == 400 && _thinking && _google) {
        _thinking = false;
        continue;
      }
      final transient = status == 429 || status >= 500;
      if (transient && attempt < 2) {
        await Future<void>.delayed(retryDelay);
        if (_closed) return null;
        continue;
      }
      throw GenkitAgentFailure(status);
    }
  }
}
