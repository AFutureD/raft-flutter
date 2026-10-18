import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/gemini_live.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice.dart';
import 'package:raft_flutter/features/agent_orb/orb_prompt.dart';
import 'package:raft_flutter/features/agent_orb/orb_scope.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/orb_action_world.dart';

/// The agent's language is a setting: kept on the device, pinned in every
/// prompt the agent or the voice reads, asked of Gemini Live where the model
/// takes it, and chosen next to the voice.
void main() {
  const zh = AgentLanguage.zh;
  const en = AgentLanguage.en;
  const keyOf = 'raft.agentDemo.language';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await DevicePreferences.load();
    AgentVoiceSettings.instance.language = zh;
    GeminiLiveSession.forgetSetups();
  });
  tearDown(() {
    AgentVoiceSettings.instance.language = zh;
    GeminiLiveSession.forgetSetups();
  });

  group('the setting', () {
    test('is Chinese until chosen, kept per device, and tells listeners', () {
      final s = AgentVoiceSettings.instance;
      expect(s.language, zh);
      var told = 0;
      void listener() => told++;
      s.addListener(listener);
      addTearDown(() => s.removeListener(listener));
      s.language = en;
      expect(s.language, en);
      expect(DevicePreferences.current!.getString(keyOf), 'en');
      expect(told, 1);
      s.language = zh;
      expect(DevicePreferences.current!.getString(keyOf), 'zh');
    });

    test('the choices are shown by name', () {
      expect(AgentVoiceSettings.languageLabels.keys, [zh, en]);
      expect(AgentVoiceSettings.languageLabels[zh], '中文');
      expect(AgentVoiceSettings.languageLabels[en], 'English');
    });
  });

  group('the prompts pin it', () {
    test('the realtime prompt of the orb, in the language chosen', () {
      expect(orbSystemPrompt(channels: ''), contains(zh.line));
      expect(
        orbSystemPrompt(channels: '', language: en),
        allOf(contains(en.line), isNot(contains(zh.line))),
      );
      // The line is the one the owner asked for.
      expect(zh.line, '始终用中文回答，用户夹杂英文词也不要换语言。');
      // The persona no longer says the opposite.
      expect(orbPromptPersona, isNot(contains('用户说什么语言')));
    });

    test('the text agent, in every state', () {
      for (final (mode, driving) in [
        (OrbMode.normal, false),
        (OrbMode.driving, true),
        (OrbMode.confirming, false),
      ]) {
        for (final language in AgentLanguage.values) {
          final p = orbAgentPrompt(
            mode: mode,
            driving: driving,
            channels: '',
            pending: 'x',
            language: language,
          );
          expect(p, contains(language.line), reason: '$mode $language');
          for (final other in AgentLanguage.values.where(
            (l) => l != language,
          )) {
            expect(p, isNot(contains(other.line)), reason: '$mode $language');
          }
        }
      }
      expect(
        orbAgentScope(
          mode: OrbMode.normal,
          driving: false,
          declarations: const [],
          channels: '',
          language: en,
        ).systemPrompt,
        contains(en.line),
      );
    });

    test(
      'the voice that relays says it in the language, in a short prompt',
      () {
        for (final language in AgentLanguage.values) {
          final p = layeredVoicePromptFor(language);
          expect(p, contains(language.relayLine));
          expect(p, contains('ask_agent'));
          expect(p.length, lessThan(900));
        }
        expect(layeredVoicePromptFor(en), isNot(contains(zh.relayLine)));
        expect(layeredVoicePrompt, layeredVoicePromptFor(zh));
      },
    );

    testWidgets('the orb gives it to the realtime session and to the agent', (
      t,
    ) async {
      AgentVoiceSettings.instance.language = en;
      final f = ActionOrbFixture(t)..agentLayer = false;
      await f.setUp();
      await f.pump();
      await f.startCall();
      expect(f.sessions.single.systemPrompt, contains(en.line));
      expect(f.sessions.single.systemPrompt, isNot(contains(zh.line)));
      await t.pumpWidget(const SizedBox());
      await f.tearDown();

      AgentVoiceSettings.instance.language = zh;
      final g = ActionOrbFixture(t)..agentLayer = true;
      await g.setUp();
      await g.pump();
      await g.startCall();
      expect(
        g.sessions.single.steering!.scope().systemPrompt,
        contains(zh.line),
      );
      AgentVoiceSettings.instance.language = en;
      expect(
        g.sessions.single.steering!.scope().systemPrompt,
        contains(en.line),
      );
      await t.pumpWidget(const SizedBox());
      await g.tearDown();
    });
  });

  group('Gemini Live is asked for it', () {
    GeminiLiveSession live({String? languageCode}) => GeminiLiveSession(
      apiKey: 'secret',
      systemPrompt: 'p',
      tools: const [],
      onToolCall: (n, a) async => {},
      languageCode: languageCode,
    );

    Map<String, Object?> speech(GeminiLiveSession s) {
      final setup =
          s.setupMessage('m', affective: false, nonBlocking: false)['setup']!
              as Map;
      return ((setup['generationConfig']! as Map)['speechConfig']! as Map)
          .cast<String, Object?>();
    }

    test('speechConfig.languageCode is sent when there is a language', () {
      expect(
        speech(live(languageCode: zh.speechCode))['languageCode'],
        'cmn-CN',
      );
      expect(
        speech(live(languageCode: en.speechCode))['languageCode'],
        'en-US',
      );
      expect(speech(live()), isNot(contains('languageCode')));
      expect(speech(live(languageCode: 'cmn-CN')), contains('voiceConfig'));
    });

    test('a model that refuses it has it dropped, and is remembered', () {
      final first = live(languageCode: 'cmn-CN')..useModel('models/m38');
      expect(first.setupFlags.languageCode, isTrue);
      expect(
        first.dropRefused(
          'Unsupported language code cmn-CN',
          nonBlocking: false,
        ),
        'languageCode',
      );
      expect(speech(first), isNot(contains('languageCode')));
      // The other features stay.
      expect(first.setupFlags.affective, isTrue);
      first.rememberSetup();

      final next = live(languageCode: 'cmn-CN')..useModel('models/m38');
      expect(next.setupFlags.languageCode, isFalse);
      expect(speech(next), isNot(contains('languageCode')));
      // Another model has not refused it.
      final other = live(languageCode: 'cmn-CN')..useModel('models/other');
      expect(other.setupFlags.languageCode, isTrue);
      expect(speech(other)['languageCode'], 'cmn-CN');
    });

    test('a refusal that names nothing drops the language first', () {
      final s = live(languageCode: 'cmn-CN')..useModel('models/m');
      expect(
        s.dropRefused('1007 invalid argument', nonBlocking: true),
        'languageCode',
      );
      expect(
        s.dropRefused('1007 invalid argument', nonBlocking: true),
        'affective',
      );
      // Without a language there is nothing of it to drop.
      final plain = live()..useModel('models/p');
      expect(plain.dropRefused('1007', nonBlocking: true), 'affective');
    });
  });

  group('the settings page', () {
    testWidgets('has the picker next to the voices, and changes the language', (
      t,
    ) async {
      t.view.physicalSize = const Size(420, 3600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: const AgentVoiceSettingsPage(),
        ),
      );
      expect(find.text('Agent 语言'), findsOneWidget);
      expect(find.text('中文'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);
      // Just above the voice list.
      expect(
        t.getTopLeft(find.text('Agent 语言')).dy,
        lessThan(t.getTopLeft(find.text('声音')).dy),
      );
      final en = find.byKey(const ValueKey('agent-setting-AgentLanguage.en'));
      await t.tap(en);
      await t.pump();
      expect(AgentVoiceSettings.instance.language, AgentLanguage.en);
      expect(
        DevicePreferences.current!.getString('raft.agentDemo.language'),
        'en',
      );
      await t.tap(find.byKey(const ValueKey('agent-setting-AgentLanguage.zh')));
      await t.pump();
      expect(AgentVoiceSettings.instance.language, AgentLanguage.zh);
    });
  });
}
