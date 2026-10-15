import 'package:flutter/material.dart';

import 'agent_theme.dart';

/// Who spoke a transcript line.
enum AgentSpeaker { you, agent }

/// What the voice session is doing; drives the mic button and its hint.
enum AgentMicState {
  /// Ready: hold to talk, tap for live.
  idle,
  connecting,

  /// Push-to-talk held.
  holding,

  /// Live conversation: the microphone stays open.
  live,
  thinking,
  speaking,
}

/// The bottom of agent mode: captions of the latest exchange and a large mic
/// button. Hold the button to talk, tap it for a live conversation. Typing is
/// secondary, behind the keyboard icon.
class AgentVoiceDock extends StatefulWidget {
  const AgentVoiceDock({
    super.key,
    required this.lines,
    required this.onSubmit,
    this.state = AgentMicState.idle,
    this.onMicDown,
    this.onMicUp,
    this.notice,
    this.hint = '比如 “raft-flutter 现在什么情况？”',
  });

  /// Latest lines, oldest first. The dock shows the last two.
  final List<(AgentSpeaker, String)> lines;
  final ValueChanged<String> onSubmit;
  final AgentMicState state;

  /// The finger touched the mic button.
  final VoidCallback? onMicDown;

  /// The finger left the mic button after [held].
  final ValueChanged<Duration>? onMicUp;

  /// A one-line status shown under the button instead of the usual hint,
  /// e.g. a missing key or a connection error.
  final String? notice;
  final String hint;

  @override
  State<AgentVoiceDock> createState() => _AgentVoiceDockState();
}

class _AgentVoiceDockState extends State<AgentVoiceDock> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _typing = false;
  DateTime? _down;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    widget.onSubmit(value);
    _text.clear();
  }

  void _toggleTyping() {
    setState(() => _typing = !_typing);
    if (_typing) {
      _focus.requestFocus();
    } else {
      _focus.unfocus();
    }
  }

  String get _stateHint => switch (widget.state) {
    AgentMicState.idle => '按住说话 · 点一下实时对话',
    AgentMicState.connecting => '正在连接…',
    AgentMicState.holding => '正在听，松开发送',
    AgentMicState.live => '实时对话中 · 点一下结束',
    AgentMicState.thinking => '正在想…',
    AgentMicState.speaking => '正在回答 · 按住可以打断',
  };

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final shown = widget.lines.length > 2
        ? widget.lines.sublist(widget.lines.length - 2)
        : widget.lines;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (speaker, text) in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Bubble(speaker: speaker, text: text, theme: t),
          ),
        if (_typing)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.layer,
                borderRadius: BorderRadius.circular(t.cardRadius),
                border: Border.all(color: t.line, width: t.border),
              ),
              child: TextField(
                key: const ValueKey('agent-input'),
                controller: _text,
                focusNode: _focus,
                onSubmitted: (_) => _submit(),
                textInputAction: TextInputAction.send,
                style: t.body(14),
                cursorColor: t.foreground,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: widget.hint,
                  hintStyle: t.body(14, color: t.hint),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 56,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _SmallButton(
                  key: const ValueKey('agent-keyboard'),
                  icon: _typing ? Icons.keyboard_hide : Icons.keyboard,
                  label: _typing ? '收起键盘' : '打字',
                  onTap: _toggleTyping,
                  theme: t,
                ),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Listener(
                    onPointerDown: (_) {
                      _down = DateTime.now();
                      widget.onMicDown?.call();
                    },
                    onPointerUp: (_) => _release(),
                    onPointerCancel: (_) => _release(),
                    child: AgentOrb(state: widget.state, size: 76),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.notice ?? _stateHint,
                    key: const ValueKey('agent-mic-hint'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.body(
                      12.5,
                      color: widget.notice == null ? t.muted : t.foreground,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            if (_typing)
              SizedBox(
                width: 56,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _SmallButton(
                    key: const ValueKey('agent-send'),
                    icon: Icons.arrow_upward,
                    label: '发送',
                    onTap: _submit,
                    theme: t,
                  ),
                ),
              )
            else
              const SizedBox(width: 56),
          ],
        ),
      ],
    );
  }

  void _release() {
    final down = _down;
    _down = null;
    if (down != null) widget.onMicUp?.call(DateTime.now().difference(down));
  }
}

class _SmallButton extends StatelessWidget {
  const _SmallButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    required this.theme,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final RaftAgentTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: t.layer,
            shape: t.orbSquare ? BoxShape.rectangle : BoxShape.circle,
            border: Border.all(color: t.line, width: t.cardBorderWidth),
          ),
          child: Icon(icon, size: 20, color: t.foreground),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.speaker,
    required this.text,
    required this.theme,
  });
  final AgentSpeaker speaker;
  final String text;
  final RaftAgentTheme theme;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final agent = speaker == AgentSpeaker.agent;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: agent ? t.hud : t.layer,
        borderRadius: BorderRadius.circular(t.cardRadius),
        border: Border.all(color: agent ? t.hud : t.line, width: t.border),
        boxShadow: t.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              agent ? 'Agent' : '你',
              style: t.body(
                11,
                color: agent ? t.orb : t.hint,
                weight: FontWeight.w700,
              ),
            ),
            Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: t.body(14, color: agent ? t.hudForeground : t.foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// The mic button: brand yellow, square with a hard shadow in Brutal. Turns
/// to the "decision" color while the microphone is open.
class AgentOrb extends StatelessWidget {
  const AgentOrb({super.key, this.state = AgentMicState.idle, this.size = 52});
  final AgentMicState state;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final shape = t.orbSquare ? BoxShape.rectangle : BoxShape.circle;
    final open = state == AgentMicState.holding || state == AgentMicState.live;
    final pressed = state == AgentMicState.holding;
    final fill = open
        ? (t.cardFills?[AgentPriority.decision] ??
              t.priority(AgentPriority.decision))
        : t.orb;
    final icon = switch (state) {
      AgentMicState.idle || AgentMicState.holding => Icons.mic,
      AgentMicState.live => Icons.mic,
      AgentMicState.connecting || AgentMicState.thinking => Icons.more_horiz,
      AgentMicState.speaking => Icons.graphic_eq,
    };
    final shadow = t.orbSquare ? (pressed ? 1.0 : 5.0) : 0.0;
    return Semantics(
      button: true,
      label: '麦克风',
      child: AnimatedContainer(
        key: const ValueKey('agent-orb'),
        duration: const Duration(milliseconds: 120),
        width: size,
        height: size,
        transform: Matrix4.translationValues(
          t.orbSquare && pressed ? 4 : 0,
          t.orbSquare && pressed ? 4 : 0,
          0,
        ),
        decoration: BoxDecoration(
          color: fill,
          shape: shape,
          border: t.orbSquare
              ? Border.all(color: t.line, width: t.border)
              : null,
          boxShadow: [
            if (t.orbSquare)
              BoxShadow(color: t.line, offset: Offset(shadow, shadow))
            else
              BoxShadow(
                color: open ? fill.withValues(alpha: .35) : t.orbHalo,
                spreadRadius: open ? 14 : 7,
              ),
          ],
        ),
        child: Icon(
          icon,
          color: open ? t.foreground : t.orbForeground,
          size: size * .44,
        ),
      ),
    );
  }
}
