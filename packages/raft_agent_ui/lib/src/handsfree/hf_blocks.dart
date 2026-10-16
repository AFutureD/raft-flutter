import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTokens;

import '../display_spec.dart';
import '../enter.dart';
import '../entity_blocks.dart';
import '../entity_model.dart';
import 'hf_entity.dart';
import 'hf_scope.dart';
import 'hf_tokens.dart';

/// The card shell of a block: paper, a 3 s ink outline, a hard shadow in the
/// colour of what it means. [fill] replaces the paper (a callout).
class HfCard extends StatelessWidget {
  const HfCard({
    super.key,
    required this.child,
    this.tone = HfTone.info,
    this.fill,
    this.padding,
    this.clip = false,
  });
  final Widget child;
  final HfTone tone;
  final Color? fill;

  /// In s-units; null is 14 around.
  final EdgeInsets? padding;

  /// Clip the child to the rounded corners (a table, a code block).
  final bool clip;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final radius = BorderRadius.circular(hf.sp(16));
    final pad = padding ?? const EdgeInsets.all(14);
    Widget inner = Padding(
      padding: EdgeInsets.fromLTRB(
        hf.sp(pad.left),
        hf.sp(pad.top),
        hf.sp(pad.right),
        hf.sp(pad.bottom),
      ),
      child: child,
    );
    if (clip) inner = ClipRRect(borderRadius: radius, child: inner);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: fill ?? HfColors.card,
        borderRadius: radius,
        border: Border.all(color: HfColors.ink, width: hf.sp(3)),
        boxShadow: [
          BoxShadow(color: HfColors.of(tone), offset: Offset(0, hf.sp(6))),
        ],
      ),
      child: inner,
    );
  }
}

/// Columns and rows, for comparing many things at once. The columns share the
/// width; a cell wraps to the lines it is allowed. (It never scrolls sideways:
/// the page is the only thing that scrolls.)
///
/// [display] says whether the `header`, the `borders` between rows and the
/// `zebra` fill are drawn; `lines` clamps a cell's text.
class HfTable extends StatelessWidget {
  const HfTable({
    super.key,
    required this.columns,
    required this.rows,
    this.display,
  });
  final List<String> columns;
  final List<List<AgentTableCell>> rows;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Table');
    final cols = math.max(columns.length, 1);
    final pad = EdgeInsets.fromLTRB(hf.sp(12), hf.sp(8), hf.sp(8), hf.sp(8));
    return HfCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Table(
        key: const ValueKey('agent-table'),
        defaultColumnWidth: const FlexColumnWidth(),
        border: x.has('borders')
            ? TableBorder(
                horizontalInside: BorderSide(
                  color: HfColors.ink.withValues(alpha: .35),
                  width: hf.sp(1.5),
                ),
              )
            : null,
        children: [
          if (x.has('header'))
            TableRow(
              decoration: BoxDecoration(
                color: HfColors.cream,
                border: Border(
                  bottom: BorderSide(color: HfColors.ink, width: hf.sp(3)),
                ),
              ),
              children: [
                for (final c in columns)
                  Padding(
                    padding: pad,
                    child: Text(
                      c,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: hf
                          .type(HfType.body)
                          .copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
              ],
            ),
          for (final (r, row) in rows.indexed)
            TableRow(
              decoration: x.has('zebra') && r.isOdd
                  ? BoxDecoration(color: HfColors.cream.withValues(alpha: .55))
                  : null,
              children: [
                for (var i = 0; i < cols; i++)
                  Padding(
                    padding: pad,
                    child: i < row.length
                        ? _cell(hf, row[i], x.lines)
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _cell(HfData hf, AgentTableCell cell, int lines) {
    final entity = cell.entity;
    if (entity != null) {
      return HfEntityInline(entity: entity, handle: cell.handle);
    }
    return Text(
      cell.text ?? '',
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      style: hf.type(HfType.body),
    );
  }
}

/// Things in the order they happened: when, what, and optionally the entity
/// it concerns. [display] says which parts are drawn: the `time`, the `icon`
/// (dot and line), the `title` and the `entity`.
class HfTimeline extends StatelessWidget {
  const HfTimeline({super.key, required this.items, this.display});
  final List<AgentTimelineItem> items;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Timeline');
    final showTime = x.has('time');
    final showIcon = x.has('icon');
    final showEntity = x.has('entity');
    // Every element off still leaves what happened.
    final showTitle = x.has('title') || (!showTime && !showEntity);
    return HfCard(
      child: Column(
        key: const ValueKey('agent-timeline'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, item) in items.indexed)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (showTime)
                    SizedBox(
                      width: hf.sp(72),
                      child: Padding(
                        padding: EdgeInsets.only(
                          top: hf.sp(2),
                          right: hf.sp(8),
                        ),
                        child: Text(
                          item.time,
                          textAlign: TextAlign.right,
                          style: hf.type(HfType.body, color: HfColors.inkSoft),
                        ),
                      ),
                    ),
                  if (showIcon)
                    SizedBox(
                      width: hf.sp(22),
                      child: Column(
                        children: [
                          SizedBox(height: hf.sp(6)),
                          Container(
                            key: ValueKey('timeline-icon-$i'),
                            width: hf.sp(14),
                            height: hf.sp(14),
                            decoration: BoxDecoration(
                              color: i == items.length - 1
                                  ? HfColors.sticker
                                  : HfColors.card,
                              border: Border.all(
                                color: HfColors.ink,
                                width: hf.sp(2.5),
                              ),
                            ),
                          ),
                          if (i < items.length - 1)
                            Expanded(
                              child: Container(
                                width: hf.sp(3),
                                color: HfColors.ink,
                              ),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: showTime || showIcon ? hf.sp(8) : 0,
                        bottom: i < items.length - 1 ? hf.sp(14) : 0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showTitle)
                            Text(
                              item.title,
                              maxLines: x.lines,
                              overflow: TextOverflow.ellipsis,
                              style: hf.type(HfType.headline),
                            ),
                          if (showEntity && item.entity != null)
                            Padding(
                              padding: EdgeInsets.only(
                                top: showTitle ? hf.sp(2) : 0,
                              ),
                              child: HfEntityInline(
                                entity: item.entity!,
                                handle: item.handle,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Code or a diff in a monospace block. A line starting with `+` is green and
/// one starting with `-` red when [diff] is on. Never wraps: it scrolls.
///
/// [display] says which parts are drawn: the `title` above the code, the
/// `line_numbers` and the "还有 N 行" note (`more`).
class HfCodeBlock extends StatelessWidget {
  const HfCodeBlock({
    super.key,
    required this.code,
    this.diff = false,
    this.title,
    this.display,
  });
  final String code;
  final bool diff;

  /// A file name or language, small, above the code.
  final String? title;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve('CodeBlock');
    final mono = RaftTokens.of(context).monoFont;
    final all = code.replaceAll('\r\n', '\n').split('\n');
    if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
    final lines = all.take(AgentBlockLimits.codeLines).toList();
    final more = all.length - lines.length;
    final style = TextStyle(
      fontFamily: mono,
      fontFamilyFallback: hf.theme.fontFallback,
      fontSize: hf.sp(13),
      height: 1.45,
      color: HfColors.ink,
    );
    final digits = '${lines.length}'.length;
    Color? tint(String line) {
      if (!diff) return null;
      if (line.startsWith('+++') || line.startsWith('---')) return null;
      if (line.startsWith('+')) return HfColors.progress.withValues(alpha: .55);
      if (line.startsWith('-')) return HfColors.decision.withValues(alpha: .4);
      if (line.startsWith('@@')) return HfColors.mention.withValues(alpha: .3);
      return null;
    }

    return HfCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (x.has('title') && title != null && title!.isNotEmpty)
            Container(
              padding: EdgeInsets.fromLTRB(
                hf.sp(12),
                hf.sp(6),
                hf.sp(12),
                hf.sp(6),
              ),
              decoration: BoxDecoration(
                color: HfColors.cream,
                border: Border(
                  bottom: BorderSide(color: HfColors.ink, width: hf.sp(2.5)),
                ),
              ),
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: hf.type(HfType.body),
              ),
            ),
          Column(
            key: const ValueKey('agent-code'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, line) in lines.indexed)
                Container(
                  key: ValueKey(
                    tint(line) == null ? 'code-line-$i' : 'code-line-hot-$i',
                  ),
                  color: tint(line),
                  padding: EdgeInsets.symmetric(
                    horizontal: hf.sp(12),
                    vertical: hf.sp(1),
                  ),
                  // A long line wraps: the page is the only scroll.
                  child: x.has('line_numbers')
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: hf.sp(digits * 9 + 8),
                              child: Text(
                                '${i + 1}',
                                textAlign: TextAlign.right,
                                style: style.copyWith(color: HfColors.inkMuted),
                              ),
                            ),
                            SizedBox(width: hf.sp(10)),
                            Expanded(
                              child: Text(
                                line.isEmpty ? ' ' : line,
                                style: style,
                              ),
                            ),
                          ],
                        )
                      : Text(line.isEmpty ? ' ' : line, style: style),
                ),
            ],
          ),
          if (more > 0 && x.has('more'))
            Padding(
              padding: EdgeInsets.fromLTRB(
                hf.sp(12),
                hf.sp(4),
                hf.sp(12),
                hf.sp(6),
              ),
              child: Text(
                '… 还有 $more 行',
                style: hf.type(HfType.meta, color: HfColors.inkSoft),
              ),
            ),
        ],
      ),
    );
  }
}

/// One sentence that matters: good news (green), a warning (orange), or just
/// a note. [display] says whether the `icon` and the `text` are drawn; `lines`
/// clamps the sentence.
class HfCallout extends StatelessWidget {
  const HfCallout({
    super.key,
    required this.text,
    this.tone = AgentTone.neutral,
    this.display,
  });
  final String text;
  final AgentTone tone;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Callout');
    // Every element off still leaves the sentence.
    final showText = x.has('text') || !x.has('icon');
    final base = switch (tone) {
      AgentTone.good => HfTone.progress,
      AgentTone.warn => HfTone.blocked,
      AgentTone.neutral => HfTone.info,
    };
    final icon = switch (tone) {
      AgentTone.good => Icons.check_circle_outline,
      AgentTone.warn => Icons.warning_amber_rounded,
      AgentTone.neutral => Icons.info_outline,
    };
    return Semantics(
      container: true,
      label: switch (tone) {
        AgentTone.good => '好消息：$text',
        AgentTone.warn => '注意：$text',
        AgentTone.neutral => text,
      },
      child: KeyedSubtree(
        key: ValueKey('agent-callout-${tone.name}'),
        child: HfCard(
          tone: base,
          fill: tone == AgentTone.neutral ? null : HfColors.of(base),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: AnimatedSize(
            duration: agentResizeDuration,
            curve: agentResizeCurve,
            alignment: Alignment.topCenter,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (x.has('icon'))
                  Padding(
                    padding: EdgeInsets.only(top: hf.sp(2)),
                    child: Icon(icon, size: hf.sp(28), color: HfColors.ink),
                  ),
                if (x.has('icon') && showText) SizedBox(width: hf.sp(10)),
                if (showText)
                  Expanded(
                    child: AgentTypeText(
                      text,
                      maxLines: x.lines,
                      style: hf.type(HfType.headline),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pick one of a few options (at most five). Reports the pick; the app
/// decides what it means. On a TV the options are shown, not pressed.
class HfChoice extends StatefulWidget {
  const HfChoice({
    super.key,
    required this.options,
    this.prompt,
    this.selected,
    this.onChoose,
  });
  final List<String> options;
  final String? prompt;

  /// Index already chosen (the owner knows), else none.
  final int? selected;
  final void Function(int index, String label)? onChoose;

  @override
  State<HfChoice> createState() => _HfChoiceState();
}

class _HfChoiceState extends State<HfChoice> {
  int? _picked;

  int? get _current => widget.selected ?? _picked;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final options = widget.options.take(AgentBlockLimits.choiceOptions);
    return HfCard(
      tone: HfTone.sticker,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.prompt != null && widget.prompt!.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: hf.sp(8)),
              child: AgentTypeText(
                widget.prompt!,
                maxLines: 3,
                style: hf.type(HfType.headline),
              ),
            ),
          for (final (i, label) in options.indexed)
            Padding(
              padding: EdgeInsets.only(bottom: hf.sp(8)),
              child: AgentPop(
                order: i,
                child: _Option(
                  key: ValueKey('choice-$i'),
                  index: i,
                  label: label,
                  selected: _current == i,
                  locked: _current != null || !hf.interactive,
                  onTap: () {
                    if (_current != null || !hf.interactive) return;
                    setState(() => _picked = i);
                    widget.onChoose?.call(i, label);
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Option extends StatelessWidget {
  const _Option({
    super.key,
    required this.index,
    required this.label,
    required this.selected,
    required this.locked,
    required this.onTap,
  });
  final int index;
  final String label;
  final bool selected, locked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Semantics(
      button: true,
      selected: selected,
      enabled: !locked,
      label: '第 ${index + 1} 个，$label',
      excludeSemantics: true,
      onTap: locked ? null : onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: locked ? null : onTap,
        child: Opacity(
          opacity: locked && !selected && hf.interactive ? .5 : 1,
          child: Container(
            constraints: BoxConstraints(minHeight: hf.sp(56)),
            padding: EdgeInsets.symmetric(
              horizontal: hf.sp(12),
              vertical: hf.sp(8),
            ),
            decoration: BoxDecoration(
              color: selected ? HfColors.sticker : HfColors.card,
              borderRadius: BorderRadius.circular(hf.sp(14)),
              border: Border.all(color: HfColors.ink, width: hf.sp(3)),
            ),
            child: Row(
              children: [
                Text('${index + 1}', style: hf.type(HfType.headline)),
                SizedBox(width: hf.sp(14)),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: hf.type(HfType.headline),
                  ),
                ),
                if (selected)
                  Icon(Icons.check, size: hf.sp(26), color: HfColors.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An on / off switch with a label. Reports the new value.
class HfToggle extends StatefulWidget {
  const HfToggle({
    super.key,
    required this.label,
    this.value = false,
    this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<HfToggle> createState() => _HfToggleState();
}

class _HfToggleState extends State<HfToggle> {
  late bool _on = widget.value;

  @override
  void didUpdateWidget(HfToggle old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _on = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    void flip() {
      if (!hf.interactive) return;
      setState(() => _on = !_on);
      widget.onChanged?.call(_on);
    }

    return Semantics(
      toggled: _on,
      label: widget.label,
      excludeSemantics: true,
      onTap: flip,
      child: HfCard(
        tone: HfTone.sticker,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: flip,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: hf.sp(44)),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: hf.type(HfType.headline),
                  ),
                ),
                SizedBox(width: hf.sp(12)),
                AnimatedContainer(
                  key: ValueKey('toggle-${_on ? 'on' : 'off'}'),
                  duration: const Duration(milliseconds: 160),
                  width: hf.sp(68),
                  height: hf.sp(38),
                  padding: EdgeInsets.all(hf.sp(3)),
                  alignment: _on ? Alignment.centerRight : Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: _on ? HfColors.progress : HfColors.cream,
                    borderRadius: BorderRadius.circular(hf.sp(19)),
                    border: Border.all(color: HfColors.ink, width: hf.sp(3)),
                  ),
                  child: Container(
                    width: hf.sp(28),
                    decoration: BoxDecoration(
                      color: HfColors.card,
                      borderRadius: BorderRadius.circular(hf.sp(14)),
                      border: Border.all(
                        color: HfColors.ink,
                        width: hf.sp(2.5),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: hf.sp(8)),
                Text(_on ? '开' : '关', style: hf.type(HfType.headline)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
