import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_audio.dart';
import 'agent_steering.dart';
import 'gemini_live.dart';
import 'gemini_text.dart';
import 'voice_provider.dart';

/// One HTTP exchange with the Gemini REST API: a GET when [body] is null, else
/// a POST of [body] as JSON. [apiKey] belongs in the `x-goog-api-key` header
/// and nowhere else.
typedef GeminiTransport = Future<({int status, String body})> Function(
  Uri uri,
  String apiKey,
  Map<String, Object?>? body,
);

/// The transport of the app: an [HttpClient] per exchange.
Future<({int status, String body})> geminiHttpTransport(
  Uri uri,
  String apiKey,
  Map<String, Object?>? body,
) async {
  const timeout = Duration(seconds: 60);
  // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the voice session's client.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request =
        await (body == null ? client.getUrl(uri) : client.postUrl(uri)).timeout(
          timeout,
        );
    request.headers.set('x-goog-api-key', apiKey);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body)));
    }
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join().timeout(timeout);
    return (status: response.statusCode, body: text);
  } finally {
    client.close(force: true);
  }
}

/// The orb's model as a text agent: a Gemini Flash model that answers by
/// plain `generateContent` calls, with the same system prompt and the same
/// function declarations as a [GeminiLiveSession], in a loop of its own
/// (model, tools, model, ...) until it replies with words only. It exists to
/// measure the same prompt and tools on a model that is better at several
/// steps of tool use than a realtime one.
///
/// Text only: nothing is heard or spoken, [sendAudio] and [endAudio] do
/// nothing, and a turn's words arrive as one [onOutputText] before
/// [onTurnComplete]. Turns run one at a time, in the order they were sent.
class GeminiAgentSession implements VoiceSession, AppSpeaker {
  GeminiAgentSession({
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.steering,
    this.apiKey,
    AgentVoiceKey? key,
    GeminiTransport? transport,
    this.maxSteps = 8,
    this.retryDelay = const Duration(seconds: 1),
    this.onOutputText,
    this.onTurnComplete,
    this.onClosed,
  }) : _key = key ?? AgentVoiceKey.instance,
       _transport = transport ?? geminiHttpTransport;

  final String systemPrompt;
  final List<Map<String, Object?>> tools;

  /// When given, every model request takes its instruction and tools from it
  /// and [systemPrompt] and [tools] are not used.
  final AgentSteering? steering;
  @override
  final AgentToolHandler onToolCall;

  /// The key; the stored Gemini key unless one is given.
  final String? apiKey;
  final AgentVoiceKey _key;
  final GeminiTransport _transport;

  /// The most model calls one turn may take; a model still calling tools
  /// after that is stopped.
  final int maxSteps;

  /// How long a model call waits before it is tried again after a 429 or a
  /// 5xx (twice at most).
  final Duration retryDelay;

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

  static const _host = 'generativelanguage.googleapis.com';

  /// The agent layer runs on Flash Lite (Kevin): one model call per tool
  /// step, so the faster model keeps a two-step turn short.
  static const lite = true;

  String? _model;
  String? _apiKey;
  bool _connected = false;
  bool _closed = false;

  /// Whether the model takes a `thinkingConfig`; off once it refused one.
  bool _thinking = true;

  /// Everything said so far, as the API takes it: the model's parts stay as
  /// they came (Gemini 3 wants each `thoughtSignature` sent back).
  final _contents = <Map<String, Object?>>[];

  /// Context to ride along with the next user turn.
  final _context = <String>[];

  /// The end of the queue of turns.
  Future<void> _tail = Future.value();

  @override
  bool get connected => _connected;

  @override
  String? get model => _model;

  /// The `generationConfig`: plain text out, the least thinking [model] takes
  /// ([thinking] false: none set, for a model that refuses it).
  static Map<String, Object?> generationConfig(
    String model, {
    bool thinking = true,
  }) => {
    'temperature': .3,
    if (thinking) 'thinkingConfig': ?GeminiText.thinkingConfig(model),
  };

  static void _debug(String message) {
    if (!kReleaseMode) debugPrint('gemini-agent $message');
  }

  @override
  Future<void> connect() async {
    final key = apiKey ?? await _key.read();
    if (key == null) throw const FormatException('没有 Gemini Key');
    _apiKey = key;
    final reply = await _transport(
      Uri.https(_host, '/v1beta/models', {'pageSize': '1000'}),
      key,
      null,
    );
    if (reply.status != 200) throw HttpException('models ${reply.status}');
    _model = GeminiText.pickModelFrom(reply.body, lite: lite);
    _closed = false;
    _connected = true;
  }

  @override
  void sendAudio(Uint8List pcm16k) {}

  @override
  void endAudio() {}

  /// Queued after the turn under way.
  @override
  void sendText(String text) {
    if (_closed) return;
    _tail = _tail.then((_) => _turn(text));
  }

  /// Kept for the next turn's input: the API wants the turns to alternate,
  /// and a turn of its own would be answered.
  @override
  void addContext(String text) {
    if (!_closed) _context.add(text);
  }

  /// The app's own words, as a turn of the agent: said after the turn under
  /// way, and the next model turn is told of them.
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
      onClosed?.call(e is HttpException ? e.message : '${e.runtimeType}');
    }
  }

  /// The tools one turn has run (what the steering's review is shown).
  final _runs = <AgentToolRun>[];

  /// One turn: the model and its tools until it answers with words only, or
  /// a tool brings the app's own words ([agentAppSays]). Those words, or null
  /// when the session was closed meanwhile.
  Future<String?> _loop(String text) async {
    final context = [..._context];
    _context.clear();
    _runs.clear();
    _contents.add({
      'role': 'user',
      'parts': [
        for (final c in context) {'text': c},
        {'text': text},
      ],
    });
    // The app may answer the person's words itself.
    final intercept = steering?.intercept;
    if (intercept != null) {
      final answer = await intercept(text, _callOne);
      if (_closed) return null;
      if (answer != null) {
        _contents.add({
          'role': 'model',
          'parts': [
            {'text': answer},
          ],
        });
        return answer;
      }
    }
    final said = <String>[];
    var retried = false;
    for (var step = 1; step <= maxSteps; step++) {
      final content = await _generate(step);
      if (_closed) return null;
      final parts = [
        for (final p in (content?['parts'] as List? ?? const []))
          if (p is Map) Map<String, Object?>.from(p),
      ];
      // An empty reply stays out: a model turn without parts is refused.
      if (parts.isNotEmpty) _contents.add({'role': 'model', 'parts': parts});
      for (final p in parts) {
        final t = p['text'];
        if (t is String && t.isNotEmpty && p['thought'] != true) said.add(t);
      }
      final calls = [
        for (final p in parts)
          if (p['functionCall'] is Map)
            Map<String, Object?>.from(p['functionCall'] as Map),
      ];
      if (calls.isEmpty) {
        final review = steering?.review?.call(said.join('\n'), [..._runs]);
        final retry = review?.retry;
        if (retry != null && !retried && step < maxSteps) {
          retried = true;
          said.clear();
          _contents.add({
            'role': 'user',
            'parts': [
              {'text': retry},
            ],
          });
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
        final response = (r['functionResponse'] as Map)['response'] as Map;
        final line = response.remove(agentAppSays);
        if (line is String && line.isNotEmpty) own.add(line);
      }
      _contents.add({'role': 'user', 'parts': responses});
      if (own.isNotEmpty) {
        final line = own.join('');
        _contents.add({
          'role': 'model',
          'parts': [
            {'text': line},
          ],
        });
        return line;
      }
      if (step == maxSteps) _debug('step cap $maxSteps reached');
    }
    return said.join('\n');
  }

  /// The calls answered without being run: the turn is out of steps, and the
  /// history still needs an answer to every call.
  List<Map<String, Object?>> _refused(List<Map<String, Object?>> calls) => [
    for (final c in calls)
      _response(c, {'error': '这一轮的步数用完了，没有执行这个工具。请根据已有的信息回答。'}),
  ];

  Map<String, Object?> _response(
    Map<String, Object?> call,
    Map<String, Object?> result,
  ) => {
    'functionResponse': {
      if (call['id'] != null) 'id': call['id'],
      'name': call['name'],
      'response': {...result},
    },
  };

  /// One tool, with the timeout and the size guard of a Live session's tools.
  Future<Map<String, Object?>> _callOne(
    String name,
    Map<String, Object?> args,
  ) async {
    Map<String, Object?>? result;
    // The call ids are not passed on: the responder skips an id it has
    // seen, and these are only unique within one reply.
    await AgentToolResponder(
      handler: onToolCall,
      send: (response) {
        result = (response['response'] as Map).cast<String, Object?>();
        return true;
      },
    ).answer([
      {'name': name, 'args': args},
    ]);
    final answer = result ?? {'error': '工具没有返回'};
    _runs.add(AgentToolRun(name, args, answer));
    return answer;
  }

  /// Runs [calls] in order; one response part per call. Once a tool has the
  /// app's own words the rest are not run: the turn is over.
  Future<List<Map<String, Object?>>> _runTools(
    List<Map<String, Object?>> calls,
  ) async {
    final out = <Map<String, Object?>>[];
    var over = false;
    for (final call in calls) {
      if (_closed) break;
      if (over) {
        out.add(_response(call, {'error': '这一轮已经结束，没有执行这个工具。'}));
        continue;
      }
      final args = call['args'];
      final result = await _callOne('${call['name']}', {
        if (args is Map) ...Map<String, Object?>.from(args),
      });
      over = result[agentAppSays] is String;
      out.add(_response(call, result));
    }
    return out;
  }

  /// The model's next content for the history so far; null when it sent none.
  Future<Map<String, Object?>?> _generate(int step) async {
    final model = _model!;
    final scope = steering?.scope();
    final declarations = GeminiLiveSession.declarations(
      scope?.tools ?? tools,
      nonBlocking: false,
    );
    for (var attempt = 0; ; attempt++) {
      final watch = Stopwatch()..start();
      final reply = await _transport(
        Uri.https(_host, '/v1beta/$model:generateContent'),
        _apiKey!,
        {
          'systemInstruction': {
            'parts': [
              {'text': scope?.systemPrompt ?? systemPrompt},
            ],
          },
          'contents': [..._contents],
          if (declarations.isNotEmpty)
            'tools': [
              {'functionDeclarations': declarations},
            ],
          'generationConfig': generationConfig(model, thinking: _thinking),
        },
      );
      Map<String, Object?>? content;
      if (reply.status == 200) {
        final candidate =
            (jsonDecode(reply.body)['candidates'] as List?)?.firstOrNull;
        if (candidate is Map && candidate['content'] is Map) {
          content = Map<String, Object?>.from(candidate['content'] as Map);
        }
      }
      _debug(
        '$model step=$step ${reply.status} ${watch.elapsedMilliseconds}ms '
        'tools=${[for (final p in (content?['parts'] as List? ?? const []))
          if (p is Map && p['functionCall'] is Map) p['functionCall']['name']].join(',')}',
      );
      if (_closed) return null;
      if (reply.status == 200) return content;
      // A model that rejects the thinking setting is asked again without.
      if (reply.status == 400 && _thinking) {
        _thinking = false;
        continue;
      }
      final transient = reply.status == 429 || reply.status >= 500;
      if (transient && attempt < 2) {
        await Future<void>.delayed(retryDelay);
        if (_closed) return null;
        continue;
      }
      throw HttpException('generateContent ${reply.status}');
    }
  }
}
