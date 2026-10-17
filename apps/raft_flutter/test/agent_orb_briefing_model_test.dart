import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/gemini_text.dart';

void main() {
  Map<String, dynamic> m(
    String n, [
    List<String> methods = const ['generateContent'],
  ]) => {'name': 'models/$n', 'supportedGenerationMethods': methods};

  // Kevin: the briefing can use a faster, smaller model (Flash Lite 3.1)
  // with less thinking.
  group('the briefing model', () {
    test('is the newest stable Flash Lite the key has', () {
      expect(
        GeminiText.pickModel([
          m('gemini-2.5-flash'),
          m('gemini-2.5-flash-lite'),
          m('gemini-3.0-flash'),
          m('gemini-3.1-flash-lite-preview'),
          m('gemini-3.1-flash-lite'),
          m('gemini-3.1-flash-lite-live', ['bidiGenerateContent']),
        ], lite: true),
        'models/gemini-3.1-flash-lite',
      );
    });

    test('falls back to Flash when the key has no Lite', () {
      expect(
        GeminiText.pickModel([
          m('gemini-2.5-flash'),
          m('gemini-3.0-flash'),
        ], lite: true),
        'models/gemini-3.0-flash',
      );
    });

    test('Agent mode keeps the full Flash', () {
      expect(
        GeminiText.pickModel([
          m('gemini-3.0-flash'),
          m('gemini-3.1-flash-lite'),
        ]),
        'models/gemini-3.0-flash',
      );
      expect(GeminiText.instance.lite, isFalse);
      expect(GeminiText.briefing.lite, isTrue);
    });

    test('thinks at the minimal level; Agent mode stays at low', () {
      expect(
        GeminiText.generationConfig('models/gemini-3.1-flash-lite', lite: true),
        containsPair('thinkingConfig', {'thinkingLevel': 'minimal'}),
      );
      expect(
        GeminiText.generationConfig('models/gemini-3.0-flash'),
        containsPair('thinkingConfig', {'thinkingLevel': 'low'}),
      );
      expect(
        GeminiText.generationConfig('models/gemini-2.5-flash-lite', lite: true),
        containsPair('thinkingConfig', {'thinkingBudget': 0}),
      );
      expect(
        GeminiText.generationConfig(
          'models/gemini-3.1-flash-lite',
          lite: true,
          thinking: false,
        ),
        isNot(contains('thinkingConfig')),
      );
    });
  });
}
