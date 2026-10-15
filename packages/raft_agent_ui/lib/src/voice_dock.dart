import 'package:flutter/material.dart';

import 'agent_theme.dart';

/// Who spoke a transcript line.
enum AgentSpeaker { you, agent }

/// The bottom of agent mode: the latest exchange, an input and the orb.
///
/// The orb submits the typed request for now; a realtime voice provider can
/// drive [listening] and [lines] later without changing the layout.
class AgentVoiceDock extends StatefulWidget {
  const AgentVoiceDock({
    super.key,
    required this.lines,
    required this.onSubmit,
    this.listening = false,
    this.hint = '问点什么，比如 “raft-flutter 现在什么情况？”',
  });

  /// Latest lines, oldest first. The dock shows the last two.
  final List<(AgentSpeaker, String)> lines;
  final ValueChanged<String> onSubmit;
  final bool listening;
  final String hint;

  @override
  State<AgentVoiceDock> createState() => _AgentVoiceDockState();
}

class _AgentVoiceDockState extends State<AgentVoiceDock> {
  final _text = TextEditingController();
  final _focus = FocusNode();

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
        Row(
          children: [
            Expanded(
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
            const SizedBox(width: 12),
            AgentOrb(listening: widget.listening, onTap: _submit),
          ],
        ),
      ],
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
              style: t.body(14, color: agent ? t.hudForeground : t.foreground),
            ),
          ],
        ),
      ),
    );
  }
}

/// The voice button: brand yellow, square with a hard shadow in Brutal.
class AgentOrb extends StatelessWidget {
  const AgentOrb({
    super.key,
    this.listening = false,
    this.onTap,
    this.size = 52,
  });
  final bool listening;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final shape = t.orbSquare ? BoxShape.rectangle : BoxShape.circle;
    return Semantics(
      button: true,
      label: '发送',
      child: GestureDetector(
        key: const ValueKey('agent-orb'),
        onTap: onTap,
        child: AnimatedContainer(
          duration: t.duration,
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: t.orb,
            shape: shape,
            border: t.orbSquare
                ? Border.all(color: t.line, width: t.border)
                : null,
            boxShadow: [
              if (t.orbSquare)
                BoxShadow(color: t.line, offset: const Offset(3, 3))
              else
                BoxShadow(color: t.orbHalo, spreadRadius: listening ? 12 : 7),
            ],
          ),
          child: Icon(
            Icons.graphic_eq,
            color: t.orbForeground,
            size: size * .46,
          ),
        ),
      ),
    );
  }
}
