import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_preferences.dart';
import '../agent_orb/orb_preference.dart' show AgentOrbPreference;
import 'agent_audio.dart';
import 'agent_engine.dart';
import 'agent_thinking.dart';
import 'layered_voice_mode.dart';
import 'voice_provider.dart';

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

  /// OpenAI Realtime built-in voices; marin and cedar are the recommended ones.
  static const openAiVoices = {
    'marin': 'Marin（推荐）',
    'cedar': 'Cedar（推荐）',
    'alloy': 'Alloy',
    'ash': 'Ash',
    'ballad': 'Ballad',
    'coral': 'Coral',
    'echo': 'Echo',
    'sage': 'Sage',
    'shimmer': 'Shimmer',
    'verse': 'Verse',
  };

  /// xAI Grok Voice built-in voices (`GET /v1/tts/voices`); eve is the
  /// default. The names are the service's own.
  static const grokVoices = {
    'eve': 'Eve',
    'ara': 'Ara',
    'rex': 'Rex',
    'sal': 'Sal',
    'leo': 'Leo',
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
  static const reasoningLabels = {
    AgentReasoning.low: '低',
    AgentReasoning.medium: '中',
    AgentReasoning.high: '高',
  };

  /// Grok Voice has one switch (`reasoning.effort` is `high` or `none`), no
  /// scale, so the choice does not apply to it and it keeps the service's
  /// default (on). See https://docs.x.ai/developers/model-capabilities/audio/speech-to-speech
  static bool reasoningApplies(AgentVoiceProvider provider) =>
      provider != AgentVoiceProvider.grok;

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

  /// Which realtime voice service the conversation runs on.
  AgentVoiceProvider get provider =>
      _enum(AgentVoiceProvider.values, 'provider', AgentVoiceProvider.gemini);
  set provider(AgentVoiceProvider v) => _write('provider', v.name);

  String get openAiVoice {
    final v = _read('openAiVoice');
    return v != null && openAiVoices.containsKey(v)
        ? v
        : openAiVoices.keys.first;
  }

  set openAiVoice(String v) => _write('openAiVoice', v);

  String get grokVoice {
    final v = _read('grokVoice');
    return v != null && grokVoices.containsKey(v) ? v : grokVoices.keys.first;
  }

  set grokVoice(String v) => _write('grokVoice', v);

  /// The chosen voice of [provider].
  String voiceOf(AgentVoiceProvider provider) => switch (provider) {
    AgentVoiceProvider.gemini => voice,
    AgentVoiceProvider.openai => openAiVoice,
    AgentVoiceProvider.grok => grokVoice,
  };

  /// The voices [provider] offers, with how they are shown.
  static Map<String, String> voicesOf(AgentVoiceProvider provider) =>
      switch (provider) {
        AgentVoiceProvider.gemini => voices,
        AgentVoiceProvider.openai => openAiVoices,
        AgentVoiceProvider.grok => grokVoices,
      };

  AgentPace get pace => _enum(AgentPace.values, 'pace', AgentPace.normal);
  set pace(AgentPace v) => _write('pace', v.name);

  /// The reasoning effort of the next voice session (Gemini, OpenAI).
  AgentReasoning get reasoning =>
      _enum(AgentReasoning.values, 'reasoning', AgentReasoning.low);
  set reasoning(AgentReasoning v) => _write('reasoning', v.name);

  AgentWarmth get warmth =>
      _enum(AgentWarmth.values, 'warmth', AgentWarmth.natural);
  set warmth(AgentWarmth v) => _write('warmth', v.name);

  AgentOutput get output =>
      _enum(AgentOutput.values, 'output', AgentOutput.earpiece);
  set output(AgentOutput v) {
    _write('output', v.name);
    applyOutput();
  }

  /// The Raft agent whose memory the voice shares; null keeps its own.
  ({String id, String name})? get brain {
    final id = _read('brainId');
    if (id == null || id.isEmpty) return null;
    return (id: id, name: _read('brainName') ?? id);
  }

  set brain(({String id, String name})? v) {
    _values['brainName'] = v?.name ?? '';
    _write('brainId', v?.id ?? '');
    if (v != null) _write('brainName', v.name);
  }

  /// Send each voice session's summary to [brain] so it remembers it.
  bool get writeBack => _read('writeBack') != 'off';
  set writeBack(bool v) => _write('writeBack', v ? 'on' : 'off');

  /// 录屏模式: play the agent's voice as media instead of as a call, so
  /// Android's screen recorder can capture it (it never records
  /// voice-communication audio). Off by default; the price is that the
  /// phone's echo cancellation no longer covers the speaker, so the mic may
  /// hear the agent when it speaks aloud.
  bool get recordingMode => _read('recording') == 'on';
  set recordingMode(bool v) {
    _write('recording', v ? 'on' : 'off');
    unawaited(applyRecordingMode());
  }

  /// Tells the native side how to play the agent's voice.
  Future<void> applyRecordingMode() async {
    try {
      await _output.invokeMethod('setRecordingMode', recordingMode);
    } catch (_) {
      /* platforms without native audio */
    }
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
///
/// With [showOrb] (opened from the orb's Labs card) it also chooses what the
/// orb runs on: the realtime voice model alone (its service, voice and
/// reasoning below), or a voice model with the text Agent (the voice model
/// for listening and speaking, how it speaks, and the Agent's engine, model
/// and reasoning).
class AgentVoiceSettingsPage extends StatelessWidget {
  const AgentVoiceSettingsPage({
    super.key,
    this.onPreview,
    this.agents,
    this.showOrb = false,
  });

  /// Offer the orb's brain choice, and the Agent's settings with it.
  final bool showOrb;

  /// Plays a short greeting in the given voice; null where no session can
  /// run (the page still saves the choice).
  final ValueChanged<String>? onPreview;

  /// Lists the Raft agents that can share memory; null hides the section
  /// (e.g. the offline demo).
  final Future<List<({String id, String name})>> Function()? agents;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final s = AgentVoiceSettings.instance;
    final orb = AgentOrbPreference.instance;
    Widget section(String title, {Key? key, TextStyle? style}) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Text(title, key: key, style: style ?? t.heading(15)),
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
        listenable: Listenable.merge([s, orb]),
        builder: (context, _) {
          // The voice model of the layered brain listens and speaks: Gemini
          // Live today (the layer is built on its transcript and tool
          // calls); the voice choices below are its.
          final layered = showOrb && orb.brainMode == AgentBrainMode.layered;
          final provider = layered ? AgentVoiceProvider.gemini : s.provider;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (showOrb) ...[
                section('悬浮球'),
                choices(
                  {for (final m in AgentBrainMode.values) m: m.label},
                  orb.brainMode,
                  orb.setBrainMode,
                ),
                section(
                  layered
                      ? '语音模型负责听和说，文字 Agent 负责想和做；确认和结果由 App 把关。下一次对话生效。'
                      : '一个实时语音模型自己听、想、调用工具、说话。下一次对话生效。',
                  key: const ValueKey('agent-orb-brain-note'),
                  style: t.body(12, color: t.hint),
                ),
              ],
              section(layered ? '语音模型（听和说）' : '语音服务'),
              if (layered) ...[
                choices(
                  const {AgentVoiceProvider.gemini: 'Gemini Live'},
                  AgentVoiceProvider.gemini,
                  (_) {},
                ),
                section(
                  '目前听和说用 Gemini Live：它的转写和端点检测是这一层的输入。',
                  key: const ValueKey('agent-orb-voice-model-note'),
                  style: t.body(12, color: t.hint),
                ),
              ] else
                choices(
                  agentVoiceProviderLabels,
                  s.provider,
                  (v) => s.provider = v,
                ),
              _ProviderKeyRow(
                key: ValueKey('agent-provider-key-${provider.name}'),
                provider: provider,
              ),
              section('声音'),
              for (final e in AgentVoiceSettings.voicesOf(provider).entries)
                ListTile(
                  key: ValueKey('agent-voice-${e.key}'),
                  leading: Icon(
                    e.key == s.voiceOf(provider)
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: t.foreground,
                  ),
                  title: Text(e.value, style: t.body(15)),
                  subtitle: provider == AgentVoiceProvider.gemini
                      ? Text(e.key, style: t.body(12, color: t.hint))
                      : null,
                  trailing: onPreview == null
                      ? null
                      : IconButton(
                          tooltip: '试听',
                          icon: Icon(Icons.play_circle_outline, color: t.muted),
                          onPressed: () {
                            _setVoice(s, provider, e.key);
                            onPreview!(e.key);
                          },
                        ),
                  onTap: () => _setVoice(s, provider, e.key),
                ),
              if (layered) ...[
                section('说话方式'),
                choices(
                  {for (final m in LayeredVoiceMode.values) m: m.label},
                  orb.layeredVoiceMode,
                  orb.setLayeredVoiceMode,
                ),
                section(
                  'Live 转述：Live 用自然的声音把 Agent 的答案说出来；要你确认的那句话，App 会核对，漏了就自己再说一遍。'
                  'App 朗读：Live 只听，App 用手机自带的声音读 Agent 的话。',
                  key: const ValueKey('agent-orb-speak-note'),
                  style: t.body(12, color: t.hint),
                ),
                section('文字 Agent'),
                choices(
                  {for (final e in AgentEngine.values) e: e.label},
                  orb.agentEngine,
                  orb.setAgentEngine,
                ),
                _AgentModelField(preference: orb),
                section('Agent 推理强度'),
                choices(
                  {for (final v in AgentThinking.values) v: v.label},
                  orb.agentThinking,
                  orb.setAgentThinking,
                ),
                section(
                  '最少最快；高想得更久、答得更晚。下一次对话生效。',
                  key: const ValueKey('agent-orb-thinking-note'),
                  style: t.body(12, color: t.hint),
                ),
              ] else ...[
                section('推理强度'),
                if (AgentVoiceSettings.reasoningApplies(s.provider)) ...[
                  choices(
                    AgentVoiceSettings.reasoningLabels,
                    s.reasoning,
                    (v) => s.reasoning = v,
                  ),
                  section(
                    '低最快；高想得更久、答得更晚。下一次对话生效。',
                    key: const ValueKey('agent-reasoning-note'),
                    style: t.body(12, color: t.hint),
                  ),
                ] else
                  section(
                    'Grok 只有开和关两档，没有强度可选，这里用服务默认（开）。',
                    key: const ValueKey('agent-reasoning-grok-note'),
                    style: t.body(12, color: t.hint),
                  ),
              ],
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
              section('录屏'),
              SwitchListTile(
                key: const ValueKey('agent-recording-mode'),
                value: s.recordingMode,
                onChanged: (v) => s.recordingMode = v,
                title: Text('录屏模式', style: t.body(15)),
                subtitle: Text(
                  '录屏时用，建议按住说话。Agent 的声音改走媒体通道，系统录屏才能录到；'
                  '外放时可能被麦克风收回去形成回声。',
                  style: t.body(12, color: t.hint),
                ),
              ),
              if (agents != null) ...[
                section('记忆'),
                _BrainPicker(load: agents!, settings: s),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The text Agent's model id: empty lets the app pick a Flash Lite.
class _AgentModelField extends StatefulWidget {
  const _AgentModelField({required this.preference});
  final AgentOrbPreference preference;

  @override
  State<_AgentModelField> createState() => _AgentModelFieldState();
}

class _AgentModelFieldState extends State<_AgentModelField> {
  late final _text = TextEditingController(
    text: widget.preference.agentModel ?? '',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: TextField(
        key: const ValueKey('agent-orb-agent-model'),
        controller: _text,
        autocorrect: false,
        enableSuggestions: false,
        style: t.body(14),
        decoration: InputDecoration(
          labelText: 'Agent 模型',
          hintText: '留空：自动选 Flash Lite',
          helperText: '例：gemini-3.5-flash-lite，或 googleai/…（Genkit）',
          helperStyle: t.body(12, color: t.hint),
        ),
        onChanged: widget.preference.setAgentModel,
      ),
    );
  }
}

void _setVoice(
  AgentVoiceSettings s,
  AgentVoiceProvider provider,
  String voice,
) {
  switch (provider) {
    case AgentVoiceProvider.gemini:
      s.voice = voice;
    case AgentVoiceProvider.openai:
      s.openAiVoice = voice;
    case AgentVoiceProvider.grok:
      s.grokVoice = voice;
  }
}

/// The key of one voice service: whether there is one (last four characters
/// only), scan a QR code to fill it in, clear it.
class _ProviderKeyRow extends StatefulWidget {
  const _ProviderKeyRow({super.key, required this.provider});
  final AgentVoiceProvider provider;

  @override
  State<_ProviderKeyRow> createState() => _ProviderKeyRowState();
}

class _ProviderKeyRowState extends State<_ProviderKeyRow> {
  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared by the next scan; the row is rebuilt (and the error gone) when the provider changes.
  String? _error;

  AgentVoiceKey get _key => voiceKeyFor(widget.provider);

  @override
  void initState() {
    super.initState();
    _key.read();
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    try {
      final scanned = await AgentAudio.instance.scanCode();
      if (scanned == null) return;
      final saved = await saveScannedKey(scanned, preferred: widget.provider);
      if (saved == null && mounted) {
        setState(() => _error = '二维码里没有找到 Key');
      }
    } on PlatformException catch (e) {
      // ignore: raft_lints/avoid_caught_exception_text -- Demo screen: the scanner plugin's own message is the most useful thing to read.
      if (mounted) setState(() => _error = '扫码失败：${e.message ?? e.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final name = agentVoiceProviderLabels[widget.provider];
    return ListenableBuilder(
      listenable: _key,
      builder: (context, _) {
        final suffix = _key.suffix;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                suffix == null ? '还没有 $name Key' : '$name Key ····$suffix',
                key: const ValueKey('agent-provider-key-status'),
                style: t.body(13, color: t.hint),
              ),
              if (_error != null) Text(_error!, style: t.body(13)),
              Wrap(
                spacing: 8,
                children: [
                  if (AgentAudio.instance.supported)
                    TextButton(
                      key: const ValueKey('agent-provider-key-scan'),
                      onPressed: _scan,
                      child: Text(suffix == null ? '扫码填入 Key' : '重新扫码'),
                    ),
                  if (suffix != null)
                    TextButton(
                      key: const ValueKey('agent-provider-key-clear'),
                      onPressed: _key.clear,
                      child: const Text('清除 Key'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BrainPicker extends StatefulWidget {
  const _BrainPicker({required this.load, required this.settings});
  final Future<List<({String id, String name})>> Function() load;
  final AgentVoiceSettings settings;

  @override
  State<_BrainPicker> createState() => _BrainPickerState();
}

class _BrainPickerState extends State<_BrainPicker> {
  // An agent that was archived since it was chosen is not offered any more:
  // the choice falls back to 独立记忆 instead of pointing at it.
  late final _agents = widget.load().then((list) {
    final current = widget.settings.brain?.id;
    if (current != null && !list.any((a) => a.id == current)) {
      widget.settings.brain = null;
    }
    return list;
  });

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final s = widget.settings;
    final current = s.brain?.id;
    Widget option(String? id, String title, String? subtitle) => ListTile(
      key: ValueKey('agent-brain-${id ?? 'none'}'),
      leading: Icon(
        id == current
            ? Icons.radio_button_checked
            : Icons.radio_button_unchecked,
        color: t.foreground,
      ),
      title: Text(title, style: t.body(15)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle, style: t.body(12, color: t.hint)),
      onTap: () => s.brain = id == null ? null : (id: id, name: title),
    );
    return FutureBuilder(
      future: _agents,
      builder: (context, snapshot) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          option(null, '独立记忆', '语音助理只记得这次对话'),
          if (snapshot.connectionState != ConnectionState.done)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else if (snapshot.hasError)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('读取 Agent 列表失败', style: t.body(13, color: t.hint)),
            )
          else
            for (final a
                in snapshot.data ?? const <({String id, String name})>[])
              option(a.id, a.name, '和它共享记忆'),
          SwitchListTile(
            key: const ValueKey('agent-brain-write-back'),
            value: s.writeBack,
            onChanged: current == null ? null : (v) => s.writeBack = v,
            title: Text('通话结束后把要点发给它', style: t.body(15)),
            subtitle: Text(
              '以私信发送，由它自己记进记忆。它的记忆会作为背景发给语音模型。',
              style: t.body(12, color: t.hint),
            ),
          ),
        ],
      ),
    );
  }
}
