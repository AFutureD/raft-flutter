import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_audio.dart';
import 'gemini_text.dart';

/// One-shot JSON text generation over the Responses API, which OpenAI and xAI
/// both serve in the same shape:
/// - OpenAI: `POST https://api.openai.com/v1/responses`, model `gpt-6-luna`
///   (https://developers.openai.com/api/docs/models/gpt-6-luna,
///   https://developers.openai.com/api/reference/resources/responses/methods/create)
/// - xAI: `POST https://api.x.ai/v1/responses`, model `grok-4.3`
///   (https://docs.x.ai/developers/model-capabilities/text/generate-text,
///   https://docs.x.ai/developers/models/grok-4.3, openapi.json `/v1/responses`)
///
/// Nothing is stored on the service (`store: false`); the key is only sent as
/// the bearer header and never logged.
class ResponsesText {
  ResponsesText({
    required this.endpoint,
    required this.model,
    required this.key,
    this.timeout = const Duration(seconds: 15),
  });

  factory ResponsesText.openAi({AgentVoiceKey? key}) => ResponsesText(
    endpoint: Uri.parse('https://api.openai.com/v1/responses'),
    model: 'gpt-6-luna',
    key: (key ?? OpenAiVoiceKey.instance).read,
  );

  factory ResponsesText.xai({AgentVoiceKey? key}) => ResponsesText(
    endpoint: Uri.parse('https://api.x.ai/v1/responses'),
    model: 'grok-4.3',
    key: (key ?? GrokVoiceKey.instance).read,
  );

  final Uri endpoint;
  final String model;
  final Future<String?> Function() key;
  final Duration timeout;

  /// The request body: [system] as `instructions`, [prompt] as the input,
  /// JSON output (the prompt must ask for JSON).
  Map<String, Object?> body(String system, String prompt) => {
    'model': model,
    'instructions': system,
    'input': prompt,
    'text': {
      'format': {'type': 'json_object'},
    },
    // A summary needs no reasoning (both models accept `none`).
    'reasoning': {'effort': 'none'},
    'store': false,
    'max_output_tokens': 800,
  };

  /// The model's reply to [prompt] as JSON text, or null without a key.
  Future<String?> generate(String system, String prompt) async {
    final apiKey = await key();
    if (apiKey == null) return null;
    // ignore: raft_lints/avoid_unproxied_network_client -- Resolves through HttpOverrides.global (SystemProxy.installGlobally) like the voice session's client.
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(endpoint).timeout(timeout);
      request.headers
        ..set('Authorization', 'Bearer $apiKey')
        ..contentType = ContentType.json;
      request.add(utf8.encode(jsonEncode(body(system, prompt))));
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      if (response.statusCode != 200) {
        throw HttpException('responses ${response.statusCode}');
      }
      return outputText(jsonDecode(text));
    } finally {
      client.close(force: true);
    }
  }

  /// The text of the `message` items of a Responses API reply.
  static String? outputText(Object? reply) {
    if (reply is! Map) return null;
    final out = StringBuffer();
    for (final item in reply['output'] as List? ?? const []) {
      if (item is! Map || item['type'] != 'message') continue;
      for (final part in item['content'] as List? ?? const []) {
        if (part is Map && part['type'] == 'output_text') {
          out.write(part['text'] ?? '');
        }
      }
    }
    final text = out.toString();
    return text.isEmpty ? null : text;
  }
}

/// A small text generation with the key of whichever voice service has one:
/// Gemini when its key exists, else OpenAI, else xAI. Null when there is no
/// key; throws when the service cannot be reached or refuses.
Future<String?> generateWithVoiceKey(String system, String prompt) async {
  if (await AgentVoiceKey.instance.read() != null) {
    return GeminiText.instance.generate(system, prompt);
  }
  if (await OpenAiVoiceKey.instance.read() != null) {
    return ResponsesText.openAi().generate(system, prompt);
  }
  if (await GrokVoiceKey.instance.read() != null) {
    return ResponsesText.xai().generate(system, prompt);
  }
  return null;
}
