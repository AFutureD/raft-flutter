import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/workspace_controller.dart';
import '../../data/device_preferences.dart';
import 'agent_mode_page.dart';

/// Device-local opt-in for the agent mode demo. Default off.
class AgentModePreference extends ChangeNotifier {
  AgentModePreference._();
  static final instance = AgentModePreference._();
  static const preferenceKey = 'raft.agentModeDemo';

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

  @visibleForTesting
  void resetForTest() => _override = null;
}

/// Labs control for the demo: a switch and, when on, an entry button.
/// Shown in debug and profile builds only.
class AgentModeLabsCard extends StatelessWidget {
  const AgentModeLabsCard({super.key, required this.controller});
  final WorkspaceController controller;

  @override
  Widget build(BuildContext context) {
    if (kReleaseMode) return const SizedBox.shrink();
    final pref = AgentModePreference.instance;
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
                      'Agent 模式（demo）',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                  ),
                  RaftSwitch(
                    key: const ValueKey('agent-mode-demo-switch'),
                    value: pref.enabled,
                    semanticLabel: 'Agent 模式（demo）',
                    onChanged: pref.setEnabled,
                  ),
                ],
              ),
              const SizedBox(height: RaftSpace.x1),
              RaftCssText(
                'Z 轴叠层的主动提醒与频道摘要。只读，不发送任何内容。',
                style: TextStyle(color: t.muted, fontSize: 13),
              ),
              if (pref.enabled) ...[
                const SizedBox(height: RaftSpace.x3),
                RaftButton(
                  key: const ValueKey('agent-mode-open'),
                  label: '打开 Agent 模式',
                  onPressed: () => openAgentMode(context, controller),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
