import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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
class GeminiLiveSession {
  GeminiLiveSession({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.voice = 'Sulafat',
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
  });

  static const _host = 'generativelanguage.googleapis.com';
  static String _path(String version) =>
      '/ws/google.ai.generativelanguage.$version.GenerativeService.BidiGenerateContent';

  /// Affective dialog (tone follows the person's tone) needs the v1alpha
  /// endpoint and a model that supports it; dropped after one refusal.
  static bool _affective = true;

  /// Functions declared `NON_BLOCKING` let the model keep talking while a
  /// screen is composed. A model that refuses them at setup gets blocking
  /// functions instead (answered just as fast); dropped after one refusal.
  static bool _nonBlocking = true;

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
  final AgentToolHandler onToolCall;
  final String voice;
  final void Function(Uint8List pcm24k)? onAudio;
  final void Function(String text)? onInputText;
  final void Function(String text)? onOutputText;
  final void Function()? onTurnComplete;
  final void Function()? onInterrupted;

  /// The server closed the session.
  final void Function(String reason)? onClosed;

  static String? _model;
  WebSocket? _socket;
  String? _resumeHandle;

  bool get connected => _socket != null;
  String? get model => _model;

  /// The model chosen for this key, once known.
  static String? get pickedModel => _model;

  /// Picks the newest model that supports Live sessions for this key.
  static Future<String> _pickModel(String key) async {
    if (_model != null) return _model!;
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
      int rank(String name) =>
          (name.contains('native-audio') || name.contains('live') ? 2 : 0) +
          (name.contains('preview') || name.contains('exp') ? 0 : 1);
      models.sort((a, b) {
        final r = rank(b) - rank(a);
        return r != 0 ? r : b.compareTo(a);
      });
      return _model = models.first;
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

  Future<void> connect() async {
    if (_socket != null) return;
    final hasNonBlocking = nonBlockingNames(tools).isNotEmpty;
    while (true) {
      final nb = _nonBlocking && hasNonBlocking;
      try {
        await _connect(affective: _affective, nonBlocking: nb);
        return;
      } catch (e) {
        // A refusal that names the function behavior drops that first;
        // otherwise affective dialog (as before), then non-blocking.
        // ignore: raft_lints/avoid_caught_exception_text -- Matched against "behavior" / "non_blocking" to pick which feature to drop; the text is never shown.
        final refusal = '$e';
        final behavior = RegExp(
          r'behavior|non_?blocking|scheduling',
          caseSensitive: false,
        ).hasMatch(refusal);
        if (nb && behavior) {
          _nonBlocking = false;
        } else if (_affective) {
          _affective = false;
        } else if (nb) {
          _nonBlocking = false;
        } else {
          rethrow;
        }
      }
    }
  }

  Future<void> _connect({
    required bool affective,
    required bool nonBlocking,
  }) async {
    _declaredNonBlocking = nonBlocking;
    final model = await _pickModel(apiKey);
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
    _send({
      'setup': {
        'model': model,
        'generationConfig': {
          'responseModalities': ['AUDIO'],
          // Gemini 3 Live models require a level; low keeps replies quick.
          'thinkingConfig': {'thinkingLevel': 'low'},
          'speechConfig': {
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
        'outputAudioTranscription': <String, Object?>{},
        'contextWindowCompression': {'slidingWindow': <String, Object?>{}},
        if (affective) 'enableAffectiveDialog': true,
        'sessionResumption': {'handle': ?_resumeHandle},
      },
    });
    try {
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _handle(Map<String, dynamic> message) {
    final content = message['serverContent'] as Map<String, dynamic>?;
    if (content != null) {
      if (content['interrupted'] == true) onInterrupted?.call();
      final input = content['inputTranscription']?['text'];
      if (input is String && input.isNotEmpty) onInputText?.call(input);
      final output = content['outputTranscription']?['text'];
      if (output is String && output.isNotEmpty) onOutputText?.call(output);
      for (final part
          in (content['modelTurn']?['parts'] as List? ?? const [])) {
        final data = part['inlineData']?['data'];
        if (data is String) onAudio?.call(base64Decode(data));
      }
      if (content['turnComplete'] == true) onTurnComplete?.call();
    }
    final calls = message['toolCall']?['functionCalls'] as List?;
    if (calls != null) unawaited(_answer(calls));
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

  /// False when there was no open socket (the message is lost).
  bool _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return false;
    socket.add(jsonEncode(message));
    return true;
  }

  void sendAudio(Uint8List pcm16k) => _send({
    'realtimeInput': {
      'audio': {
        'mimeType': 'audio/pcm;rate=16000',
        'data': base64Encode(pcm16k),
      },
    },
  });

  /// The microphone stopped (push-to-talk released): answer now.
  void endAudio() => _send({
    'realtimeInput': {'audioStreamEnd': true},
  });

  void sendText(String text) => _send({
    'realtimeInput': {'text': text},
  });

  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

class GeminiLiveException implements Exception {
  const GeminiLiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// How long a tool may run before the model gets an error instead.
const agentToolTimeout = Duration(seconds: 8);

void _toolLog(String message) {
  if (!kReleaseMode) debugPrint('agent-tool $message');
}

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
  }) : quietNames = quietNames ?? (() => const <String>{}),
       log = log ?? _toolLog;

  final AgentToolHandler handler;

  /// Sends one `functionResponses` entry; false when it could not be sent.
  final bool Function(Map<String, Object?> response) send;

  /// The functions declared non-blocking in this session.
  final Set<String> Function() quietNames;
  final Duration timeout;
  final void Function(String message) log;

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
    try {
      result = await handler(
        name,
        (call['args'] as Map?)?.cast<String, Object?>() ?? const {},
      ).timeout(timeout);
    } on TimeoutException {
      result = {
        'error':
            '$name 超过 ${timeout.inSeconds} 秒没有返回：现在读不到，'
            '请如实告诉用户稍后再试，不要重复调用。',
      };
    } catch (e) {
      result = {'error': '$e'};
    }
    if (id != null && _cancelled.remove('$id')) {
      log('response id=$id dropped (cancelled)');
      return;
    }
    final delivered = send({
      'id': id,
      'name': name,
      'response': nonBlocking
          ? GeminiLiveSession.quietResponse(result)
          : result,
    });
    log(
      'response $name id=$id ${result['error'] == null ? 'ok' : 'error'} '
      '${watch.elapsedMilliseconds}ms${delivered ? '' : ' NOT SENT (no socket)'}',
    );
  }
}
