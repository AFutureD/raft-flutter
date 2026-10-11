// Presentational pieces of Web ForwardComposerDesktop
// (packages/web/src/components/message/ForwardComposerDesktop.tsx): the
// two-pane dialog card. The app owns targets, search and sending.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'dialog_card.dart' show RaftShadowSet;
import 'icons.dart';
import 'theme.dart';

Color _rule(RaftTokens t) => t.brutal ? Colors.black : t.colors['line-muted']!;
Color _panel(RaftTokens t) =>
    t.brutal ? Colors.white : t.colors['layer-panel']!;

/// `text-xs font-bold` strong label (selected count, Clear, error).
TextStyle _label(RaftTokens t) => TextStyle(
  fontFamily: t.headingFont,
  fontSize: 12,
  height: 16 / 12,
  fontWeight: FontWeight.w700,
  color: t.strong,
  leadingDistribution: TextLeadingDistribution.even,
);

/// `Card h-[min(clamp(30rem,72dvh,46rem),100dvh-2rem)]
/// w-[min(clamp(48rem,60vw,60rem),100vw-2rem)]` with the header, the
/// `clamp(19rem,24vw,22rem)` destination column and the preview / note column.
class RaftForwardDesktopDialog extends StatelessWidget {
  const RaftForwardDesktopDialog({
    super.key,
    required this.title,
    required this.subtitle,
    required this.close,
    required this.search,
    required this.selectedLabel,
    required this.rows,
    required this.preview,
    required this.noteLabel,
    required this.note,
    required this.send,
    this.clearLabel,
    this.onClear,
    this.showClear = false,
    this.error,
  });

  final String title, subtitle, selectedLabel, noteLabel;
  final String? clearLabel, error;

  /// The header close action.
  final Widget close;

  /// The destination search field ([RaftForwardDesktopSearch]).
  final Widget search;

  /// Whether the "Clear" link shows; [onClear] null renders it inert.
  final bool showClear;
  final VoidCallback? onClear;

  /// Destination rows (6px apart).
  final List<Widget> rows;

  /// The forwarded-bundle preview.
  final Widget preview;

  /// The note editor ([RaftForwardDesktopNoteField]) and its send action.
  final Widget note, send;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = math.min(
      size.width - 32,
      (size.width * .6).clamp(768.0, 960.0),
    );
    final height = math.min(
      size.height - 32,
      (size.height * .72).clamp(480.0, 736.0),
    );
    final side = (size.width * .24).clamp(304.0, 352.0);
    final rule = _rule(t);
    final panel = _panel(t);
    final label = _label(t);
    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          key: const ValueKey('forward-dialog'),
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: panel,
            border: Border.all(color: rule, width: t.brutal ? 2 : 1),
            borderRadius: BorderRadius.circular(t.brutal ? 0 : 8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: rule, width: 2)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: RaftTypography.heading(t, size: 16, line: 24),
                          ),
                          Text(
                            subtitle,
                            style: RaftTypography.mono(
                              t,
                              size: 12,
                              line: 16,
                              color: t.brutal
                                  ? Colors.black.withValues(alpha: .55)
                                  : t.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    close,
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: side,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border(right: BorderSide(color: rule, width: 2)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          search,
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 24,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  selectedLabel,
                                  key: const ValueKey('forward-selected-count'),
                                  style: label,
                                ),
                                if (showClear)
                                  GestureDetector(
                                    onTap: onClear,
                                    child: Text(
                                      clearLabel ?? '',
                                      style: label.copyWith(
                                        decoration: TextDecoration.underline,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ListView(
                              padding: EdgeInsets.zero,
                              children: [
                                for (final (i, row) in rows.indexed) ...[
                                  if (i > 0) const SizedBox(height: 6),
                                  row,
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (error != null)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 8),
                                      child: Text(error!, style: label),
                                    ),
                                  preview,
                                ],
                              ),
                            ),
                          ),
                          _NoteBar(
                            noteLabel: noteLabel,
                            note: note,
                            send: send,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `border-t-2 bg-layer-panel p-3`: "Optional note" + the compact composer
/// (`border-2 p-2`, 40px editor, 28px accent send button).
class _NoteBar extends StatelessWidget {
  const _NoteBar({
    required this.noteLabel,
    required this.note,
    required this.send,
  });
  final String noteLabel;
  final Widget note, send;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final rule = _rule(t);
    final panel = _panel(t);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: panel,
        border: Border(top: BorderSide(color: rule, width: 2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 4,
        children: [
          Text(
            noteLabel,
            style: _label(t).copyWith(
              color: t.brutal ? Colors.black.withValues(alpha: .6) : t.muted,
            ),
          ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: panel,
              border: Border.all(color: rule, width: 2),
              borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                SizedBox(height: 40, child: note),
                Align(alignment: Alignment.centerRight, child: send),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// `label.flex items-center gap-2 border-2 bg-layer-panel px-2 py-2
/// shadow-brutal-sm` around the 14px Search icon and the bold 14px input.
class RaftForwardDesktopSearch extends StatelessWidget {
  const RaftForwardDesktopSearch({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    required this.onChanged,
  });
  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final text = TextStyle(
      fontFamily: t.headingFont,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w700,
      color: t.strong,
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: _panel(t),
        border: Border.all(color: _rule(t), width: 2),
        borderRadius: BorderRadius.circular(t.brutal ? 0 : 6),
        boxShadow: t.brutal ? RaftShadowSet.brutalSm : null,
      ),
      child: Row(
        children: [
          RaftIcon(
            RaftGlyph.search,
            size: 14,
            color: t.brutal ? Colors.black.withValues(alpha: .5) : t.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              autofillHints: null,
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              onChanged: onChanged,
              style: text,
              cursorColor: t.strong,
              decoration: InputDecoration(
                isCollapsed: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                hintText: placeholder,
                hintStyle: text.copyWith(
                  color: Colors.black.withValues(alpha: .35),
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The desktop dialog's borderless 14px note editor (fills its 40px slot).
class RaftForwardDesktopNoteField extends StatelessWidget {
  const RaftForwardDesktopNoteField({
    super.key,
    required this.controller,
    this.hint,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String? hint;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return TextField(
      autofillHints: null,
      controller: controller,
      enabled: enabled,
      maxLength: 4000,
      maxLines: null,
      expands: true,
      style: RaftTypography.body(t, size: 14, line: 20, color: Colors.black),
      decoration: InputDecoration(
        isCollapsed: true,
        filled: false,
        counterText: '',
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        hintText: hint,
        hintStyle: RaftTypography.body(
          t,
          size: 14,
          line: 20,
          color: Colors.black.withValues(alpha: .35),
        ),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }
}
