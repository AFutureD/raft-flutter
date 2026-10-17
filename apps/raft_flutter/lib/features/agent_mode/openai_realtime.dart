import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_tool_output.dart';
import 'gemini_live.dart';
import 'voice_provider.dart';

/// Linear resampler for mono PCM16 (little endian) that keeps its place
/// between chunks, so a stream cut at any byte boundary stays continuous.
class Pcm16Resampler {
  Pcm16Resampler({required this.inRate, required this.outRate});

  final int inRate;
  final int outRate;

  // Position of the next output sample, in 1/[outRate] of an input sample,
  // relative to the first sample of the next chunk (-outRate is the last
  // sample of the previous chunk).
  int _pos = 0;
  int _prev = 0;

  static int _floorDiv(int a, int b) => a >= 0 ? a ~/ b : -((-a + b - 1) ~/ b);

  Uint8List convert(Uint8List pcm) {
    final n = pcm.lengthInBytes ~/ 2;
    if (n == 0) return Uint8List(0);
    final input = ByteData.sublistView(pcm);
    int sample(int i) => input.getInt16(i * 2, Endian.little);
    final out = <int>[];
    while (true) {
      final i0 = _floorDiv(_pos, outRate);
      if (i0 + 1 >= n) break;
      final s0 = i0 < 0 ? _prev : sample(i0);
      final s1 = sample(i0 + 1);
      out.add(s0 + ((s1 - s0) * (_pos - i0 * outRate)) ~/ outRate);
      _pos += inRate;
    }
    _prev = sample(n - 1);
    _pos -= n * outRate;
    final bytes = ByteData(out.length * 2);
    for (var i = 0; i < out.length; i++) {
      bytes.setInt16(i * 2, out[i].clamp(-32768, 32767), Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}

/// Which service speaks the OpenAI Realtime protocol to the session. xAI's
/// Grok Voice API is a clone of it (same events, audio and tool flow), with a
/// few documented differences that [OpenAiRealtimeSession] branches on:
/// where `voice` and `turn_detection` sit in `session.update`, the transcript
/// events, no `reasoning`/`truncation` settings, and per-minute billing.
///
/// Verified against https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech
/// and https://docs.x.ai/developers/rest-api-reference/inference/voice
/// (event list and schemas: https://docs.x.ai/voice-realtime.ws.json).
enum RealtimeService { openai, grok }

/// One OpenAI Realtime session over WebSocket (`gpt-realtime-2.1-mini`):
/// the same job as [GeminiLiveSession] on another service. With
/// `service: RealtimeService.grok` it is an xAI Grok Voice session
/// (`grok-voice-latest`) instead.
///
/// Audio: the Realtime API takes and returns 24 kHz mono PCM16, the app's
/// microphone gives 16 kHz (resampled here) and its speaker plays 24 kHz
/// (passed through). Turns are found by the server (server VAD with a short
/// silence); when the microphone stops, a tail of silence is sent so the
/// server ends the person's turn.
///
/// Tools: [tools] are the Gemini-style declarations the app already has,
/// converted to the Realtime `function` tools with the same names,
/// descriptions and parameters. A response that calls tools ends; once every
/// call is answered (`function_call_output`) one `response.create` makes the
/// model go on, unless the person spoke in between.
class OpenAiRealtimeSession implements VoiceSession {
  OpenAiRealtimeSession({
    required this.apiKey,
    required this.systemPrompt,
    required this.tools,
    required this.onToolCall,
    this.voice = defaultVoice,
    this.reasoning = AgentReasoning.low,
    this.onAudio,
    this.onInputText,
    this.onOutputText,
    this.onTurnComplete,
    this.onInterrupted,
    this.onClosed,
    this.playbackPending,
    this.service = RealtimeService.openai,
    Duration? idleClose,
    Uri? endpoint,
    void Function(String message)? log,
    this._toolTimeout = agentToolTimeout,
  }) : endpoint =
           endpoint ??
           (service == RealtimeService.grok
               ? Uri.parse('$_grokUrl?model=$grokModelName')
               : Uri.parse('$_url?model=$modelName')),
       _idleClose =
           idleClose ??
           (service == RealtimeService.grok ? grokIdleClose : null),
       _log = log ?? ((m) => _debugLog(service, m));

  static const modelName = 'gpt-realtime-2.1-mini';
  static const defaultVoice = 'marin';
  static const _url = 'wss://api.openai.com/v1/realtime';

  /// Grok Voice: `grok-voice-latest` is an alias of Grok Voice 3.0.
  static const grokModelName = 'grok-voice-latest';
  static const grokDefaultVoice = 'eve';
  static const _grokUrl = 'wss://api.x.ai/v1/realtime';

  /// Grok Voice is priced per minute.
  static const grokUsdPerMinute = 0.08;

  /// A per-minute service is billed for the time a session is open, so it is
  /// closed after this long without any traffic, tool or speech, and opened
  /// again on next use.
  static const grokIdleClose = Duration(seconds: 60);

  /// The server decides the person has finished after this much silence.
  static const silenceMs = 400;
  static const _prefixPaddingMs = 300;

  /// Sent when the microphone stops, so the server sees the silence.
  static const _tailMs = silenceMs + 300;

  /// Grok's end-of-speech delay is not documented, so the tail is longer.
  static const _grokTailMs = 1200;

  /// The Realtime API takes and gives audio at this rate only (PCM16).
  static const apiRate = 24000;
  static const micRate = 16000;

  /// Optional session settings a model may refuse; each is dropped (for the
  /// rest of the run) after one refusal that names it.
  static bool _reasoning = true;
  static bool _truncation = true;
  static String _transcribeModel = 'gpt-4o-mini-transcribe';

  /// Same for Grok's `audio.input.transcription.model`.
  static bool _grokTranscription = true;

  @visibleForTesting
  static void resetFallbacks() {
    _reasoning = true;
    _truncation = true;
    _transcribeModel = 'gpt-4o-mini-transcribe';
    _grokTranscription = true;
  }

  final RealtimeService service;
  bool get _grok => service == RealtimeService.grok;

  /// `reasoning.effort` of the session: OpenAI accepts minimal, low, medium,
  /// high and xhigh (https://developers.openai.com/api/reference/resources/realtime/subresources/client_secrets/methods/create);
  /// the app offers the middle three. A refusal that names it steps down one
  /// level, and `low` refused drops `reasoning` as before. Grok Voice has no
  /// such scale (`reasoning.effort` is `high` or `none`), so it is not sent.
  final AgentReasoning reasoning;
  late AgentReasoning _effort = reasoning;

  /// Close the socket after this long without activity (null: never).
  final Duration? _idleClose;

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
  @override
  final void Function(String reason)? onClosed;

  /// How much of the speech received is still to be played; used to cut the
  /// unheard part off the conversation when the person interrupts.
  final Future<Duration> Function()? playbackPending;
  final Uri endpoint;
  final void Function(String message) _log;
  final Duration _toolTimeout;

  static void _debugLog(RealtimeService service, String message) {
    if (kReleaseMode) return;
    final tag = service == RealtimeService.grok ? 'grok' : 'openai';
    debugPrint('agent-$tag $message');
  }

  WebSocket? _socket;
  final _micResampler = Pcm16Resampler(inRate: micRate, outRate: apiRate);

  // ---- conversation state ----------------------------------------------

  /// A response is being generated (so `response.create` would be refused).
  bool _responseActive = false;

  /// A `response.create` was sent and the server has not answered yet.
  bool _awaitingCreated = false;
  bool _userSpeaking = false;

  /// Counts the times the person started speaking: a tool call that belongs
  /// to an older count was overtaken by what they said.
  int _epoch = 0;
  int _responseEpoch = 0;

  /// The model owes a response (text was sent) / should go on after tools.
  bool _wantResponse = false;
  bool _continuation = false;
  int _continueEpoch = 0;

  /// Calls whose output has not been sent yet.
  int _outstanding = 0;
  Future<void> _quietTail = Future.value();

  /// The audio item being spoken and how much of it was received (ms).
  String? _audioItem;
  double _audioMs = 0;
  final _inputDeltaItems = <String>{};

  /// Grok: the transcript already passed on, per item (its `updated` events
  /// carry the whole text so far, not a delta).
  final _inputStreamed = <String, String>{};

  /// Grok: the speech received is heard before the next `response.create`
  /// (so the answer after a tool does not overlap the speech before it).
  bool _waitingForPlayback = false;
  bool _playbackSettled = false;

  // ---- idle close and session time (per-minute billing) --------------------

  Timer? _idleTimer;
  final _sinceActivity = Stopwatch();
  final _open = Stopwatch();
  bool _openLogged = true;
  final _callResponses = <String>{};

  @override
  bool get connected => _socket != null;

  @override
  String? get model => _grok ? grokModelName : modelName;

  // ---- tools -----------------------------------------------------------

  /// [tools] (Gemini FunctionDeclarations) as Realtime `function` tools: the
  /// name, description and JSON Schema parameters unchanged; Gemini's
  /// `behavior` has no counterpart and is dropped.
  static List<Map<String, Object?>> functionTools(
    List<Map<String, Object?>> tools,
  ) => [
    for (final t in tools)
      {
        'type': 'function',
        'name': t['name'],
        'description': t['description'],
        'parameters':
            t['parameters'] ??
            const {'type': 'object', 'properties': <String, Object?>{}},
      },
  ];

  late final _quiet = GeminiLiveSession.nonBlockingNames(tools);

  late final _responder = AgentToolResponder(
    handler: onToolCall,
    quietNames: () => _quiet,
    timeout: _toolTimeout,
    log: _log,
    send: _sendToolResult,
  );

  // ---- connecting ------------------------------------------------------

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    for (var attempt = 0; ; attempt++) {
      try {
        await _connect();
        return;
      } on OpenAiRealtimeException catch (e) {
        // A refusal that names an optional setting drops that setting.
        // ignore: raft_lints/avoid_caught_exception_text -- Matched against setting names to pick which one to drop; the text is never shown.
        final named = '${e.param ?? ''} ${e.message}'.toLowerCase();
        if (attempt >= 3) rethrow;
        if (_grok) {
          // Grok has no other optional settings than the transcription.
          if (_grokTranscription && named.contains('transcri')) {
            _grokTranscription = false;
          } else {
            rethrow;
          }
        } else if (_reasoning && named.contains('reasoning')) {
          final lower = GeminiLiveSession.lowerThinking(_effort);
          if (lower == null) {
            _reasoning = false;
          } else {
            _effort = lower;
          }
        } else if (_truncation && named.contains('truncation')) {
          _truncation = false;
        } else if (_transcribeModel != 'whisper-1' &&
            named.contains('transcri')) {
          _transcribeModel = 'whisper-1';
        } else {
          rethrow;
        }
        _log('setup refused (${e.param ?? 'no param'}); retrying without it');
      }
    }
  }

  /// The `session` of the `session.update` sent at setup. Stable from one
  /// turn to the next (and from session to session): nothing in front of the
  /// instructions changes, so the server's prompt cache applies.
  Map<String, Object?> sessionConfig() =>
      _grok ? _grokSessionConfig() : _openAiSessionConfig();

  /// Grok Voice's `session`: `voice` and `turn_detection` at the top level
  /// (not under `audio`), PCM at 24 kHz both ways, input transcription by
  /// `grok-transcribe` (without it the server sends no user transcript).
  /// No `type`, `output_modalities`, `truncation` (speech only) and no VAD
  /// tuning: the documented `turn_detection` fields are `type` and
  /// `idle_timeout_ms`. `reasoning` is left at the server default.
  Map<String, Object?> _grokSessionConfig() => {
    'instructions': systemPrompt,
    'voice': voice,
    'turn_detection': {'type': 'server_vad'},
    'tools': functionTools(tools),
    'audio': {
      'input': {
        'format': {'type': 'audio/pcm', 'rate': apiRate},
        if (_grokTranscription) 'transcription': {'model': 'grok-transcribe'},
      },
      'output': {
        'format': {'type': 'audio/pcm', 'rate': apiRate},
      },
    },
  };

  Map<String, Object?> _openAiSessionConfig() => {
    'type': 'realtime',
    'output_modalities': ['audio'],
    'instructions': systemPrompt,
    'tools': functionTools(tools),
    if (_reasoning) 'reasoning': {'effort': _effort.name},
    if (_truncation)
      // Drops a fifth of a full conversation at once instead of a little each
      // turn, which would break the cached prefix every turn.
      'truncation': {'type': 'retention_ratio', 'retention_ratio': 0.8},
    'audio': {
      'input': {
        'format': {'type': 'audio/pcm', 'rate': apiRate},
        'transcription': {'model': _transcribeModel},
        'turn_detection': {
          'type': 'server_vad',
          'threshold': 0.5,
          'prefix_padding_ms': _prefixPaddingMs,
          'silence_duration_ms': silenceMs,
          'create_response': true,
          'interrupt_response': true,
        },
      },
      'output': {
        'format': {'type': 'audio/pcm', 'rate': apiRate},
        'voice': voice,
      },
    },
  };

  Future<void> _connect() async {
    final WebSocket socket;
    try {
      // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the Gemini voice session's socket.
      socket = await WebSocket.connect(
        endpoint.toString(),
        headers: {'Authorization': 'Bearer $apiKey'},
        // Events are small next to the audio (base64 does not compress), and
        // a deflate stream that goes wrong ends in a protocol close (1002).
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 15));
    } on WebSocketException catch (e) {
      // ignore: raft_lints/avoid_caught_exception_text -- Matched to pick a message; the rest is the socket's own text (host and path, never the key).
      final refused = e.message;
      // dart:io does not say why the upgrade was refused (an unknown or
      // revoked key is a 401, a key without the model a 403/404).
      if (refused.contains('not upgraded')) {
        throw OpenAiRealtimeException(
          _grok
              ? 'xAI 拒绝了连接：请检查 Key 是否有效、账户能否使用 Grok 语音'
              : 'OpenAI 拒绝了连接：请检查 Key 是否有效、账户能否使用实时语音模型',
        );
      }
      throw OpenAiRealtimeException('连接失败（${refused.split('\n').first}）');
    }
    final created = Completer<void>();
    final ready = Completer<void>();
    socket.listen(
      (raw) {
        final Map<String, dynamic> event;
        try {
          final text = raw is String ? raw : utf8.decode(raw as List<int>);
          _receivedBytes += text.length;
          event = jsonDecode(text) as Map<String, dynamic>;
          _lastReceived = '${event['type']}';
          if (text.length > _bigEvent) {
            _log('recv ${event['type']} ${text.length} chars');
          }
        } catch (_) {
          _log('unreadable frame ignored');
          return;
        }
        switch (event['type']) {
          case 'session.created':
            if (!created.isCompleted) created.complete();
          case 'session.updated':
            if (!ready.isCompleted) ready.complete();
          case 'error' when !ready.isCompleted:
            final error = event['error'] as Map<String, dynamic>? ?? const {};
            final failure = OpenAiRealtimeException(
              '${error['message'] ?? '会话设置被拒绝'}',
              param: error['param'] as String?,
            );
            if (!created.isCompleted) created.completeError(failure);
            if (!ready.isCompleted) ready.completeError(failure);
          default:
            if (ready.isCompleted) _handle(event);
        }
      },
      onDone: () {
        final established = ready.isCompleted;
        final remote = _socket == socket;
        if (remote) {
          _socket = null;
          _logOpenTime('closed by the server');
        }
        final reason = (socket.closeReason?.isNotEmpty ?? false)
            ? socket.closeReason!
            : '连接已断开（${socket.closeCode ?? '-'}）';
        // What the next device run needs to tell who ended it: dart:io closes
        // with 1002 itself when a frame from the server breaks the protocol,
        // and the server closes with 1002 when ours does. The key is never in
        // any of this.
        _log(
          'socket done code=${socket.closeCode} '
          'reason="${socket.closeReason ?? ''}" '
          'lastSent=$_lastSent lastReceived=$_lastReceived '
          'sent=${_sentEvents}ev/${_sentBytes}B '
          'audioFramesSent=$_audioFrames received=${_receivedBytes}B '
          'open=${_open.elapsed.inSeconds}s',
        );
        final closed = OpenAiRealtimeException(reason);
        if (!created.isCompleted) created.completeError(closed);
        if (!ready.isCompleted) ready.completeError(closed);
        if (remote && established) onClosed?.call(reason);
      },
      onError: (Object e) {
        _log('socket error ${e.runtimeType} lastSent=$_lastSent');
        if (!created.isCompleted) created.completeError(e);
        if (!ready.isCompleted) ready.completeError(e);
      },
      cancelOnError: true,
    );
    _socket = socket;
    try {
      await created.future.timeout(const Duration(seconds: 15));
      _send({'type': 'session.update', 'session': sessionConfig()});
      await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      await close();
      rethrow;
    }
    _resetConversation();
    _startClock();
  }

  void _resetConversation() {
    _lastSent = _lastReceived = '-';
    _sentEvents = _sentBytes = _audioFrames = _receivedBytes = 0;
    _responseActive = _awaitingCreated = _userSpeaking = false;
    _wantResponse = _continuation = false;
    _outstanding = 0;
    _audioItem = null;
    _audioMs = 0;
    _waitingForPlayback = _playbackSettled = false;
    _inputStreamed.clear();
  }

  // ---- idle close and session time ----------------------------------------

  void _startClock() {
    _open
      ..reset()
      ..start();
    _openLogged = false;
    _sinceActivity
      ..reset()
      ..start();
    _armIdle(_idleClose);
  }

  void _armIdle(Duration? after) {
    _idleTimer?.cancel();
    if (_idleClose == null || after == null) return;
    _idleTimer = Timer(after, _idleCheck);
  }

  /// Nothing is happening when no response is being made, no tool is running
  /// and the person is not talking.
  void _idleCheck() {
    final limit = _idleClose;
    if (limit == null || _socket == null) return;
    final quietFor = _sinceActivity.elapsed;
    final busy = _responseActive || _awaitingCreated || _outstanding > 0;
    if (busy || _userSpeaking || quietFor < limit) {
      _armIdle(busy || _userSpeaking ? limit : limit - quietFor);
      return;
    }
    _log('idle for ${quietFor.inSeconds}s: closing the session');
    final socket = _socket;
    _socket = null;
    _logOpenTime('idle');
    // Not reported as closed by the server: the next use connects again.
    unawaited(socket?.close());
  }

  /// One debug line with how long the session was open; for a per-minute
  /// service, what that costs at the list price. Never logs the key.
  void _logOpenTime(String why) {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_openLogged) return;
    _openLogged = true;
    _open.stop();
    final seconds = _open.elapsed.inMilliseconds / 1000;
    final cost = _grok
        ? ' (about \$${(seconds / 60 * grokUsdPerMinute).toStringAsFixed(4)} '
              'at \$$grokUsdPerMinute/min)'
        : '';
    _log('session $why after ${seconds.toStringAsFixed(1)}s open$cost');
  }

  // ---- events from the server --------------------------------------------

  void _handle(Map<String, dynamic> event) {
    _sinceActivity.reset();
    switch (event['type']) {
      case 'input_audio_buffer.speech_started':
        unawaited(_speechStarted());
      case 'input_audio_buffer.speech_stopped':
        _userSpeaking = false;
        _flush();
      case 'conversation.item.input_audio_transcription.delta':
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) {
          _inputDeltaItems.add('${event['item_id']}');
          onInputText?.call(delta);
        }
      case 'conversation.item.input_audio_transcription.updated':
        // Grok: the whole transcript so far, which may correct what was said
        // before. Only the text that extends what was passed on is passed on.
        _inputTranscript('${event['item_id']}', event['transcript']);
      case 'conversation.item.input_audio_transcription.completed':
        if (_grok) {
          final id = '${event['item_id']}';
          _inputTranscript(id, event['transcript']);
          _inputStreamed.remove(id);
          return;
        }
        // Models that stream deltas have said it all already.
        final streamed = _inputDeltaItems.remove('${event['item_id']}');
        final transcript = event['transcript'];
        if (!streamed && transcript is String && transcript.isNotEmpty) {
          onInputText?.call(transcript);
        }
      case 'response.created':
        final response = event['response'] as Map<String, dynamic>? ?? const {};
        _responseActive = true;
        _awaitingCreated = false;
        _responseEpoch = _epoch;
        // A response the server started (the person's turn) sees everything
        // already in the conversation.
        _wantResponse = _continuation = false;
        _log('response ${response['id']} created');
      case 'response.output_audio.delta':
        final delta = event['delta'];
        if (delta is! String) return;
        final pcm = base64Decode(delta);
        final item = '${event['item_id']}';
        if (item != _audioItem) {
          _audioItem = item;
          _audioMs = 0;
        }
        _audioMs += pcm.length / (apiRate * 2 / 1000);
        onAudio?.call(pcm);
      case 'response.output_audio_transcript.delta':
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) onOutputText?.call(delta);
      case 'response.function_call_arguments.done':
        _toolCall(event);
      case 'response.done':
        _responseDone(event['response'] as Map<String, dynamic>? ?? const {});
      case 'error':
        final error = event['error'] as Map<String, dynamic>? ?? const {};
        _awaitingCreated = false;
        _log(
          'server error ${error['type']}/${error['code']}: '
          '${error['message']}',
        );
    }
  }

  /// Passes on the part of a Grok transcript [text] (cumulative) that follows
  /// what was passed on for [item]. A correction of earlier text cannot be
  /// taken back from the captions; it is logged and the rest follows.
  void _inputTranscript(String item, Object? text) {
    if (text is! String || text.isEmpty) return;
    final before = _inputStreamed[item] ?? '';
    if (text.length <= before.length) return;
    if (!text.startsWith(before)) {
      _log('transcript of $item revised; keeping the captions as they are');
    }
    _inputStreamed[item] = text;
    onInputText?.call(text.substring(before.length));
  }

  /// The person began to speak. The server has already cut the response off;
  /// stop what is playing and remove the unheard part from the conversation.
  Future<void> _speechStarted() async {
    _userSpeaking = true;
    _epoch++;
    final item = _audioItem;
    final receivedMs = _audioMs;
    final wasResponding = _responseActive;
    _audioItem = null;
    _audioMs = 0;
    var pendingMs = 0;
    if (item != null) {
      try {
        pendingMs = (await playbackPending?.call())?.inMilliseconds ?? 0;
      } catch (_) {
        pendingMs = 0;
      }
    }
    if (wasResponding || pendingMs > 0) onInterrupted?.call();
    if (item != null) {
      final heard = (receivedMs - pendingMs).clamp(0, receivedMs).floor();
      _send({
        'type': 'conversation.item.truncate',
        'item_id': item,
        'content_index': 0,
        'audio_end_ms': heard,
      });
    }
  }

  void _toolCall(Map<String, dynamic> event) {
    final callId = '${event['call_id']}';
    final name = '${event['name']}';
    final responseId = '${event['response_id']}';
    _callResponses.add(responseId);
    _outstanding++;
    Map<String, Object?> args;
    try {
      final raw = event['arguments'];
      final decoded = raw is String && raw.isNotEmpty ? jsonDecode(raw) : {};
      args = (decoded as Map).cast<String, Object?>();
    } catch (_) {
      _sendToolResult({
        'id': callId,
        'name': name,
        'response': {'error': '$name 的参数不是有效的 JSON，请重新调用。'},
      });
      return;
    }
    if (_epoch != _responseEpoch) {
      // The person spoke over the response that made this call: the call is
      // not run (the model still gets an answer for it).
      _sendToolResult({
        'id': callId,
        'name': name,
        'response': {'error': '用户打断了，这次调用没有执行。'},
      });
      return;
    }
    if (_grok && !_responseActive) {
      // Grok sends the call "alongside" `response.done`: if that came first
      // the model must still be asked to go on once the call is answered.
      _continuation = true;
      _continueEpoch = _epoch;
    }
    final call = {'id': callId, 'name': name, 'args': args};
    if (_quiet.contains(name)) {
      // Screen operations run in the order they were called.
      _quietTail = _quietTail.then((_) => _responder.answer([call]));
    } else {
      unawaited(_responder.answer([call]));
    }
  }

  /// Gives the model the result of one call, intact.
  bool _sendToolResult(Map<String, Object?> response) {
    final name = '${response['name']}';
    final result = Map<String, Object?>.from(response['response'] as Map);
    // `scheduling` is Gemini's way to hush an answer; nothing here reads it.
    if (_quiet.contains(name)) result.remove('scheduling');
    // Valid JSON of a safe size, whatever the tool returned (the responder
    // already guarded it; this keeps the error paths and any other caller to
    // the same rule).
    final output = guardToolOutput(result).json;
    final sent = _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'function_call_output',
        'call_id': response['id'],
        'output': output,
      },
    });
    if (_outstanding > 0) _outstanding--;
    _flush();
    return sent;
  }

  void _responseDone(Map<String, dynamic> response) {
    _responseActive = false;
    final id = '${response['id']}';
    final status = '${response['status']}';
    _logUsage(response);
    final output = response['output'] as List? ?? const [];
    final calledTools =
        _callResponses.remove(id) ||
        output.any((o) => o is Map && o['type'] == 'function_call');
    if (status == 'failed') {
      final error = (response['status_details'] as Map?)?['error'] as Map?;
      unawaited(_fail('${error?['message'] ?? '这一轮回答失败了'}'));
      return;
    }
    if (status == 'cancelled') {
      // The person took over: their next turn answers, nothing goes on.
    } else if (calledTools) {
      // Not the end of the turn: the model goes on once the calls are answered.
      _continuation = true;
      _continueEpoch = _epoch;
    } else {
      onTurnComplete?.call();
    }
    _flush();
  }

  /// Asks for the next response when one is owed and nothing stands in the
  /// way: not while one is running, a tool is still working, or the person is
  /// talking (the server answers them itself).
  void _flush() {
    if (_continuation && _epoch != _continueEpoch) _continuation = false;
    if (!(_wantResponse || _continuation)) return;
    if (_responseActive || _awaitingCreated) return;
    if (_outstanding > 0 || _userSpeaking || _waitingForPlayback) return;
    final settled = _playbackSettled;
    _playbackSettled = false;
    if (_grok && !settled && playbackPending != null) {
      // Grok: an answer that starts while the speech before it is still
      // playing overlaps it, so wait for the speech to be heard.
      _waitingForPlayback = true;
      unawaited(_afterPlayback());
      return;
    }
    _wantResponse = _continuation = false;
    _awaitingCreated = _send({'type': 'response.create'});
  }

  Future<void> _afterPlayback() async {
    try {
      final wait = await playbackPending!();
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    } catch (_) {
      /* ask now */
    }
    _waitingForPlayback = false;
    _playbackSettled = true;
    _flush();
    _playbackSettled = false;
  }

  Future<void> _fail(String reason) async {
    final socket = _socket;
    _socket = null;
    _logOpenTime('failed');
    await socket?.close();
    onClosed?.call(reason);
  }

  // ---- usage log ---------------------------------------------------------

  /// One line with what a response was billed for: tokens in (and how many
  /// of them were cached) and out, to compare bills with the cache on.
  static String usageLine(Map<String, dynamic> response) {
    final usage = response['usage'];
    if (usage is! Map) return '';
    final input = usage['input_token_details'] as Map? ?? const {};
    final cachedDetails = input['cached_tokens_details'] as Map? ?? const {};
    final output = usage['output_token_details'] as Map? ?? const {};
    final inTokens = (usage['input_tokens'] as num?) ?? 0;
    final cached = (input['cached_tokens'] as num?) ?? 0;
    final pct = inTokens > 0 ? (cached * 100 / inTokens).round() : 0;
    return 'usage response=${response['id']} status=${response['status']} '
        'input=$inTokens (text=${input['text_tokens'] ?? 0} '
        'audio=${input['audio_tokens'] ?? 0}) '
        'cached=$cached $pct% (text=${cachedDetails['text_tokens'] ?? 0} '
        'audio=${cachedDetails['audio_tokens'] ?? 0}) '
        'output=${usage['output_tokens'] ?? 0} '
        '(text=${output['text_tokens'] ?? 0} '
        'audio=${output['audio_tokens'] ?? 0}) '
        'total=${usage['total_tokens'] ?? 0}';
  }

  void _logUsage(Map<String, dynamic> response) {
    final line = usageLine(response);
    if (line.isNotEmpty) _log(line);
  }

  // ---- sending -------------------------------------------------------------

  /// Events bigger than this many characters are logged when they arrive.
  static const _bigEvent = 8000;

  // What went over the socket, for the log line at its close.
  String _lastSent = '-';
  String _lastReceived = '-';
  int _sentEvents = 0;
  int _sentBytes = 0;
  int _audioFrames = 0;
  int _receivedBytes = 0;

  /// False when there was no open socket (the message is lost).
  bool _send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null) return false;
    _sinceActivity.reset();
    final text = jsonEncode(message);
    final type = '${message['type']}';
    _sentEvents++;
    _sentBytes += text.length;
    if (type == 'input_audio_buffer.append') {
      _audioFrames++;
    } else {
      // Type and size only: never the content, never the key.
      _lastSent = type;
      _log('send $type ${utf8.encode(text).length}B');
    }
    socket.add(text);
    return true;
  }

  @override
  void sendAudio(Uint8List pcm16k) {
    final pcm = _micResampler.convert(pcm16k);
    if (pcm.isEmpty) return;
    _send({'type': 'input_audio_buffer.append', 'audio': base64Encode(pcm)});
  }

  /// The microphone stopped: the server finds the end of the turn in
  /// silence, so a tail of it is sent.
  @override
  void endAudio() {
    final silence = Uint8List(
      apiRate * 2 * (_grok ? _grokTailMs : _tailMs) ~/ 1000,
    );
    _send({
      'type': 'input_audio_buffer.append',
      'audio': base64Encode(silence),
    });
  }

  @override
  void addContext(String text) => _send({
    'type': 'conversation.item.create',
    'item': {
      'type': 'message',
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': text},
      ],
    },
  });

  @override
  void sendText(String text) {
    _send({
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {'type': 'input_text', 'text': text},
        ],
      },
    });
    _wantResponse = true;
    _flush();
  }

  @override
  Future<void> close() async {
    final socket = _socket;
    _socket = null;
    _logOpenTime('closed');
    await socket?.close();
  }
}

class OpenAiRealtimeException implements Exception {
  const OpenAiRealtimeException(this.message, {this.param});
  final String message;

  /// The setting the server named in its refusal, if any.
  final String? param;
  @override
  String toString() => message;
}
