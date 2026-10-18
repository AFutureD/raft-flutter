import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/data/device_preferences.dart';
import 'package:raft_flutter/features/agent_mode/agent_voice_settings.dart';
import 'package:raft_flutter/features/agent_mode/layered_voice_mode.dart';
import 'package:raft_flutter/features/agent_mode/voice_provider.dart';
import 'package:raft_flutter/features/agent_orb/orb_preference.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The voice model of the layered brain (voice model + text Agent) is chosen
/// among Gemini Live, OpenAI Realtime and Grok Voice; each keeps its own
/// model and voice.

void main() {
  final pref = AgentOrbPreference.instance;
  final s = AgentVoiceSettings.instance;

  Future<void> reset([Map<String, Object> stored = const {}]) async {
    SharedPreferences.setMockInitialValues(stored);
    await DevicePreferences.load();
    pref.resetForTest();
    s.provider = AgentVoiceProvider.gemini;
    s.layeredProvider = AgentVoiceProvider.gemini;
    s.liveModelChoice = AgentVoiceSettings.liveModelAuto;
    s.openAiModel = AgentVoiceSettings.openAiModels.keys.first;
    s.grokModel = AgentVoiceSettings.grokModels.keys.first;
    s.voice = AgentVoiceSettings.voices.keys.first;
    s.openAiVoice = AgentVoiceSettings.openAiVoices.keys.first;
    s.grokVoice = AgentVoiceSettings.grokVoices.keys.first;
  }

  setUp(reset);
  tearDown(reset);

  group('the preferences', () {
    test('the layered service is its own, Gemini until chosen', () {
      expect(s.layeredProvider, AgentVoiceProvider.gemini);
      s.layeredProvider = AgentVoiceProvider.grok;
      expect(s.layeredProvider, AgentVoiceProvider.grok);
      expect(s.provider, AgentVoiceProvider.gemini, reason: 'voice-only own');
      s.provider = AgentVoiceProvider.openai;
      expect(s.layeredProvider, AgentVoiceProvider.grok);
    });

    test('the layered service is kept under its key and read back', () async {
      s.layeredProvider = AgentVoiceProvider.openai;
      await pumpEventQueue();
      expect(
        DevicePreferences.current!.getString('raft.agentDemo.layeredProvider'),
        'openai',
      );
    });

    test('a stored service or model that is unknown falls back', () {
      s.layeredProvider = AgentVoiceProvider.openai;
      // Written as a stored value another build might have left.
      s.openAiModel = 'gpt-realtime-9';
      s.grokModel = 'grok-voice-9';
      expect(s.openAiModel, 'gpt-realtime-2.1-mini');
      expect(s.grokModel, 'grok-voice-latest');
    });

    test('the OpenAI and Grok models: defaults, choice, id to ask for', () {
      expect(AgentVoiceSettings.openAiModels.keys.toList(), [
        'gpt-realtime-2.1-mini',
        'gpt-realtime-2.1',
        'gpt-realtime-2',
      ]);
      expect(AgentVoiceSettings.grokModels.keys.toList(), [
        'grok-voice-latest',
        'grok-voice-3.0',
      ]);
      expect(s.openAiModel, 'gpt-realtime-2.1-mini');
      expect(s.grokModel, 'grok-voice-latest');
      s.setModelChoice(AgentVoiceProvider.openai, 'gpt-realtime-2');
      s.setModelChoice(AgentVoiceProvider.grok, 'grok-voice-3.0');
      expect(s.openAiModel, 'gpt-realtime-2');
      expect(s.grokModel, 'grok-voice-3.0');
      expect(s.modelChoiceOf(AgentVoiceProvider.openai), 'gpt-realtime-2');
      expect(s.modelChoiceOf(AgentVoiceProvider.grok), 'grok-voice-3.0');
      expect(s.realtimeModelOf(AgentVoiceProvider.openai), 'gpt-realtime-2');
      expect(s.realtimeModelOf(AgentVoiceProvider.grok), 'grok-voice-3.0');
    });

    test('Gemini keeps its Live model choice; automatic asks for none', () {
      expect(
        AgentVoiceSettings.modelsOf(AgentVoiceProvider.gemini),
        AgentVoiceSettings.liveModelLabels,
      );
      expect(
        s.modelChoiceOf(AgentVoiceProvider.gemini),
        AgentVoiceSettings.liveModelAuto,
      );
      expect(s.realtimeModelOf(AgentVoiceProvider.gemini), isNull);
      final id = AgentVoiceSettings.liveModelLabels.keys.last;
      s.setModelChoice(AgentVoiceProvider.gemini, id);
      expect(s.liveModelChoice, id);
      expect(s.realtimeModelOf(AgentVoiceProvider.gemini), id);
    });

    test('every service has its own models and voices', () {
      for (final p in AgentVoiceProvider.values) {
        expect(AgentVoiceSettings.modelsOf(p), isNotEmpty);
        expect(AgentVoiceSettings.voicesOf(p), isNotEmpty);
      }
      s.openAiVoice = 'cedar';
      s.grokVoice = 'rex';
      s.voice = 'Kore';
      expect(s.voiceOf(AgentVoiceProvider.openai), 'cedar');
      expect(s.voiceOf(AgentVoiceProvider.grok), 'rex');
      expect(s.voiceOf(AgentVoiceProvider.gemini), 'Kore');
    });

    test('a choice survives a restart: read from the device storage', () async {
      s.layeredProvider = AgentVoiceProvider.grok;
      s.grokModel = 'grok-voice-3.0';
      s.openAiModel = 'gpt-realtime-2.1';
      await pumpEventQueue();
      final stored = DevicePreferences.current!;
      expect(stored.getString('raft.agentDemo.grokModel'), 'grok-voice-3.0');
      expect(
        stored.getString('raft.agentDemo.openAiModel'),
        'gpt-realtime-2.1',
      );
    });
  });

  group('the settings page, layered', () {
    Future<void> open(WidgetTester t) async {
      t.view.physicalSize = const Size(420, 4800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      pref.setBrainMode(AgentBrainMode.layered);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: const AgentVoiceSettingsPage(showOrb: true),
        ),
      );
    }

    Finder key(String k) => find.byKey(ValueKey(k));
    Finder chip(AgentVoiceProvider p) =>
        key('agent-setting-AgentVoiceProvider.${p.name}');

    testWidgets('three voice services; Gemini first, with its own model '
        'list, key and voices', (t) async {
      await open(t);
      expect(find.text('Gemini Live'), findsOneWidget);
      expect(find.text('OpenAI Realtime'), findsOneWidget);
      expect(find.text('Grok Voice'), findsOneWidget);
      expect(key('agent-provider-key-gemini'), findsOneWidget);
      expect(key('agent-orb-agent-key-note'), findsNothing);
      expect(key('agent-live-model-note'), findsOneWidget);
      expect(key('agent-setting-auto'), findsOneWidget);
      expect(key('agent-voice-Sulafat'), findsOneWidget);
      expect(
        find.textContaining('用 Gemini Live 听和说，也可以让 Live 自己调用 ask_agent'),
        findsOneWidget,
      );
      expect(find.text('语音模型版本'), findsOneWidget);
    });

    testWidgets('OpenAI: its models, voices and key, and the Gemini key of '
        'the text Agent', (t) async {
      await open(t);
      await t.tap(chip(AgentVoiceProvider.openai));
      await t.pump();
      expect(s.layeredProvider, AgentVoiceProvider.openai);
      expect(s.provider, AgentVoiceProvider.gemini);
      for (final label in AgentVoiceSettings.openAiModels.values) {
        expect(find.text(label), findsOneWidget);
      }
      for (final id in AgentVoiceSettings.openAiVoices.keys) {
        expect(key('agent-voice-$id'), findsOneWidget);
      }
      expect(key('agent-voice-Sulafat'), findsNothing);
      expect(key('agent-setting-auto'), findsNothing);
      expect(key('agent-live-model-note'), findsNothing);
      expect(key('agent-realtime-model-note'), findsOneWidget);
      expect(key('agent-provider-key-openai'), findsOneWidget);
      expect(key('agent-provider-key-agent-gemini'), findsOneWidget);
      expect(find.text('文字 Agent 一直用 Gemini，需要 Gemini Key。'), findsOneWidget);
      expect(find.text('Gemini Key', findRichText: true), findsNothing);
      expect(find.textContaining('OpenAI/Grok 只负责听和转写'), findsOneWidget);
      expect(find.text('下一次对话生效。'), findsOneWidget);
    });

    testWidgets('Grok: its models and voices', (t) async {
      await open(t);
      await t.tap(chip(AgentVoiceProvider.grok));
      await t.pump();
      expect(s.layeredProvider, AgentVoiceProvider.grok);
      for (final label in AgentVoiceSettings.grokModels.values) {
        expect(find.text(label), findsOneWidget);
      }
      for (final label in AgentVoiceSettings.openAiModels.values) {
        expect(find.text(label), findsNothing);
      }
      for (final id in AgentVoiceSettings.grokVoices.keys) {
        expect(key('agent-voice-$id'), findsOneWidget);
      }
      expect(key('agent-provider-key-grok'), findsOneWidget);
      expect(key('agent-orb-agent-key-note'), findsOneWidget);
    });

    testWidgets('the language chips are there for all three', (t) async {
      await open(t);
      for (final p in AgentVoiceProvider.values) {
        await t.tap(chip(p));
        await t.pump();
        expect(find.text('Agent 语言'), findsOneWidget);
        for (final l in AgentVoiceSettings.languageLabels.values) {
          expect(find.text(l), findsWidgets);
        }
        expect(find.textContaining('对 Gemini、OpenAI、Grok 都一样'), findsOneWidget);
      }
    });

    testWidgets('each service keeps its own model and voice when switching', (
      t,
    ) async {
      await open(t);
      await t.tap(chip(AgentVoiceProvider.openai));
      await t.pump();
      await t.tap(key('agent-setting-gpt-realtime-2'));
      await t.tap(key('agent-voice-cedar'));
      await t.pump();
      await t.tap(chip(AgentVoiceProvider.grok));
      await t.pump();
      await t.tap(key('agent-setting-grok-voice-3.0'));
      await t.tap(key('agent-voice-rex'));
      await t.pump();
      await t.tap(chip(AgentVoiceProvider.gemini));
      await t.pump();
      await t.tap(key('agent-voice-Kore'));
      await t.pump();
      expect(s.openAiModel, 'gpt-realtime-2');
      expect(s.openAiVoice, 'cedar');
      expect(s.grokModel, 'grok-voice-3.0');
      expect(s.grokVoice, 'rex');
      expect(s.voice, 'Kore');
      // Back on OpenAI the page shows what it chose there.
      await t.tap(chip(AgentVoiceProvider.openai));
      await t.pump();
      final selected = t.widget<ChoiceChip>(
        key('agent-setting-gpt-realtime-2'),
      );
      expect(selected.selected, isTrue);
      final leading = t.widget<ListTile>(key('agent-voice-cedar')).leading!;
      expect((leading as Icon).icon, Icons.radio_button_checked);
    });

    testWidgets('how it speaks and the Agent are still below', (t) async {
      await open(t);
      await t.tap(chip(AgentVoiceProvider.openai));
      await t.pump();
      for (final m in LayeredVoiceMode.values) {
        expect(find.text(m.label), findsOneWidget);
      }
      expect(key('agent-orb-agent-model'), findsOneWidget);
      expect(
        find.textContaining('OpenAI / Grok 的“转述”：由 App 决定说什么'),
        findsOneWidget,
      );
    });
  });

  group('the settings page, voice model alone', () {
    testWidgets('keeps its own service and does not touch the layered one', (
      t,
    ) async {
      t.view.physicalSize = const Size(420, 4200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      pref.setBrainMode(AgentBrainMode.voiceOnly);
      s.layeredProvider = AgentVoiceProvider.grok;
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.brutal),
          home: const AgentVoiceSettingsPage(showOrb: true),
        ),
      );
      expect(find.text('Gemini Live'), findsNothing);
      expect(find.text('OpenAI Realtime'), findsNothing);
      expect(find.text('语音服务'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('agent-provider-key-gemini')),
        findsOneWidget,
      );
      await t.tap(
        find.byKey(ValueKey('agent-setting-${AgentVoiceProvider.openai}')),
      );
      await t.pump();
      expect(s.provider, AgentVoiceProvider.openai);
      expect(s.layeredProvider, AgentVoiceProvider.grok);
      expect(
        find.byKey(const ValueKey('agent-orb-agent-key-note')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('agent-setting-gpt-realtime-2')),
        findsNothing,
        reason: 'the model choice of the voice model alone is Gemini only',
      );
    });
  });

  // Renders the layered page (OpenAI Realtime selected) in both themes into
  // $RAFT_SCREENSHOT_DIR; skipped when it is not set.
  final shotDir = Platform.environment['RAFT_SCREENSHOT_DIR'];
  group('the screenshot', () {
    const size = Size(412, 2560);
    const ratio = 2.0;

    Future<void> loadCjk() async {
      // The theme's own Latin fonts, so only the Chinese comes from Noto.
      for (final f in ['HankenGrotesk', 'Geist', 'GeistMono', 'Inter']) {
        final data = ['', '../../']
            .map((up) => File('${up}packages/raft_ui/assets/fonts/$f.ttf'))
            .firstWhere((file) => file.existsSync())
            .readAsBytesSync();
        final loader = FontLoader('packages/raft_ui/$f')
          ..addFont(Future.value(ByteData.sublistView(data)));
        await loader.load();
      }
      final bytes = File(
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
      ).readAsBytesSync();
      // The theme falls back to these families for Chinese glyphs.
      for (final family in ['Noto Sans CJK JP', 'Noto Sans CJK SC']) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }

    Future<ui.Image> render(WidgetTester t, ThemeData theme) async {
      final boundary = GlobalKey();
      t.view.physicalSize = size * ratio;
      t.view.devicePixelRatio = ratio;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: const AgentVoiceSettingsPage(showOrb: true),
          ),
        ),
      );
      await t.pump();
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      return (await t.runAsync(() => render.toImage(pixelRatio: ratio)))!;
    }

    testWidgets('layered settings, OpenAI Realtime selected, light and dark', (
      t,
    ) async {
      pref.setBrainMode(AgentBrainMode.layered);
      s.layeredProvider = AgentVoiceProvider.openai;
      await t.runAsync(loadCjk);
      final light = await render(t, raftTheme(RaftFamily.brutal));
      final dark = await render(t, raftTheme(RaftFamily.elegant, dark: true));
      Future<void> write(String name, ui.Image image) async {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$shotDir/$name').writeAsBytesSync(data!.buffer.asUint8List());
      }

      await t.runAsync(() async {
        Directory(shotDir!).createSync(recursive: true);
        await write('settings-light.png', light);
        await write('settings-dark.png', dark);
        final gap = 24;
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawRect(
          Rect.fromLTWH(
            0,
            0,
            light.width + dark.width + gap * 1.0,
            light.height * 1.0,
          ),
          Paint()..color = const Color(0xFF888888),
        );
        canvas.drawImage(light, Offset.zero, Paint());
        canvas.drawImage(dark, Offset(light.width + gap * 1.0, 0), Paint());
        final picture = recorder.endRecording();
        final both = await picture.toImage(
          light.width + dark.width + gap,
          light.height,
        );
        picture.dispose();
        await write('settings.png', both);
        both.dispose();
      });
      light.dispose();
      dark.dispose();
    }, skip: shotDir == null);
  });
}
