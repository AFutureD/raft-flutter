import 'package:flutter/material.dart';

import 'handsfree/hf_scope.dart';
import 'handsfree/hf_strip.dart';
import 'handsfree/hf_tokens.dart';

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

/// The foot of agent mode on a phone or a desktop: the caption strip with the
/// latest words (the agent's, or yours while you speak), and under it (or at
/// its right, on a desktop) the dock: a big mic, a keyboard button and the
/// agent's mood. Hold the mic to talk, tap it for a live conversation. Typing
/// is secondary, behind the keyboard button.
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
    this.mood,
  });

  /// Latest lines, oldest first. The caption strip shows the last one.
  final List<(AgentSpeaker, String)> lines;
  final ValueChanged<String> onSubmit;
  final AgentMicState state;

  /// The finger touched the mic button.
  final VoidCallback? onMicDown;

  /// The finger left the mic button after [held].
  final ValueChanged<Duration>? onMicUp;

  /// A one-line status shown in the strip instead of the usual hint, e.g. a
  /// missing key or a connection error.
  final String? notice;
  final String hint;

  /// The agent's state and mood ([AgentMoodBadge]), in the dock.
  final Widget? mood;


  @override
  State<AgentVoiceDock> createState() => _AgentVoiceDockState();
}

class _AgentVoiceDockState extends State<AgentVoiceDock> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  bool _typing = false;

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

  /// What the strip says: a notice, what the mic is doing while the person
  /// talks, else the latest words (the agent's while it thinks and speaks),
  /// else how to start.
  (String, String) get _caption {
    if (widget.notice != null) return ('AGENT', widget.notice!);
    final talking =
        widget.state == AgentMicState.holding ||
        widget.state == AgentMicState.live ||
        widget.state == AgentMicState.connecting;
    if (talking) return ('AGENT', _stateHint);
    if (widget.lines.isEmpty) {
      return ('AGENT', _stateHint);
    }
    // The agent's words win over the person's own, when it spoke in the last
    // two lines (a typed "算了" is answered before it is echoed).
    final last = widget.lines.last;
    final before = widget.lines.length > 1
        ? widget.lines[widget.lines.length - 2]
        : null;
    final (who, text) = last.$1 == AgentSpeaker.you && before != null
        ? (before.$1 == AgentSpeaker.agent ? before : last)
        : last;
    return (who == AgentSpeaker.agent ? 'AGENT' : '你', text);
  }

  IconData get _micIcon => switch (widget.state) {
    AgentMicState.connecting ||
    AgentMicState.thinking => Icons.more_horiz_rounded,
    AgentMicState.speaking => Icons.graphic_eq_rounded,
    _ => Icons.mic_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final (who, said) = _caption;
    final caption = HfCaptionStrip(
      who: who,
      caption: said,
      textKey: const ValueKey('agent-mic-hint'),
    );
    final dock = HfDock(
      onMicDown: widget.onMicDown,
      onMicUp: widget.onMicUp,
      onKeyboard: _toggleTyping,
      keyboardOpen: _typing,
      moodWidget: widget.mood,
      listening:
          widget.state == AgentMicState.holding ||
          widget.state == AgentMicState.live,
      micIcon: _micIcon,
    );
    final input = _typing
        ? Padding(
            padding: EdgeInsets.only(bottom: hf.sp(12)),
            child: _InputBar(
              controller: _text,
              focus: _focus,
              hint: widget.hint,
              onSubmit: _submit,
            ),
          )
        : null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?input,
        if (hf.phone) ...[
          caption,
          SizedBox(height: hf.sp(14)),
          dock,
        ] else
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: caption),
              SizedBox(width: hf.sp(28)),
              dock,
            ],
          ),
      ],
    );
  }
}

/// The text field and its send button.
class _InputBar extends StatelessWidget {
  const _InputBar({
    required this.controller,
    required this.focus,
    required this.hint,
    required this.onSubmit,
  });
  final TextEditingController controller;
  final FocusNode focus;
  final String hint;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Container(
      padding: EdgeInsets.only(left: hf.sp(14), right: hf.sp(6)),
      decoration: BoxDecoration(
        color: HfColors.card,
        borderRadius: BorderRadius.circular(hf.sp(16)),
        border: Border.all(color: HfColors.ink, width: hf.sp(3)),
        boxShadow: [
          BoxShadow(color: HfColors.sticker, offset: Offset(0, hf.sp(5))),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('agent-input'),
              controller: controller,
              focusNode: focus,
              onSubmitted: (_) => onSubmit(),
              textInputAction: TextInputAction.send,
              style: hf.type(HfType.body),
              cursorColor: HfColors.ink,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                hintText: hint,
                hintStyle: hf.type(HfType.body, color: HfColors.inkMuted),
                contentPadding: EdgeInsets.symmetric(vertical: hf.sp(14)),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: '发送',
            child: GestureDetector(
              key: const ValueKey('agent-send'),
              onTap: onSubmit,
              child: Container(
                width: hf.sp(44),
                height: hf.sp(44),
                decoration: BoxDecoration(
                  color: HfColors.sticker,
                  shape: BoxShape.circle,
                  border: Border.all(color: HfColors.ink, width: hf.sp(3)),
                ),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: hf.sp(24),
                  color: HfColors.ink,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
