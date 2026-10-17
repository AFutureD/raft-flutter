import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'agent_audio.dart';

/// One-shot text generation with the Gemini key stored on the device (the
/// same key as the voice session), over REST `generateContent`.
class GeminiText {
  GeminiText({
    AgentVoiceKey? key,
    this.timeout = const Duration(seconds: 20),
    this.lite = false,
  }) : _key = key ?? AgentVoiceKey.instance;

  static final instance = GeminiText();

  /// The orb's briefings: a smaller, faster model that thinks less (Kevin).
  static final briefing = GeminiText(lite: true);

  static const _host = 'generativelanguage.googleapis.com';
  final AgentVoiceKey _key;
  final Duration timeout;

  /// Prefer Flash Lite (else Flash) and the least thinking.
  final bool lite;
  static final _models = <bool, String>{};

  /// The newest Flash model that can generate text for this key: stable
  /// ahead of preview, full ahead of lite (lite ahead of full with [lite]),
  /// then the highest version.
  static String pickModel(
    Iterable<Map<String, dynamic>> models, {
    bool lite = false,
  }) {
    final names = [
      for (final m in models)
        if ((m['supportedGenerationMethods'] as List? ?? const []).contains(
              'generateContent',
            ) &&
            RegExp(r'gemini-[\d.]+-flash').hasMatch('${m['name']}') &&
            !RegExp(
              r'image|tts|audio|live|native|embedding|thinking|robotics|computer',
            ).hasMatch('${m['name']}'))
          '${m['name']}',
    ];
    if (names.isEmpty) throw const FormatException('这个 Key 没有可用的文字模型');
    double version(String n) =>
        double.tryParse(
          RegExp(r'gemini-([\d.]+)-flash').firstMatch(n)?[1] ?? '',
        ) ??
        0;
    int rank(String n) =>
        (RegExp(r'preview|exp').hasMatch(n) ? 0 : 2) +
        (n.contains('lite') == lite ? 1 : 0);
    names.sort((a, b) {
      final r = rank(b) - rank(a);
      if (r != 0) return r;
      final v = version(b).compareTo(version(a));
      return v != 0 ? v : b.compareTo(a);
    });
    return names.first;
  }

  /// The model's reply to [prompt] as JSON text, or null without a key.
  Future<String?> generate(String system, String prompt) async {
    final apiKey = await _key.read();
    if (apiKey == null) return null;
    // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the voice session's client.
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final model = _models[lite] ??= await _discover(client, apiKey);
      var thinking = true;
      for (;;) {
        final started = Stopwatch()..start();
        final reply = await _post(
          client,
          apiKey,
          model,
          system,
          prompt,
          thinking,
        );
        if (!kReleaseMode) {
          debugPrint(
            'gemini-text $model ${reply.status} ${started.elapsedMilliseconds}ms',
          );
        }
        if (reply.status == 200) return reply.text;
        // A model that rejects the thinking setting is asked again without.
        if (reply.status == 400 && thinking) {
          thinking = false;
          continue;
        }
        _models.remove(lite);
        throw HttpException('generateContent ${reply.status}');
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _discover(HttpClient client, String apiKey) async {
    final request = await client
        .getUrl(Uri.https(_host, '/v1beta/models', {'pageSize': '1000'}))
        .timeout(timeout);
    request.headers.set('x-goog-api-key', apiKey);
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('models ${response.statusCode}');
    }
    return pickModelFrom(body, lite: lite);
  }

  /// [pickModel] over the body of a `models.list` response.
  static String pickModelFrom(String body, {bool lite = false}) => pickModel([
    for (final m in (jsonDecode(body)['models'] as List? ?? const []))
      if (m is Map) Map<String, dynamic>.from(m),
  ], lite: lite);

  /// The `thinkingConfig` with the least thinking [model] takes (null for a
  /// model without one).
  static Map<String, Object?>? thinkingConfig(
    String model, {
    bool lite = false,
  }) {
    if (model.contains('gemini-2.5')) return {'thinkingBudget': 0};
    if (model.contains('gemini-3')) {
      return {'thinkingLevel': lite ? 'minimal' : 'low'};
    }
    return null;
  }

  /// The request's generationConfig: JSON out, and the least thinking the
  /// model takes ([thinking] false: no setting, for a model that refuses it).
  static Map<String, Object?> generationConfig(
    String model, {
    bool lite = false,
    bool thinking = true,
  }) => {
    'temperature': .3,
    'responseMimeType': 'application/json',
    if (thinking) 'thinkingConfig': ?thinkingConfig(model, lite: lite),
  };

  Future<({int status, String? text})> _post(
    HttpClient client,
    String apiKey,
    String model,
    String system,
    String prompt,
    bool thinking,
  ) async {
    final request = await client
        .postUrl(Uri.https(_host, '/v1beta/$model:generateContent'))
        .timeout(timeout);
    request.headers
      ..set('x-goog-api-key', apiKey)
      ..contentType = ContentType.json;
    request.add(
      utf8.encode(
        jsonEncode({
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
          'contents': [
            {
              'role': 'user',
              'parts': [
                {'text': prompt},
              ],
            },
          ],
          'generationConfig': generationConfig(
            model,
            lite: lite,
            thinking: thinking,
          ),
        }),
      ),
    );
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    if (response.statusCode != 200) {
      return (status: response.statusCode, text: null);
    }
    final parts =
        (jsonDecode(body)['candidates'] as List?)
                ?.firstOrNull?['content']?['parts']
            as List?;
    final text = [
      for (final p in parts ?? const [])
        if (p is Map && p['text'] is String && p['thought'] != true) p['text'],
    ].join();
    return (status: 200, text: text);
  }
}
