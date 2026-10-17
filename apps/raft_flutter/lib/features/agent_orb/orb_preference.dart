import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_preferences.dart';
import '../agent_mode/agent_thinking.dart';

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

  @visibleForTesting
  void resetForTest() {
    _override = null;
    _layerOverride = null;
    _thinkingOverride = null;
  }
}

/// Labs control for the orb: a switch. Phone layout only, and in debug and
/// profile builds only, like the Agent mode card next to it.
class AgentOrbLabsCard extends StatelessWidget {
  const AgentOrbLabsCard({super.key});

  static const title = 'Agent 悬浮球（手机）';
  static const layerTitle = 'Agent 层';
  static const thinkingTitle = '文本 Agent 推理强度';

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
              const SizedBox(height: RaftSpace.x3),
              Row(
                children: [
                  Expanded(
                    child: RaftCssText(
                      layerTitle,
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
                    key: const ValueKey('agent-orb-layer-switch'),
                    value: pref.agentLayer,
                    semanticLabel: layerTitle,
                    onChanged: pref.setAgentLayer,
                  ),
                ],
              ),
              const SizedBox(height: RaftSpace.x1),
              RaftCssText(
                '用文字模型当 Agent，语音只负责听和说，确认和结果由 App 来说。需要 Gemini Key。'
                '关掉就用实时语音模型直接做。',
                style: RaftTypography.body(
                  t,
                  size: 13,
                  line: 18,
                  color: t.muted,
                ),
              ),
              if (pref.agentLayer) ...[
                const SizedBox(height: RaftSpace.x3),
                RaftCssText(
                  thinkingTitle,
                  style: RaftTypography.body(
                    t,
                    size: 14,
                    line: 20,
                    weight: FontWeight.w600,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: RaftSpace.x2),
                RaftSegmentedControl<AgentThinking>(
                  key: const ValueKey('agent-orb-thinking'),
                  label: thinkingTitle,
                  value: pref.agentThinking,
                  onChanged: pref.setAgentThinking,
                  items: [
                    for (final v in AgentThinking.values)
                      RaftSegmentedOption(
                        value: v,
                        label: v.label,
                        itemKey: ValueKey('agent-orb-thinking-${v.name}'),
                      ),
                  ],
                ),
                const SizedBox(height: RaftSpace.x1),
                RaftCssText(
                  '最少最快；高想得更久、答得更晚。下一次对话生效。',
                  style: RaftTypography.body(
                    t,
                    size: 13,
                    line: 18,
                    color: t.muted,
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
