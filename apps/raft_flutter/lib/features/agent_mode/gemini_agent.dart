import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_audio.dart';
import 'agent_steering.dart';
import 'agent_thinking.dart';
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

/// A streamed model call failed with this HTTP status (the body, which can
/// name the request, stays out).
class GeminiStreamFailure implements Exception {
  const GeminiStreamFailure(this.status);

  final int status;

  @override
  String toString() => 'GeminiStreamFailure($status)';
}

/// One streamed POST to the Gemini REST API (`streamGenerateContent?alt=sse`):
/// the JSON chunks of the answer, in order, as they arrive. A status other
/// than 200 is a [GeminiStreamFailure]. [apiKey] belongs in the
/// `x-goog-api-key` header and nowhere else. Cancelling the subscription ends
/// the request.
typedef GeminiStreamTransport = Stream<Map<String, Object?>> Function(
  Uri uri,
  String apiKey,
  Map<String, Object?> body,
);

/// The `data:` events of a server-sent-events body, each decoded as a JSON
/// object (an event that is not one is skipped).
Stream<Map<String, Object?>> geminiSseChunks(Stream<String> text) async* {
  final data = <String>[];
  Map<String, Object?>? flush() {
    if (data.isEmpty) return null;
    final raw = data.join('\n').trim();
    data.clear();
    try {
      final json = jsonDecode(raw);
      return json is Map ? Map<String, Object?>.from(json) : null;
    } on FormatException {
      return null;
    }
  }

  await for (final line in text.transform(const LineSplitter())) {
    if (line.isEmpty) {
      final chunk = flush();
      if (chunk != null) yield chunk;
    } else if (line.startsWith('data:')) {
      data.add(line.substring(5));
    }
  }
  final last = flush();
  if (last != null) yield last;
}

/// The stream transport of the app: an [HttpClient] per exchange.
Stream<Map<String, Object?>> geminiHttpStreamTransport(
  Uri uri,
  String apiKey,
  Map<String, Object?> body,
) async* {
  const timeout = Duration(seconds: 60);
  // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the voice session's client.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.postUrl(uri).timeout(timeout);
    request.headers.set('x-goog-api-key', apiKey);
    request.headers.contentType = ContentType.json;
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(timeout);
    if (response.statusCode != 200) {
      await response.drain<void>().timeout(timeout);
      throw GeminiStreamFailure(response.statusCode);
    }
    // The timeout counts the silence between two chunks.
    yield* geminiSseChunks(response.transform(utf8.decoder).timeout(timeout));
  } finally {
    client.close(force: true);
  }
}

/// One tool run through [handler] with the timeout and the size guard of a
/// Live session's tools; an `error` map when it returned nothing. The text
/// agents (`GeminiAgentSession`, `GenkitAgentSession`) both call tools so.
Future<Map<String, Object?>> runAgentTool(
  AgentToolHandler handler,
  String name,
  Map<String, Object?> args,
) async {
  Map<String, Object?>? result;
  // The call ids are not passed on: the responder skips an id it has
  // seen, and these are only unique within one reply.
  await AgentToolResponder(
    handler: handler,
    send: (response) {
      result = (response['response'] as Map).cast<String, Object?>();
      return true;
    },
  ).answer([
    {'name': name, 'args': args},
  ]);
  return result ?? {'error': '工具没有返回'};
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
class GeminiAgentSession implements VoiceSession, AppSpeaker, CancellableTurn {
  GeminiAgentSession({
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.steering,
    this.thinking = AgentThinking.low,
    this.modelName,
    this.apiKey,
    AgentVoiceKey? key,
    GeminiTransport? transport,
    GeminiStreamTransport? streamTransport,
    this.onDraft,
    this.maxSteps = 8,
    this.retryDelay = const Duration(seconds: 1),
    this.onOutputText,
    this.onTurnComplete,
    this.onClosed,
  }) : _key = key ?? AgentVoiceKey.instance,
       _transport = transport ?? geminiHttpTransport,
       _streamTransport = streamTransport ?? geminiHttpStreamTransport;

  final String systemPrompt;
  final List<Map<String, Object?>> tools;

  /// When given, every model request takes its instruction and tools from it
  /// and [systemPrompt] and [tools] are not used.
  final AgentSteering? steering;

  /// How hard the model thinks (a model that refuses a `thinkingConfig` gets
  /// none).
  final AgentThinking thinking;

  /// The model to use (`gemini-3.5-flash-lite`, `models/...` or
  /// `googleai/...`); the app picks a Flash Lite one from the list when null.
  final String? modelName;
  @override
  final AgentToolHandler onToolCall;

  /// The key; the stored Gemini key unless one is given.
  final String? apiKey;
  final AgentVoiceKey _key;
  final GeminiTransport _transport;
  final GeminiStreamTransport _streamTransport;

  /// Model words as they stream, a draft of what [onOutputText] will deliver;
  /// only the later [onOutputText] is authoritative. Given with
  /// [AgentSteering.streamSafe], the model calls stream and the words of a
  /// step after tool results come here, as long as the steering says the
  /// review would leave their beginning alone; without either, a model call
  /// is one plain `generateContent`.
  final void Function(String delta)? onDraft;

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

  /// How many turns have been cancelled, and the count the running turn
  /// started under: a cancel makes the running turn (and the ones queued)
  /// stale, and they stop at their next step.
  int _cancelled = 0;
  int _running = 0;
  bool get _stale => _closed || _cancelled != _running;

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
    AgentThinking level = AgentThinking.low,
  }) => {
    'temperature': .3,
    if (thinking)
      'thinkingConfig': ?GeminiText.thinkingConfig(model, level: level),
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
    final want = modelName?.trim();
    _model = want == null || want.isEmpty
        ? GeminiText.pickModelFrom(reply.body, lite: lite)
        : 'models/${want.replaceFirst(RegExp('^(models|googleai)/'), '')}';
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
    final mine = _cancelled;
    _tail = _tail.then((_) => _turn(text, mine));
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

  @override
  void cancelTurn() {
    _cancelled++;
  }

  Future<void> _turn(String text, int mine) async {
    if (_closed || !_connected || mine != _cancelled) return;
    _running = mine;
    final mark = _contents.length;
    try {
      final said = await _loop(text);
      if (said == null) {
        // Cancelled half way: the history goes back to before the turn, so
        // no call is left without its answer.
        if (!_closed && _contents.length > mark) {
          _contents.removeRange(mark, _contents.length);
        }
        return;
      }
      if (said.isNotEmpty) onOutputText?.call(said);
      onTurnComplete?.call();
    } catch (e) {
      if (_closed) return;
      if (_cancelled != _running) {
        // The request that was cut short failed with it: not a failure.
        if (_contents.length > mark) {
          _contents.removeRange(mark, _contents.length);
        }
        return;
      }
      _closed = true;
      _connected = false;
      _context.clear();
      // ignore: raft_lints/avoid_caught_exception_text -- The reason of a developer tool's session end (status or exception type); never the key or a body.
      onClosed?.call(e is HttpException ? e.message : '${e.runtimeType}');
    }
  }

  /// The tools one turn has run (what the steering's review is shown).
  final _runs = <AgentToolRun>[];

  bool get _streams => onDraft != null && steering?.streamSafe != null;

  /// Whether the turn under way may still give drafts: off for good once the
  /// steering said no, the review asked for a retry, or the app's own words
  /// ended the turn.
  bool _drafting = true;

  /// One turn: the model and its tools until it answers with words only, or
  /// a tool brings the app's own words ([agentAppSays]). Those words, or null
  /// when the session was closed meanwhile.
  Future<String?> _loop(String text) async {
    final context = [..._context, ?steering?.preload?.call()];
    _context.clear();
    _runs.clear();
    _drafting = true;
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
      if (_stale) return null;
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
      if (_stale) return null;
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
        final review = await steering?.review?.call(said.join('\n'), [
          ..._runs,
        ], _callOne);
        if (_stale) return null;
        final retry = review?.retry;
        if (retry != null && !retried && step < maxSteps) {
          retried = true;
          _drafting = false;
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
      if (_stale) return null;
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
        _drafting = false;
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
    final answer = await runAgentTool(onToolCall, name, args);
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
      if (_stale) break;
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
      final request = {
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
        'generationConfig': generationConfig(
          model,
          thinking: _thinking,
          level: thinking,
        ),
      };
      Map<String, Object?>? content;
      int status;
      if (_streams) {
        final streamed = await _streamed(model, request, step);
        status = streamed.status;
        content = streamed.content;
      } else {
        final reply = await _transport(
          Uri.https(_host, '/v1beta/$model:generateContent'),
          _apiKey!,
          request,
        );
        status = reply.status;
        if (status == 200) {
          final candidate =
              (jsonDecode(reply.body)['candidates'] as List?)?.firstOrNull;
          if (candidate is Map && candidate['content'] is Map) {
            content = Map<String, Object?>.from(candidate['content'] as Map);
          }
        }
      }
      _debug(
        '$model thinking=${_thinking ? thinking.name : 'none'} step=$step '
        '$status ${watch.elapsedMilliseconds}ms '
        'tools=${[for (final p in (content?['parts'] as List? ?? const []))
          if (p is Map && p['functionCall'] is Map) p['functionCall']['name']].join(',')}',
      );
      if (_stale) return null;
      if (status == 200) return content;
      // A model that rejects the thinking setting is asked again without.
      if (status == 400 && _thinking) {
        _thinking = false;
        continue;
      }
      final transient = status == 429 || status >= 500;
      if (transient && attempt < 2) {
        await Future<void>.delayed(retryDelay);
        if (_stale) return null;
        continue;
      }
      throw HttpException('generateContent $status');
    }
  }

  /// One streamed model call: the content merged from the chunks, with the
  /// words of the step given to [onDraft] as they come (see [AgentSteering.
  /// streamSafe]). A failure comes back as its status; one after a draft was
  /// given is thrown, since asking again would say the words twice.
  Future<({int status, Map<String, Object?>? content})> _streamed(
    String model,
    Map<String, Object?> request,
    int step,
  ) async {
    final parts = <Map<String, Object?>>[];
    var text = '';
    var drafted = false;
    var calling = false;
    try {
      await for (final chunk in _streamTransport(
        Uri.https(_host, '/v1beta/$model:streamGenerateContent', {
          'alt': 'sse',
        }),
        _apiKey!,
        request,
      )) {
        if (_stale) return (status: 200, content: null);
        final candidate = (chunk['candidates'] as List?)?.firstOrNull;
        final content = candidate is Map ? candidate['content'] : null;
        for (final p
            in (content is Map ? content['parts'] : null) as List? ??
                const []) {
          if (p is! Map) continue;
          final part = Map<String, Object?>.from(p);
          _mergePart(parts, part);
          if (part['functionCall'] is Map) calling = true;
          final delta = part['text'];
          if (delta is! String ||
              delta.isEmpty ||
              part['thought'] == true ||
              part['functionCall'] != null) {
            continue;
          }
          text += delta;
          // The first step may be reasoning before a tool; so is any step
          // that goes on to call one.
          if (step < 2 || !_drafting || calling) continue;
          if (!steering!.streamSafe!([..._runs], text)) {
            _drafting = false;
            continue;
          }
          drafted = true;
          onDraft!(delta);
        }
      }
    } on GeminiStreamFailure catch (e) {
      if (drafted) throw HttpException('generateContent ${e.status}');
      return (status: e.status, content: null);
    }
    return (
      status: 200,
      content: parts.isEmpty
          ? null
          : <String, Object?>{'role': 'model', 'parts': parts},
    );
  }

  /// Adds a streamed [part] to [parts] the way one whole reply has it: the
  /// pieces of one run of words (or of reasoning) are one part, which keeps
  /// the last `thoughtSignature` seen.
  static void _mergePart(
    List<Map<String, Object?>> parts,
    Map<String, Object?> part,
  ) {
    bool plain(Map<String, Object?> p) =>
        p['text'] is String &&
        p.keys.every(
          (k) => k == 'text' || k == 'thought' || k == 'thoughtSignature',
        );
    if (parts.isNotEmpty && plain(parts.last) && plain(part)) {
      final last = parts.last;
      if ((last['thought'] == true) == (part['thought'] == true)) {
        last['text'] = '${last['text']}${part['text']}';
        if (part['thoughtSignature'] != null) {
          last['thoughtSignature'] = part['thoughtSignature'];
        }
        return;
      }
    }
    parts.add(part);
  }
}
