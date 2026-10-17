import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'orb_controller.dart';
import 'orb_widget.dart';

/// The orb sheet's content (inside [showRaftPresented]'s sheet): the
/// transcript of the conversation, a text input, and the orb docked at the
/// footer's right side with its status.
class OrbSheet extends StatelessWidget {
  const OrbSheet({super.key, required this.controller});
  final OrbController controller;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Listener(
      // A touch here is the orb's, not the app's: it does not end "operating".
      onPointerDown: (_) => controller.markOrbTouch(),
      child: RaftSheet(
        key: const ValueKey('orb-sheet'),
        headerExtent: 44,
        header: Padding(
          padding: const EdgeInsets.symmetric(horizontal: RaftSpace.x4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Agent',
                  style: RaftTypography.heading(t, size: 20, line: 28),
                ),
              ),
              RaftIconButton(
                key: const ValueKey('orb-sheet-close'),
                glyph: RaftGlyph.x,
                tooltip: 'Close',
                visualSize: 32,
                onPressed: controller.closeSheet,
              ),
            ],
          ),
        ),
        body: OrbTranscript(controller: controller),
        footer: OrbSheetFooter(controller: controller),
      ),
    );
  }
}

/// The conversation: what the person said, what the agent said and what its
/// tools did, newest at the bottom.
class OrbTranscript extends StatefulWidget {
  const OrbTranscript({super.key, required this.controller});
  final OrbController controller;

  @override
  State<OrbTranscript> createState() => _OrbTranscriptState();
}

class _OrbTranscriptState extends State<OrbTranscript> {
  int _seen = 0;
  int _seenLength = 0;

  void _follow(ScrollController? scroll, int count, int length) {
    if (count == _seen && length == _seenLength) return;
    _seen = count;
    _seenLength = length;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll != null && scroll.hasClients) {
        scroll.jumpTo(scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final scroll = RaftSheetScope.maybeOf(context)?.scrollController;
    // A tap on the conversation raises a sheet that was lowered to a peek.
    return GestureDetector(
      key: const ValueKey('orb-transcript'),
      behavior: HitTestBehavior.translucent,
      onTap: widget.controller.expandSheet,
      child: _lines(context, t, scroll),
    );
  }

  Widget _lines(BuildContext context, RaftTokens t, ScrollController? scroll) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final entries = widget.controller.entries;
        _follow(
          scroll,
          entries.length,
          entries.isEmpty ? 0 : entries.last.text.length,
        );
        if (entries.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(RaftSpace.x4),
            child: Text(
              '说点什么，或者长按球直接对话',
              style: RaftTypography.body(t, size: 14, line: 20, color: t.muted),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            RaftSpace.x4,
            RaftSpace.x2,
            RaftSpace.x4,
            RaftSpace.x4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: RaftSpace.x3),
                  child: _EntryView(entry: entry),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView({required this.entry});
  final OrbEntry entry;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final body = RaftTypography.body(t, size: 14, line: 20);
    final room = MediaQuery.sizeOf(context).width * .8;
    switch (entry.kind) {
      case OrbEntryKind.user:
        return Align(
          alignment: Alignment.centerRight,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: RaftSpace.x3,
                vertical: RaftSpace.x2,
              ),
              decoration: orbSurface(
                t,
                fill: t.brutal ? t.product.brutalYellow : null,
                radius: 12,
              ),
              child: Text(entry.text, style: body),
            ),
          ),
        );
      case OrbEntryKind.agent:
        return Text(entry.text, style: body);
      case OrbEntryKind.activity:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: RaftSpace.half),
              child: RaftIcon(RaftGlyph.check, size: 14, color: t.muted),
            ),
            const SizedBox(width: RaftSpace.x2),
            Expanded(
              child: Text(
                entry.text,
                style: RaftTypography.body(
                  t,
                  size: 13,
                  line: 18,
                  color: t.muted,
                ),
              ),
            ),
          ],
        );
      case OrbEntryKind.notice:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: RaftSpace.half),
              child: RaftIcon(RaftGlyph.circleAlert, size: 14, color: t.muted),
            ),
            const SizedBox(width: RaftSpace.x2),
            Expanded(
              child: Text(
                entry.text,
                style: RaftTypography.body(
                  t,
                  size: 13,
                  line: 18,
                  color: t.muted,
                ),
              ),
            ),
          ],
        );
    }
  }
}

/// The sheet's footer: the text input over the status line with the orb docked
/// at its right.
class OrbSheetFooter extends StatefulWidget {
  const OrbSheetFooter({super.key, required this.controller});
  final OrbController controller;

  @override
  State<OrbSheetFooter> createState() => _OrbSheetFooterState();
}

class _OrbSheetFooterState extends State<OrbSheetFooter> {
  final text = TextEditingController();
  final focus = FocusNode();

  @override
  void initState() {
    super.initState();
    focus.addListener(_focusChanged);
  }

  /// Going to type raises a sheet that was lowered to a peek.
  void _focusChanged() {
    if (focus.hasFocus) widget.controller.expandSheet();
  }

  @override
  void dispose() {
    focus.removeListener(_focusChanged);
    focus.dispose();
    text.dispose();
    super.dispose();
  }

  void _send([String? _]) {
    final said = text.text.trim();
    if (said.isEmpty) return;
    text.clear();
    widget.controller.sendText(said);
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final state = c.state;
        final chip = orbStatusChip(context, state, connecting: c.connecting);
        final hint = c.notice ?? '点球挂断 · 长按说话';
        return Padding(
          key: const ValueKey('orb-sheet-footer'),
          padding: const EdgeInsets.fromLTRB(
            RaftSpace.x4,
            RaftSpace.x2,
            RaftSpace.x4,
            RaftSpace.x2,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: RaftTextInput(
                      key: const ValueKey('orb-sheet-input'),
                      controller: text,
                      focusNode: focus,
                      hintText: '问点什么，或者说“去 raft-flutter”',
                      semanticLabel: 'Agent',
                      textInputAction: TextInputAction.send,
                      onSubmitted: _send,
                    ),
                  ),
                  const SizedBox(width: RaftSpace.x2),
                  RaftIconButton(
                    key: const ValueKey('orb-sheet-send'),
                    glyph: RaftGlyph.send,
                    tooltip: 'Send',
                    visualSize: 40,
                    onPressed: _send,
                  ),
                ],
              ),
              const SizedBox(height: RaftSpace.x3),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hint,
                      style: RaftTypography.body(
                        t,
                        size: 12,
                        line: 16,
                        color: t.muted,
                      ),
                    ),
                  ),
                  if (chip != null) ...[
                    const SizedBox(width: RaftSpace.x2),
                    Flexible(child: chip),
                  ],
                  const SizedBox(width: RaftSpace.x4),
                  Padding(
                    padding: const EdgeInsets.only(
                      right: RaftSpace.x1,
                      bottom: RaftSpace.x1,
                    ),
                    child: OrbBall(
                      state: state,
                      onTap: c.tapOrb,
                      onLongPress: c.longPressOrb,
                    ),
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
