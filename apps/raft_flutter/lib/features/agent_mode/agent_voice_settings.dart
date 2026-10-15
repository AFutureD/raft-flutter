import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_preferences.dart';

enum AgentPace { slow, normal, fast }

enum AgentOutput { earpiece, speaker }

enum AgentWarmth { restrained, natural, close }

/// How the voice agent sounds, kept on this device and adjustable any time.
class AgentVoiceSettings extends ChangeNotifier {
  AgentVoiceSettings._();
  static final instance = AgentVoiceSettings._();

  /// Gemini prebuilt voices that suit the persona, with how they sound.
  static const voices = {
    'Sulafat': '温暖',
    'Achernar': '柔和',
    'Vindemiatrix': '温柔',
    'Aoede': '轻快',
    'Despina': '顺滑',
    'Kore': '坚定',
  };
  static const paceLabels = {
    AgentPace.slow: '慢一点',
    AgentPace.normal: '正常',
    AgentPace.fast: '快一点',
  };
  static const outputLabels = {
    AgentOutput.earpiece: '听筒',
    AgentOutput.speaker: '扬声器',
  };
  static const warmthLabels = {
    AgentWarmth.restrained: '克制',
    AgentWarmth.natural: '自然',
    AgentWarmth.close: '更亲近',
  };

  static const _prefix = 'raft.agentDemo.';
  static const _output = MethodChannel('app.raft/agent-audio');

  /// This run's choices; device storage keeps them across launches when it
  /// is available.
  final _values = <String, String>{};

  String? _read(String key) {
    final local = _values[key];
    if (local != null) return local;
    try {
      return DevicePreferences.current?.getString('$_prefix$key');
    } catch (_) {
      return null;
    }
  }

  void _write(String key, String value) {
    _values[key] = value;
    Future<void> store(SharedPreferences prefs) async {
      try {
        await prefs.setString('$_prefix$key', value);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      store(loaded);
    } else {
      SharedPreferences.getInstance().then(store, onError: (_) {});
    }
    notifyListeners();
  }

  T _enum<T extends Enum>(List<T> values, String key, T fallback) =>
      values.where((v) => v.name == _read(key)).firstOrNull ?? fallback;

  String get voice {
    final v = _read('voice');
    return v != null && voices.containsKey(v) ? v : voices.keys.first;
  }

  set voice(String v) => _write('voice', v);

  AgentPace get pace => _enum(AgentPace.values, 'pace', AgentPace.normal);
  set pace(AgentPace v) => _write('pace', v.name);

  AgentWarmth get warmth =>
      _enum(AgentWarmth.values, 'warmth', AgentWarmth.natural);
  set warmth(AgentWarmth v) => _write('warmth', v.name);

  AgentOutput get output =>
      _enum(AgentOutput.values, 'output', AgentOutput.earpiece);
  set output(AgentOutput v) {
    _write('output', v.name);
    applyOutput();
  }

  /// Tells the native side where speech goes (a headset always wins).
  Future<void> applyOutput() async {
    try {
      await _output.invokeMethod('setOutput', output.name);
    } catch (_) {
      /* platforms without native audio */
    }
  }

  /// Prompt lines for pace and warmth.
  String get styleNote {
    final pace = switch (this.pace) {
      AgentPace.slow => '语速放慢一些，句子之间留一点停顿。',
      AgentPace.normal => '',
      AgentPace.fast => '语速稍快、干脆利落，少用停顿。',
    };
    final warmth = switch (this.warmth) {
      AgentWarmth.restrained => '这次的语气克制一些：友好但不过分亲昵，少开玩笑，主要讲结论。',
      AgentWarmth.natural => '',
      AgentWarmth.close => '这次可以更亲近一些：像很熟的朋友，多一点关心和俏皮，但回答仍然简短。',
    };
    return [pace, warmth].where((s) => s.isNotEmpty).join('\n');
  }
}

/// Settings page for the voice: voice (with preview), pace, output, warmth.
class AgentVoiceSettingsPage extends StatelessWidget {
  const AgentVoiceSettingsPage({super.key, this.onPreview});

  /// Plays a short greeting in the given voice; null where no session can
  /// run (the page still saves the choice).
  final ValueChanged<String>? onPreview;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final s = AgentVoiceSettings.instance;
    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Text(title, style: t.heading(15)),
    );
    Widget choices<T>(Map<T, String> labels, T current, ValueChanged<T> on) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final e in labels.entries)
                ChoiceChip(
                  key: ValueKey('agent-setting-${e.key}'),
                  label: Text(e.value, style: t.body(13)),
                  selected: e.key == current,
                  onSelected: (_) => on(e.key),
                ),
            ],
          ),
        );
    return Scaffold(
      backgroundColor: t.canvas,
      appBar: AppBar(
        backgroundColor: t.canvas,
        foregroundColor: t.foreground,
        elevation: 0,
        title: Text('声音设置', style: t.heading(17)),
      ),
      body: ListenableBuilder(
        listenable: s,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            section('声音'),
            for (final e in AgentVoiceSettings.voices.entries)
              ListTile(
                key: ValueKey('agent-voice-${e.key}'),
                leading: Icon(
                  e.key == s.voice
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: t.foreground,
                ),
                title: Text(e.value, style: t.body(15)),
                subtitle: Text(e.key, style: t.body(12, color: t.hint)),
                trailing: onPreview == null
                    ? null
                    : IconButton(
                        tooltip: '试听',
                        icon: Icon(Icons.play_circle_outline, color: t.muted),
                        onPressed: () {
                          s.voice = e.key;
                          onPreview!(e.key);
                        },
                      ),
                onTap: () => s.voice = e.key,
              ),
            section('语速'),
            choices(AgentVoiceSettings.paceLabels, s.pace, (v) => s.pace = v),
            section('性格'),
            choices(
              AgentVoiceSettings.warmthLabels,
              s.warmth,
              (v) => s.warmth = v,
            ),
            section('出声位置'),
            choices(
              AgentVoiceSettings.outputLabels,
              s.output,
              (v) => s.output = v,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                '插上耳机时总是从耳机出声。语速和性格从下一句开始生效。',
                style: t.body(12, color: t.hint),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
