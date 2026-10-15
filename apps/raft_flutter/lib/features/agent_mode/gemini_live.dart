import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    this.voice = 'Kore',
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
  });

  static const _host = 'generativelanguage.googleapis.com';
  static const _path =
      '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

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
    final model = await _pickModel(apiKey);
    final socket = await WebSocket.connect(
      Uri(scheme: 'wss', host: _host, path: _path).toString(),
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
        // A socket we replaced or closed ourselves ends quietly.
        final remote = _socket == socket;
        if (remote) _socket = null;
        final reason = (socket.closeReason?.isNotEmpty ?? false)
            ? socket.closeReason!
            : '连接已断开（${socket.closeCode ?? '-'}）';
        if (!ready.isCompleted) {
          ready.completeError(GeminiLiveException(reason));
        }
        if (remote) onClosed?.call(reason);
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
          {'functionDeclarations': tools},
        ],
        'inputAudioTranscription': <String, Object?>{},
        'outputAudioTranscription': <String, Object?>{},
        'contextWindowCompression': {'slidingWindow': <String, Object?>{}},
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
    final update = message['sessionResumptionUpdate'];
    if (update is Map && update['resumable'] == true) {
      _resumeHandle = update['newHandle'] as String?;
    }
    if (message.containsKey('goAway')) unawaited(_reconnect());
  }

  Future<void> _answer(List<dynamic> calls) async {
    final responses = <Map<String, Object?>>[];
    for (final call in calls.cast<Map<String, dynamic>>()) {
      final name = '${call['name']}';
      Map<String, Object?> result;
      try {
        result = await onToolCall(
          name,
          (call['args'] as Map?)?.cast<String, Object?>() ?? const {},
        );
      } catch (e) {
        result = {'error': '$e'};
      }
      responses.add({'id': call['id'], 'name': name, 'response': result});
    }
    _send({
      'toolResponse': {'functionResponses': responses},
    });
  }

  Future<void> _reconnect() async {
    final old = _socket;
    _socket = null;
    await old?.close();
    await connect();
  }

  void _send(Map<String, Object?> message) => _socket?.add(jsonEncode(message));

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
