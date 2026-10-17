import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_preferences.dart';
import '../agent_mode/agent_engine.dart';
import '../agent_mode/agent_voice_settings.dart' show AgentVoiceSettingsPage;
import '../agent_mode/agent_thinking.dart';
import '../agent_mode/layered_voice_mode.dart';

/// Device-local Labs switch for the Agent orb (phones only). Default off.
class AgentOrbPreference extends ChangeNotifier {
  AgentOrbPreference._();
  static final instance = AgentOrbPreference._();
  static const preferenceKey = 'raft.agentOrb';

  bool? _override;

  bool get enabled {
    if (_override != null) return _override!;
    try {
      return DevicePreferences.current?.getBool(preferenceKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  void setEnabled(bool next) {
    if (next == enabled) return;
    _override = next;
    Future<void> write(SharedPreferences prefs) async {
      try {
        next
            ? await prefs.setBool(preferenceKey, true)
            : await prefs.remove(preferenceKey);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// Whether the orb runs on the agent layer (a text agent behind a voice that
  /// only listens and speaks) rather than on the realtime voice model alone.
  /// On by default in debug builds, off in release.
  static const layerKey = 'raft.agentOrb.layer';
  bool? _layerOverride;

  bool get agentLayer {
    if (_layerOverride != null) return _layerOverride!;
    try {
      return DevicePreferences.current?.getBool(layerKey) ?? kDebugMode;
    } catch (_) {
      return kDebugMode;
    }
  }

  void setAgentLayer(bool next) {
    if (next == agentLayer) return;
    _layerOverride = next;
    Future<void> write(SharedPreferences prefs) async {
      try {
        await prefs.setBool(layerKey, next);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// The brain the orb runs on: the realtime voice model alone, or a voice
  /// model with the text Agent. It is the old "Agent 层" switch under a new
  /// name (same key, so a device with the layer on is on the layered brain).
  AgentBrainMode get brainMode =>
      agentLayer ? AgentBrainMode.layered : AgentBrainMode.voiceOnly;

  void setBrainMode(AgentBrainMode next) =>
      setAgentLayer(next == AgentBrainMode.layered);

  /// The text Agent's model id (`gemini-3.5-flash-lite`, or `provider/model`
  /// for Genkit); null: the app picks a Flash Lite.
  static const agentModelKey = 'raft.agentOrb.agentModel';
  String? _agentModelOverride;
  bool _agentModelSet = false;

  String? get agentModel {
    if (_agentModelSet) return _agentModelOverride;
    try {
      final v = DevicePreferences.current?.getString(agentModelKey)?.trim();
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  void setAgentModel(String? next) {
    final v = next?.trim();
    final model = v == null || v.isEmpty ? null : v;
    if (model == agentModel) return;
    _agentModelOverride = model;
    _agentModelSet = true;
    Future<void> write(SharedPreferences prefs) async {
      try {
        model == null
            ? await prefs.remove(agentModelKey)
            : await prefs.setString(agentModelKey, model);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// How hard the text agent of the agent layer thinks. Low by default; a
  /// change reaches the next session (the orb is built again, like for the
  /// layer switch).
  static const thinkingKey = 'raft.agentOrb.thinking';
  AgentThinking? _thinkingOverride;

  AgentThinking get agentThinking {
    if (_thinkingOverride != null) return _thinkingOverride!;
    try {
      return AgentThinking.parse(
            DevicePreferences.current?.getString(thinkingKey),
          ) ??
          AgentThinking.low;
    } catch (_) {
      return AgentThinking.low;
    }
  }

  void setAgentThinking(AgentThinking next) {
    if (next == agentThinking) return;
    _thinkingOverride = next;
    Future<void> write(SharedPreferences prefs) async {
      try {
        await prefs.setString(thinkingKey, next.name);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// What makes the text agent's model calls: Genkit (the default) or direct
  /// calls to the Gemini API. A change builds the orb again.
  static const engineKey = 'raft.agentOrb.engine';
  AgentEngine? _engineOverride;

  AgentEngine get agentEngine {
    if (_engineOverride != null) return _engineOverride!;
    try {
      return AgentEngine.parse(
            DevicePreferences.current?.getString(engineKey),
          ) ??
          AgentEngine.genkit;
    } catch (_) {
      return AgentEngine.genkit;
    }
  }

  void setAgentEngine(AgentEngine next) {
    if (next == agentEngine) return;
    _engineOverride = next;
    Future<void> write(SharedPreferences prefs) async {
      try {
        await prefs.setString(engineKey, next.name);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  /// How the voice of the agent layer speaks: Live tells the agent's answer in
  /// its own natural voice (the default), or the app reads the agent's words
  /// aloud. A change builds the orb again.
  static const voiceModeKey = 'raft.agentOrb.voiceMode';
  LayeredVoiceMode? _voiceModeOverride;

  LayeredVoiceMode get layeredVoiceMode {
    if (_voiceModeOverride != null) return _voiceModeOverride!;
    try {
      return LayeredVoiceMode.parse(
            DevicePreferences.current?.getString(voiceModeKey),
          ) ??
          LayeredVoiceMode.liveRelays;
    } catch (_) {
      return LayeredVoiceMode.liveRelays;
    }
  }

  void setLayeredVoiceMode(LayeredVoiceMode next) {
    if (next == layeredVoiceMode) return;
    _voiceModeOverride = next;
    Future<void> write(SharedPreferences prefs) async {
      try {
        await prefs.setString(voiceModeKey, next.name);
      } catch (_) {
        /* optional local storage */
      }
    }

    final loaded = DevicePreferences.current;
    if (loaded != null) {
      write(loaded);
    } else {
      SharedPreferences.getInstance().then(write, onError: (_) {});
    }
    notifyListeners();
  }

  @visibleForTesting
  void resetForTest() {
    _agentModelOverride = null;
    _agentModelSet = false;
    _voiceModeOverride = null;
    _override = null;
    _layerOverride = null;
    _thinkingOverride = null;
    _engineOverride = null;
  }
}

/// Labs control for the orb: a switch, and when it is on the way to the
/// Agent settings, where the brain (the realtime voice model alone, or a voice
/// model with the text Agent), the voice, how it speaks and the Agent are
/// chosen. Phone layout only, and in debug and profile builds only, like the
/// Agent mode card next to it.
class AgentOrbLabsCard extends StatelessWidget {
  const AgentOrbLabsCard({super.key});

  static const title = 'Agent 悬浮球（手机）';

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode || !RaftAdaptiveWorkspace.compactOf(context)) {
      return const SizedBox.shrink();
    }
    final pref = AgentOrbPreference.instance;
    final t = RaftTokens.of(context);
    return ListenableBuilder(
      listenable: pref,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(bottom: RaftSpace.x4),
        child: RaftRecipeCard(
          padding: const EdgeInsets.all(RaftSpace.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: RaftCssText(
                      title,
                      style: RaftTypography.body(
                        t,
                        size: 14,
                        line: 20,
                        weight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                  ),
                  RaftSwitch(
                    key: const ValueKey('agent-orb-switch'),
                    value: pref.enabled,
                    semanticLabel: title,
                    onChanged: pref.setEnabled,
                  ),
                ],
              ),
              const SizedBox(height: RaftSpace.x1),
              RaftCssText(
                '悬浮在每个页面上的 Agent：点一下打开对话，长按直接说话，再点一下挂断。'
                '和 Agent 模式共用语音 Key 与声音设置。',
                style: RaftTypography.body(
                  t,
                  size: 13,
                  line: 18,
                  color: t.muted,
                ),
              ),
              if (pref.enabled) ...[
                const SizedBox(height: RaftSpace.x3),
                RaftCssText(
                  '现在：${pref.brainMode.label}',
                  key: const ValueKey('agent-orb-brain-summary'),
                  style: RaftTypography.body(
                    t,
                    size: 13,
                    line: 18,
                    color: t.muted,
                  ),
                ),
                const SizedBox(height: RaftSpace.x2),
                RaftButton(
                  key: const ValueKey('agent-orb-settings-open'),
                  label: 'Agent 设置',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const AgentVoiceSettingsPage(showOrb: true),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
