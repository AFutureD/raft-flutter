import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/device_preferences.dart';

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

  @visibleForTesting
  void resetForTest() => _override = null;
}

/// Labs control for the orb: a switch. Phone layout only, and in debug and
/// profile builds only, like the Agent mode card next to it.
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
            ],
          ),
        ),
      ),
    );
  }
}
