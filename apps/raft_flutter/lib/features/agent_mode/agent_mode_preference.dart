import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/workspace_controller.dart';
import '../../data/device_preferences.dart';
import 'agent_audio.dart';
import 'agent_memory.dart';
import 'agent_mode_page.dart';
import 'agent_voice_settings.dart';
import 'voice_provider.dart';

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
                const SizedBox(height: RaftSpace.x3),
                const _VoiceKeyRow(),
                const SizedBox(height: RaftSpace.x2),
                RaftButton(
                  key: const ValueKey('agent-voice-settings-open'),
                  label: '声音设置',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AgentVoiceSettingsPage(
                        agents: AgentBrain(controller).agents,
                      ),
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

/// Keys for the demo's voice (Gemini, OpenAI): scanned from a QR code, kept in
/// secure storage, shown by their last four characters only.
class _VoiceKeyRow extends StatefulWidget {
  const _VoiceKeyRow();

  @override
  State<_VoiceKeyRow> createState() => _VoiceKeyRowState();
}

class _VoiceKeyRowState extends State<_VoiceKeyRow> {
  final _key = AgentVoiceKey.instance;
  final _openAiKey = OpenAiVoiceKey.instance;
  final _grokKey = GrokVoiceKey.instance;
  // ignore: raft_lints/avoid_imperative_notice_state -- Cleared by the next scan; the row is rebuilt when the key changes.
  String? _error;

  @override
  void initState() {
    super.initState();
    _key.read();
    _openAiKey.read();
    _grokKey.read();
  }

  Future<void> _scan() async {
    setState(() => _error = null);
    try {
      final scanned = await AgentAudio.instance.scanCode();
      if (scanned == null) return;
      final saved = await saveScannedKey(
        scanned,
        preferred: AgentVoiceSettings.instance.provider,
      );
      if (saved == null) {
        setState(() => _error = '二维码里没有找到 Key');
      }
    } on PlatformException catch (e) {
      // ignore: raft_lints/avoid_caught_exception_text -- Demo screen: the scanner plugin's own message is the most useful thing to read.
      if (mounted) setState(() => _error = '扫码失败：${e.message ?? e.code}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final scanSupported = AgentAudio.instance.supported;
    return ListenableBuilder(
      listenable: Listenable.merge([_key, _openAiKey, _grokKey]),
      builder: (context, _) {
        final suffix = _key.suffix;
        final openAiSuffix = _openAiKey.suffix;
        final grokSuffix = _grokKey.suffix;
        final anyKey =
            suffix != null || openAiSuffix != null || grokSuffix != null;
        final stored = [
          if (suffix != null) 'Gemini Key ····$suffix',
          if (openAiSuffix != null) 'OpenAI Key ····$openAiSuffix',
          if (grokSuffix != null) 'Grok Key ····$grokSuffix',
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RaftCssText(
              !anyKey
                  ? (scanSupported
                        ? '语音：还没有 Gemini、OpenAI 或 Grok Key。'
                        : '语音：这台设备还不能扫码填入 Key。')
                  : '语音：${stored.join('；')}',
              key: const ValueKey('agent-voice-key-status'),
              style: TextStyle(color: t.muted, fontSize: 13),
            ),
            if (_error != null)
              RaftCssText(
                _error,
                style: TextStyle(
                  color: t.colors['danger'] ?? t.ink,
                  fontSize: 13,
                ),
              ),
            const SizedBox(height: RaftSpace.x2),
            Wrap(
              spacing: RaftSpace.x2,
              runSpacing: RaftSpace.x2,
              children: [
                if (scanSupported)
                  RaftButton(
                    key: const ValueKey('agent-voice-key-scan'),
                    label: !anyKey ? '扫码填入 Key' : '重新扫码',
                    onPressed: _scan,
                  ),
                if (anyKey)
                  RaftButton(
                    key: const ValueKey('agent-voice-key-clear'),
                    label: '清除 Key',
                    onPressed: () {
                      _key.clear();
                      _openAiKey.clear();
                      _grokKey.clear();
                    },
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}
