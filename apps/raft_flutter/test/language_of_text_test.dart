import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_language.dart';
import 'package:raft_flutter/features/agent_mode/voice_layer_text.dart';

/// One language per turn: the language of what the person said, the saved
/// setting only when the words have no letters.
void main() {
  for (final setting in AgentLanguage.values) {
    group('setting ${setting.name}', () {
      test('Chinese is zh', () {
        expect(languageOfText('读一下未读', setting), AgentLanguage.zh);
      });
      test('Latin letters alone are en', () {
        expect(languageOfText('read my unread', setting), AgentLanguage.en);
      });
      test('mixed text with Chinese is zh', () {
        expect(languageOfText('打开 Activity', setting), AgentLanguage.zh);
      });
      test('kana and Hangul count as CJK', () {
        expect(languageOfText('こんにちは', setting), AgentLanguage.zh);
        expect(languageOfText('안녕하세요', setting), AgentLanguage.zh);
      });
      test('no letters take the setting', () {
        expect(languageOfText('136', setting), setting);
        expect(languageOfText('#136 !?', setting), setting);
        expect(languageOfText('', setting), setting);
        expect(languageOfText('   ', setting), setting);
      });
    });
  }
}
