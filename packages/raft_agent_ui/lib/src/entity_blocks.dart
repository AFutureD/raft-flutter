import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import 'agent_theme.dart';
import 'display_spec.dart';
import 'enter.dart';
import 'entity_cards.dart';
import 'entity_common.dart';
import 'entity_model.dart';

/// Limits the model's content is held to; the catalog validators use them.
abstract final class AgentBlockLimits {
  static const tableColumns = 5;
  static const tableRows = 20;
  static const codeLines = 40;
  static const choiceOptions = 5;
  static const confirmChanges = 8;
}

/// A cell of a table: plain text, or a reference the app draws as a line.
class AgentTableCell {
  const AgentTableCell.text(String this.text) : entity = null, handle = null;
  const AgentTableCell.entity(AgentEntityRef this.entity, {this.handle})
    : text = null;
  final String? text;
  final AgentEntityRef? entity;
  final String? handle;
}

/// Columns and rows, for comparing many things at once. Horizontal scroll
/// when the columns do not fit at a readable width.
///
/// [display] says whether the `header`, the `borders` between rows and the
/// `zebra` fill are drawn; `lines` clamps a cell's text.
class AgentTableView extends StatelessWidget {
  const AgentTableView({
    super.key,
    required this.columns,
    required this.rows,
    this.display,
  });
  final List<String> columns;
  final List<List<AgentTableCell>> rows;
  final DisplaySpec? display;

  static const minColumnWidth = 120.0;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Table');
    final f = x.factor();
    final cols = math.max(columns.length, 1);
    return AgentEntityFrame(
      padding: EdgeInsets.zero,
      child: LayoutBuilder(
        builder: (context, box) {
          final width = math.max(box.maxWidth / cols, minColumnWidth * f);
          final fits = width * cols <= box.maxWidth + .5;
          final table = Table(
            key: const ValueKey('agent-table'),
            defaultColumnWidth: fits
                ? const FlexColumnWidth()
                : FixedColumnWidth(width),
            border: x.has('borders')
                ? TableBorder(
                    horizontalInside: BorderSide(
                      color: t.line.withValues(alpha: .35),
                      width: 1.5,
                    ),
                  )
                : null,
            children: [
              if (x.has('header'))
                TableRow(
                  decoration: BoxDecoration(
                    color: t.chip,
                    border: Border(bottom: BorderSide(color: t.line, width: 3)),
                  ),
                  children: [
                    for (final c in columns)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        child: Text(
                          c,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.body(
                            entityMinText * f,
                            weight: FontWeight.w900,
                          ),
                        ),
                      ),
                  ],
                ),
              for (final (r, row) in rows.indexed)
                TableRow(
                  decoration: x.has('zebra') && r.isOdd
                      ? BoxDecoration(color: t.chip.withValues(alpha: .55))
                      : null,
                  children: [
                    for (var i = 0; i < cols; i++)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        child: i < row.length
                            ? _cell(t, row[i], f, x.lines)
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
            ],
          );
          return fits
              ? table
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: table,
                );
        },
      ),
    );
  }

  Widget _cell(RaftAgentTheme t, AgentTableCell cell, double f, int lines) {
    final entity = cell.entity;
    if (entity != null) {
      return AgentEntityInline(
        entity: entity,
        handle: cell.handle,
        size: 17 * f,
      );
    }
    return Text(
      cell.text ?? '',
      maxLines: lines,
      overflow: TextOverflow.ellipsis,
      style: t.body(17 * f),
    );
  }
}

/// One step on a timeline.
class AgentTimelineItem {
  const AgentTimelineItem({
    required this.time,
    required this.title,
    this.entity,
    this.handle,
  });
  final String time, title;
  final AgentEntityRef? entity;
  final String? handle;
}

/// Things in the order they happened: when, what, and optionally the entity
/// it concerns. [display] says which parts are drawn: the `time`, the `icon`
/// (dot and line), the `title` and the `entity`.
class AgentTimelineView extends StatelessWidget {
  const AgentTimelineView({super.key, required this.items, this.display});
  final List<AgentTimelineItem> items;
  final DisplaySpec? display;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Timeline');
    final f = x.factor();
    final showTime = x.has('time');
    final showIcon = x.has('icon');
    final showEntity = x.has('entity');
    // Every element off still leaves what happened.
    final showTitle = x.has('title') || (!showTime && !showEntity);
    return AgentEntityFrame(
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
                      width: 84 * f,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Text(
                          item.time,
                          textAlign: TextAlign.right,
                          style: t.body(
                            entityMinText * f,
                            weight: FontWeight.w800,
                            color: t.muted,
                          ),
                        ),
                      ),
                    ),
                  if (showIcon)
                    SizedBox(
                      width: 22,
                      child: Column(
                        children: [
                          const SizedBox(height: 6),
                          Container(
                            key: ValueKey('timeline-icon-$i'),
                            width: 14,
                            height: 14,
                            decoration: BoxDecoration(
                              color: i == items.length - 1
                                  ? t.markHighlight
                                  : t.card,
                              border: Border.all(color: t.line, width: 2.5),
                            ),
                          ),
                          if (i < items.length - 1)
                            Expanded(child: Container(width: 3, color: t.line)),
                        ],
                      ),
                    ),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        left: showTime || showIcon ? 8 : 0,
                        bottom: i < items.length - 1 ? 14 : 0,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (showTitle)
                            Text(
                              item.title,
                              maxLines: x.lines,
                              overflow: TextOverflow.ellipsis,
                              style: t.body(
                                entityMetaCompact * f,
                                weight: FontWeight.w800,
                              ),
                            ),
                          if (showEntity && item.entity != null)
                            Padding(
                              padding: EdgeInsets.only(top: showTitle ? 2 : 0),
                              child: AgentEntityInline(
                                entity: item.entity!,
                                handle: item.handle,
                                size: (entityMinText + 1) * f,
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
class AgentCodeBlockView extends StatelessWidget {
  const AgentCodeBlockView({
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
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('CodeBlock');
    final f = x.factor();
    final mono = RaftTokens.of(context).monoFont;
    final all = code.replaceAll('\r\n', '\n').split('\n');
    if (all.isNotEmpty && all.last.isEmpty) all.removeLast();
    final lines = all.take(AgentBlockLimits.codeLines).toList();
    final more = all.length - lines.length;
    final style = TextStyle(
      fontFamily: mono,
      fontFamilyFallback: t.fontFallback,
      fontSize: entityMinText * f,
      height: 1.45,
      color: t.foreground,
    );
    final digits = '${lines.length}'.length;
    Color? tint(String line) {
      if (!diff) return null;
      if (line.startsWith('+++') || line.startsWith('---')) return null;
      if (line.startsWith('+')) {
        return agentPriorityFill(
          t,
          AgentPriority.progress,
        ).withValues(alpha: t.cardFills != null ? .55 : .3);
      }
      if (line.startsWith('-')) {
        return agentPriorityFill(
          t,
          AgentPriority.decision,
        ).withValues(alpha: t.cardFills != null ? .4 : .28);
      }
      if (line.startsWith('@@')) {
        return agentPriorityFill(
          t,
          AgentPriority.mention,
        ).withValues(alpha: .3);
      }
      return null;
    }

    return AgentEntityFrame(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (x.has('title') && title != null && title!.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              decoration: BoxDecoration(
                color: t.chip,
                border: Border(bottom: BorderSide(color: t.line, width: 2.5)),
              ),
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.body(entityMinText * f, weight: FontWeight.w800),
              ),
            ),
          LayoutBuilder(
            builder: (context, box) => SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: box.maxWidth),
                child: IntrinsicWidth(
                  child: Column(
                    key: const ValueKey('agent-code'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, line) in lines.indexed)
                        Container(
                          key: ValueKey(
                            tint(line) == null
                                ? 'code-line-$i'
                                : 'code-line-hot-$i',
                          ),
                          color: tint(line),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 1,
                          ),
                          child: x.has('line_numbers')
                              ? Row(
                                  children: [
                                    SizedBox(
                                      width: (digits * 10 + 8) * f,
                                      child: Text(
                                        '${i + 1}',
                                        textAlign: TextAlign.right,
                                        style: style.copyWith(color: t.hint),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      line.isEmpty ? ' ' : line,
                                      softWrap: false,
                                      style: style,
                                    ),
                                  ],
                                )
                              : Text(
                                  line.isEmpty ? ' ' : line,
                                  softWrap: false,
                                  style: style,
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (more > 0 && x.has('more'))
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: Text(
                '… 还有 $more 行',
                style: t.body(entityMinText * f, color: t.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// One sentence that matters: good news, a warning, or just a note.
/// [display] says whether the `icon` and the `text` are drawn; `lines`
/// clamps the sentence.
class AgentCalloutView extends StatelessWidget {
  const AgentCalloutView({
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
    final t = RaftAgentTheme.of(context);
    final x = (display ?? DisplaySpec.none).resolve('Callout');
    final f = x.factor();
    // Every element off still leaves the sentence.
    final showText = x.has('text') || !x.has('icon');
    final base = agentToneFill(t, tone);
    final fill = base == null
        ? t.card
        : t.cardFills != null
        ? base
        : Color.alphaBlend(base.withValues(alpha: .25), t.card);
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: DecoratedBox(
          key: ValueKey('agent-callout-${tone.name}'),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(t.cardRadius),
            border: Border.all(color: t.line, width: t.cardBorderWidth),
            boxShadow: t.cardShadow,
          ),
          child: Padding(
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
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(icon, size: 28 * f, color: t.line),
                    ),
                  if (x.has('icon') && showText) const SizedBox(width: 10),
                  if (showText)
                    Expanded(
                      child: AgentTypeText(
                        text,
                        maxLines: x.lines,
                        style: t.heading(
                          (entityHeadlineDetail + 2) * f,
                          weight: FontWeight.w900,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How much a confirmation weighs. `sensitive` is drawn louder and asks for
/// a clearer yes.
enum AgentConfirmRisk { change, sensitive }

/// What the person decided.
enum AgentConfirmResult { confirmed, cancelled }

/// Where a confirmed operation is, as its confirm card shows it.
enum AgentOutcomeKind { running, done, failed }

/// The outcome of the operation a confirm card asked about. The card keeps
/// its place and turns into this: "已发送 ✅" with the thing it made, or the
/// error with 重试; [onUndo] is the way back while there is one.
class AgentActionOutcome {
  const AgentActionOutcome({
    required this.kind,
    required this.text,
    this.undoLabel,
    this.onUndo,
    this.onRetry,
    this.onDismiss,
  });
  final AgentOutcomeKind kind;
  final String text;
  final String? undoLabel;
  final VoidCallback? onUndo, onRetry, onDismiss;
}

/// One line of a confirmation: "状态: 进行中 → 已完成".
class AgentChange {
  const AgentChange(this.field, this.from, this.to);
  final String field;
  final String? from, to;

  /// Splits `field: from → to` (also `->`). A line without an arrow is a
  /// `field: value` with only [to]; one without a colon is all [field].
  factory AgentChange.parse(String line) {
    final colon = line.indexOf(RegExp('[:：]'));
    if (colon < 0) return AgentChange(line.trim(), null, null);
    final field = line.substring(0, colon).trim();
    final rest = line.substring(colon + 1).trim();
    final arrow = RegExp(r'\s*(?:→|->|⟶)\s*').firstMatch(rest);
    if (arrow == null) return AgentChange(field, null, rest);
    return AgentChange(
      field,
      rest.substring(0, arrow.start).trim(),
      rest.substring(arrow.end).trim(),
    );
  }

  /// Whether [line] has the shape the model must write.
  static bool wellFormed(String line) {
    final c = AgentChange.parse(line);
    return c.field.isNotEmpty && c.from != null && c.to != null;
  }
}

/// What is about to happen, and a yes / no. The app wires [onConfirm] and
/// [onCancel] to the `confirm` tool; this widget only reports the press, and
/// locks itself after the first one so a double tap cannot decide twice.
class AgentConfirmCardView extends StatefulWidget {
  const AgentConfirmCardView({
    super.key,
    required this.title,
    required this.changes,
    this.risk = AgentConfirmRisk.change,
    this.onConfirm,
    this.onCancel,
    this.result,
    this.compact = true,
    this.outcome,
    this.attachment,
    this.display,
  });
  final String title;

  /// Once the operation ran (or is running, or failed) the buttons give way
  /// to this.
  final AgentActionOutcome? outcome;

  /// Under the changes: the things the operation is about, and after it ran,
  /// the thing it made (an entity card).
  final Widget? attachment;

  /// Which parts are drawn: the `label` ("将要修改") and the `field_names`
  /// above each change. The changes, the outcome and the buttons are never
  /// left out: a confirmation is only worth anything if the person sees what
  /// they confirm.
  final DisplaySpec? display;

  /// "field: from → to" lines.
  final List<String> changes;
  final AgentConfirmRisk risk;
  final VoidCallback? onConfirm, onCancel;

  /// Set by the owner once the decision was carried out (or refused); the
  /// buttons give way to it.
  final AgentConfirmResult? result;
  final bool compact;

  @override
  State<AgentConfirmCardView> createState() => _AgentConfirmCardViewState();
}

class _AgentConfirmCardViewState extends State<AgentConfirmCardView> {
  AgentConfirmResult? _decided;

  AgentConfirmResult? get _result => widget.result ?? _decided;

  void _decide(AgentConfirmResult r, VoidCallback? cb) {
    if (_result != null) return;
    setState(() => _decided = r);
    cb?.call();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final x = (widget.display ?? DisplaySpec.none).resolve('ConfirmCard');
    final f = x.factor();
    final sensitive = widget.risk == AgentConfirmRisk.sensitive;
    final compact = widget.compact;
    final result = _result;
    final warn = agentPriorityFill(t, AgentPriority.blocked);
    final danger = agentPriorityFill(t, AgentPriority.decision);
    return Semantics(
      container: true,
      label: '${sensitive ? '敏感操作，' : ''}${widget.title}',
      child: AgentEntityFrame(
        key: ValueKey('confirm-card-${widget.risk.name}'),
        tone: sensitive ? AgentTone.warn : AgentTone.neutral,
        emphasis: sensitive ? AgentEmphasis.high : AgentEmphasis.normal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // A sensitive operation, and one that already ran, always say so.
            if (x.has('label') || sensitive || widget.outcome != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    AgentEntityPill(
                      switch (widget.outcome?.kind) {
                        AgentOutcomeKind.running => '执行中',
                        AgentOutcomeKind.done => '已完成',
                        AgentOutcomeKind.failed => '没成功',
                        null => sensitive ? '敏感操作' : '将要修改',
                      },
                      fill: switch (widget.outcome?.kind) {
                        AgentOutcomeKind.done => agentPriorityFill(
                          t,
                          AgentPriority.progress,
                        ),
                        AgentOutcomeKind.failed => danger,
                        _ => sensitive ? warn : t.chip,
                      },
                      size: entityMinText * f,
                    ),
                  ],
                ),
              ),
            AgentTypeText(
              widget.title,
              maxLines: x.lines,
              style: t
                  .heading(
                    (compact
                            ? entityHeadlineCompact
                            : entityHeadlineDetail + 2) *
                        f,
                    weight: FontWeight.w900,
                  )
                  .copyWith(height: 1.18),
            ),
            const SizedBox(height: 10),
            for (final line in widget.changes.take(
              AgentBlockLimits.confirmChanges,
            ))
              _ChangeRow(
                change: AgentChange.parse(line),
                showField: x.has('field_names'),
                scale: f,
              ),
            if (widget.attachment != null) widget.attachment!,
            const SizedBox(height: 12),
            if (widget.outcome != null)
              _OutcomeRow(outcome: widget.outcome!)
            else if (result == null)
              Row(
                key: const ValueKey('confirm-card-actions'),
                children: [
                  Expanded(
                    flex: 3,
                    child: AgentPop(
                      child: AgentActionButton(
                        label: sensitive ? '确认执行' : '确认',
                        fill: sensitive ? danger : t.markHighlight,
                        onTap: () => _decide(
                          AgentConfirmResult.confirmed,
                          widget.onConfirm,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: AgentPop(
                      order: 1,
                      child: AgentActionButton(
                        label: '取消',
                        onTap: () => _decide(
                          AgentConfirmResult.cancelled,
                          widget.onCancel,
                        ),
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(
                result == AgentConfirmResult.confirmed ? '已确认' : '已取消',
                key: ValueKey('confirm-card-${result.name}'),
                style: t.heading(
                  entityMetaCompact + 2,
                  weight: FontWeight.w900,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OutcomeRow extends StatelessWidget {
  const _OutcomeRow({required this.outcome});
  final AgentActionOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final o = outcome;
    final mark = switch (o.kind) {
      AgentOutcomeKind.done => ' ✅',
      AgentOutcomeKind.failed => ' ⚠️',
      AgentOutcomeKind.running => '…',
    };
    return Column(
      key: ValueKey('confirm-card-outcome-${o.kind.name}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${o.text}$mark',
          style: t.heading(entityMetaCompact + 2, weight: FontWeight.w900),
        ),
        if (o.onUndo != null && o.undoLabel != null ||
            o.onRetry != null ||
            o.onDismiss != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              children: [
                if (o.onRetry != null)
                  Expanded(
                    child: AgentActionButton(
                      key: const ValueKey('confirm-card-retry'),
                      label: '重试',
                      fill: t.markHighlight,
                      onTap: o.onRetry!,
                    ),
                  ),
                if (o.onUndo != null && o.undoLabel != null)
                  Expanded(
                    child: AgentActionButton(
                      key: const ValueKey('confirm-card-undo'),
                      label: '撤销（${o.undoLabel}）',
                      onTap: o.onUndo!,
                    ),
                  ),
                if (o.onDismiss != null) ...[
                  if (o.onRetry != null || o.onUndo != null)
                    const SizedBox(width: 12),
                  Expanded(
                    child: AgentActionButton(
                      key: const ValueKey('confirm-card-dismiss'),
                      label: '知道了',
                      onTap: o.onDismiss!,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({
    required this.change,
    this.showField = true,
    this.scale = 1,
  });
  final AgentChange change;
  final bool showField;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final from = change.from, to = change.to;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showField || (from == null && to == null))
            Text(
              change.field,
              style: t.body(
                entityMinText * scale,
                weight: FontWeight.w800,
                color: t.muted,
              ),
            ),
          if (from != null && to != null)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Text(
                  from.isEmpty ? '（空）' : from,
                  style: t
                      .body(entityMetaCompact * scale, color: t.muted)
                      .copyWith(decoration: TextDecoration.lineThrough),
                ),
                Icon(
                  Icons.arrow_forward,
                  size: 20 * scale,
                  color: t.foreground,
                ),
                Text(
                  to.isEmpty ? '（空）' : to,
                  style: t.body(
                    (entityMetaCompact + 2) * scale,
                    weight: FontWeight.w900,
                  ),
                ),
              ],
            )
          else if (to != null)
            Text(
              to,
              style: t.body(
                (entityMetaCompact + 2) * scale,
                weight: FontWeight.w900,
              ),
            ),
        ],
      ),
    );
  }
}

/// Pick one of a few options (at most five). Reports the pick; the app
/// decides what it means.
class AgentChoiceView extends StatefulWidget {
  const AgentChoiceView({
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
  State<AgentChoiceView> createState() => _AgentChoiceViewState();
}

class _AgentChoiceViewState extends State<AgentChoiceView> {
  int? _picked;

  int? get _current => widget.selected ?? _picked;

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final options = widget.options.take(AgentBlockLimits.choiceOptions);
    return AgentEntityFrame(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.prompt != null && widget.prompt!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AgentTypeText(
                widget.prompt!,
                maxLines: 3,
                style: t.heading(
                  entityHeadlineDetail + 2,
                  weight: FontWeight.w900,
                ),
              ),
            ),
          for (final (i, label) in options.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AgentPop(
                order: i,
                child: _Option(
                  key: ValueKey('choice-$i'),
                  index: i,
                  label: label,
                  selected: _current == i,
                  locked: _current != null,
                  onTap: () {
                    if (_current != null) return;
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
    final t = RaftAgentTheme.of(context);
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
          opacity: locked && !selected ? .5 : 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? t.markHighlight : t.layer,
              borderRadius: BorderRadius.circular(t.cardRadius == 0 ? 0 : 12),
              border: Border.all(
                color: t.line,
                width: t.stickerLabels ? 3 : t.cardBorderWidth,
              ),
            ),
            child: Row(
              children: [
                Text(
                  '${index + 1}',
                  style: t.heading(
                    entityHeadlineDetail + 2,
                    weight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.body(
                      entityHeadlineDetail,
                      weight: FontWeight.w800,
                    ),
                  ),
                ),
                if (selected) Icon(Icons.check, size: 26, color: t.line),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An on / off switch with a label. Reports the new value.
class AgentToggleView extends StatefulWidget {
  const AgentToggleView({
    super.key,
    required this.label,
    this.value = false,
    this.onChanged,
  });
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<AgentToggleView> createState() => _AgentToggleViewState();
}

class _AgentToggleViewState extends State<AgentToggleView> {
  late bool _on = widget.value;

  @override
  void didUpdateWidget(AgentToggleView old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _on = widget.value;
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftAgentTheme.of(context);
    final on = agentPriorityFill(t, AgentPriority.progress);
    void flip() {
      setState(() => _on = !_on);
      widget.onChanged?.call(_on);
    }

    return Semantics(
      toggled: _on,
      label: widget.label,
      excludeSemantics: true,
      onTap: flip,
      child: AgentEntityFrame(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: flip,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.heading(
                      entityHeadlineDetail + 2,
                      weight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                AnimatedContainer(
                  key: ValueKey('toggle-${_on ? 'on' : 'off'}'),
                  duration: const Duration(milliseconds: 160),
                  width: 68,
                  height: 38,
                  padding: const EdgeInsets.all(3),
                  alignment: _on ? Alignment.centerRight : Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: _on ? on : t.chip,
                    borderRadius: BorderRadius.circular(
                      t.cardRadius == 0 ? 0 : 19,
                    ),
                    border: Border.all(color: t.line, width: 3),
                  ),
                  child: Container(
                    width: 28,
                    decoration: BoxDecoration(
                      color: t.card,
                      borderRadius: BorderRadius.circular(
                        t.cardRadius == 0 ? 0 : 14,
                      ),
                      border: Border.all(color: t.line, width: 2.5),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _on ? '开' : '关',
                  style: t.body(entityMetaCompact, weight: FontWeight.w900),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
