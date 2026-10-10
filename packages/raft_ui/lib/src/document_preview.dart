import 'package:flutter/material.dart';

import 'localization.dart';
import 'message_body.dart';
import 'design_primitives.dart';
import 'dialog_card.dart' show RaftShadowSet;
import 'message_content_tokens.dart';
import 'theme.dart';
import 'tokens/tokens.dart';

/// Structured, server-bounded attachment content. Never executes document HTML.
///
/// Web `AttachmentPreviewShell` panes: `TextPreviewPane`, `CsvPreviewPane`,
/// `XlsxPreviewPane` and `MarkdownPreviewPane`, each on the shell's canvas
/// surface (`bg-layer-canvas-muted`, brutal `bg-brutal-cream/45`).
class RaftDocumentPreview extends StatefulWidget {
  const RaftDocumentPreview({
    super.key,
    required this.data,
    this.truncated = false,
  });
  final Map<String, dynamic> data;
  final bool truncated;
  @override
  State<RaftDocumentPreview> createState() => _RaftDocumentPreviewState();
}

class _RaftDocumentPreviewState extends State<RaftDocumentPreview> {
  int sheet = 0;

  static String plural(int count, String one, String other) =>
      '$count ${count == 1 ? one : other}';

  /// CSS `table-layout: auto` with `min-w-full`: each column takes its
  /// max-content width (capped by the cell's `max-w-[220px]`), and any width
  /// the container has beyond their sum is shared in proportion to them.
  static Map<int, TableColumnWidth> _columnWidths(
    BuildContext context,
    DocumentAttachmentRecipe recipe,
    List<String> headers,
    List<List> rows,
    double available,
  ) {
    double measure(String text, TextStyle style) => (TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout()).width;
    final inset = recipe.cellInset.horizontal;
    final bold = recipe.tableText.copyWith(fontWeight: FontWeight.w700);
    final intrinsic = <double>[
      for (var i = 0; i < headers.length; i++)
        () {
          var width = measure(headers[i], bold);
          for (final row in rows) {
            if (i < row.length) {
              width = width > measure('${row[i]}', recipe.tableText)
                  ? width
                  : measure('${row[i]}', recipe.tableText);
            }
          }
          return (width.ceilToDouble() < recipe.maxColumnWidth
                  ? width.ceilToDouble()
                  : recipe.maxColumnWidth) +
              inset +
              1;
        }(),
    ];
    final total = intrinsic.fold<double>(0, (a, b) => a + b);
    final grow = available > total + 1 ? available / (total + 1) : 1.0;
    return {
      for (var i = 0; i < intrinsic.length; i++)
        i: FixedColumnWidth(intrinsic[i] * grow),
    };
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final t = RaftTokens.of(context);
    final recipe = DocumentAttachmentRecipe(t);
    final sheets = (data['sheets'] as List? ?? []).whereType<Map>().toList();
    final selected = sheets.isEmpty
        ? data
        : sheets[sheet.clamp(0, sheets.length - 1)];
    final kind = data['kind'];
    final tabular = ['csv', 'xlsx'].contains(kind);
    final headers = (selected['headers'] as List? ?? [])
        .map((v) => '$v')
        .toList();
    final rows = (selected['rows'] as List? ?? []).whereType<List>().toList();
    final truncated =
        widget.truncated ||
        data['truncated'] == true ||
        selected['truncated'] == true;
    final label = TextStyle(
      fontFamily: t.headingFont,
      fontSize: 12,
      height: 16 / 12,
      fontWeight: FontWeight.w700,
      color: t.brutal
          ? RaftPrimitiveColors.black.withValues(alpha: .55)
          : t.muted,
    );
    // `shadow-raft-sm theme-brutal:shadow-brutal-sm`
    final shadow = t.brutal ? RaftShadowSet.brutalSm : t.themeShadows.sm.outer;
    Widget pane(Widget child) => ColoredBox(
      color: kind == 'markdown' ? recipe.background : recipe.background,
      child: SingleChildScrollView(
        child: Padding(padding: recipe.inset, child: child),
      ),
    );
    if (kind == 'markdown') {
      final width = MediaQuery.sizeOf(context).width;
      return ColoredBox(
        color: recipe.background,
        child: SingleChildScrollView(
          child: Padding(
            padding: recipe.markdownInset(width),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (truncated)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Text(
                      raftText(
                        context,
                        'Preview truncated. Download the full file.',
                      ),
                    ),
                  ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: recipe.paper,
                    border: Border.fromBorderSide(recipe.border),
                    boxShadow: shadow,
                  ),
                  child: Padding(
                    padding: width >= 768
                        ? const EdgeInsets.symmetric(horizontal: 40, vertical: 48)
                        : const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                    child: RaftMessageBody(
                      content: '${data['markdown'] ?? ''}',
                      fontSize: 16,
                      documentMode: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!tabular) {
      // `TextPreviewPane`: label row, then a bordered `<pre>` of per-line rows.
      final lines = '${data['text'] ?? ''}'.split(RegExp(r'\r?\n'));
      return pane(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(raftText(context, 'Plain text preview'), style: label),
                  if (truncated) Text(raftText(context, 'Truncated'), style: label),
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                color: recipe.paper,
                border: Border.fromBorderSide(recipe.border),
                boxShadow: shadow,
              ),
              child: Padding(
                padding: recipe.textInset,
                child: SelectableText(
                  lines.map((line) => line.isEmpty ? ' ' : line).join('\n'),
                  style: recipe.text,
                ),
              ),
            ),
          ],
        ),
      );
    }
    // CSV / XLSX: label row, optional sheet tabs, bordered table, footer.
    final isXlsx = kind == 'xlsx';
    final rowCount = (selected['rowCount'] as num?)?.toInt() ?? rows.length;
    final columnCount =
        (selected['columnCount'] as num?)?.toInt() ?? headers.length;
    final empty = headers.isEmpty && rows.isEmpty;
    final footer = isXlsx
        ? (truncated
              ? raftFormat(
                  context,
                  'Preview truncated for performance. Showing the first {count} rows of this sheet.',
                  {'count': rows.length},
                )
              : raftFormat(context, 'Showing {shown} of {total} rows', {
                  'shown': rows.length,
                  'total': rowCount,
                }))
        : (truncated
              ? raftFormat(
                  context,
                  'Preview truncated for performance. Showing first {count} rows from the file prefix.',
                  {'count': rows.length},
                )
              : raftFormat(context, 'Showing {shown} of {total} rows', {
                  'shown': rows.length,
                  'total': rowCount,
                }));
    final summary = isXlsx
        ? plural(
            (data['sheetCount'] as num?)?.toInt() ?? sheets.length,
            'sheet',
            'sheets',
          )
        : '${truncated ? raftFormat(context, 'First {count} rows', {'count': rows.length}) : plural(rowCount, 'row', 'rows')} · ${plural(columnCount, 'column', 'columns')}';
    return pane(
      DefaultTextStyle.merge(
        style: recipe.tableText,
        child: LayoutBuilder(
          builder: (context, bounds) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: EdgeInsets.only(bottom: isXlsx ? 12 : 8),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      raftText(
                        context,
                        isXlsx ? 'XLSX data preview' : 'CSV data preview',
                      ),
                      style: label.copyWith(fontFamily: t.monoFont),
                    ),
                    Text(
                      summary,
                      style: label.copyWith(fontFamily: t.monoFont),
                    ),
                  ],
                ),
              ),
              if (isXlsx && sheets.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Wrap(
                    children: [
                      for (var i = 0; i < sheets.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: RaftControl(
                            kind: RaftControlKind.tab,
                            selected: sheet == i,
                            shadow: false,
                            semanticLabel: '${sheets[i]['name'] ?? ''}',
                            onPressed: () => setState(() => sheet = i),
                            child: Text('${sheets[i]['name'] ?? ''}'),
                          ),
                        ),
                    ],
                  ),
                ),
              if (empty)
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: recipe.paper,
                    border: Border.fromBorderSide(recipe.border),
                    boxShadow: shadow,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      raftText(context, 'This spreadsheet is empty.'),
                      style: TextStyle(
                        fontFamily: t.headingFont,
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w700,
                        color: t.brutal ? Colors.black : t.strong,
                      ),
                    ),
                  ),
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: recipe.paper,
                    border: Border.fromBorderSide(recipe.border),
                    boxShadow: shadow,
                  ),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: bounds.maxWidth - recipe.border.width * 2,
                      ),
                      child: DecoratedBox(
                        // The collapsed table's own outer border sits just
                        // inside the box's border.
                        decoration: BoxDecoration(
                          border: Border.fromBorderSide(recipe.cellBorder),
                        ),
                        child: Table(
                        columnWidths: _columnWidths(
                          context,
                          recipe,
                          headers,
                          rows,
                          bounds.maxWidth - recipe.border.width * 2 - 2,
                        ),
                        border: TableBorder(
                          horizontalInside: recipe.cellBorder,
                          verticalInside: recipe.cellBorder,
                        ),
                        children: [
                          if (headers.isNotEmpty)
                            TableRow(
                              decoration: BoxDecoration(color: recipe.tableHeader),
                              children: [
                                for (var i = 0; i < headers.length; i++)
                                  Padding(
                                    padding: recipe.cellInset,
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                        maxWidth: recipe.maxColumnWidth,
                                      ),
                                      child: Text(
                                        headers[i].isEmpty
                                            ? raftFormat(context, 'Column {index}', {'index': i + 1})
                                            : headers[i],
                                        style: recipe.tableText.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: t.brutal ? Colors.black : t.strong,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          for (var rowIndex = 0; rowIndex < rows.length; rowIndex++)
                            if (headers.isNotEmpty)
                              TableRow(
                                // `odd:bg-black/[0.03]`: the 1st, 3rd, ... row.
                                decoration: BoxDecoration(
                                  color: rowIndex.isEven ? recipe.rowStripe : null,
                                ),
                                children: [
                                  for (var i = 0; i < headers.length; i++)
                                    Padding(
                                      padding: recipe.cellInset,
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxWidth: recipe.maxColumnWidth,
                                        ),
                                        child: Semantics(
                                          label: i < rows[rowIndex].length ? '${rows[rowIndex][i]}' : '',
                                          excludeSemantics: true,
                                          child: SelectableText(
                                            i < rows[rowIndex].length ? '${rows[rowIndex][i]}' : '',
                                            style: recipe.tableText,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                        ],
                      ),
                      ),
                    ),
                  ),
                ),
              if (!empty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(footer, style: label),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class RaftMediaControls extends StatelessWidget {
  const RaftMediaControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    this.volume = 100,
    this.onPlayPause,
    this.onSeek,
    this.onVolume,
  });
  final bool playing;
  final Duration position, duration;
  final double volume;
  final VoidCallback? onPlayPause;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onVolume;
  String clock(Duration value) =>
      '${value.inMinutes}:${(value.inSeconds % 60).toString().padLeft(2, '0')}';
  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          IconButton(
            tooltip: raftText(context, playing ? 'Pause' : 'Play'),
            onPressed: onPlayPause,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
          Expanded(
            child: Slider(
              semanticFormatterCallback: (v) =>
                  clock(Duration(milliseconds: v.round())),
              value: position.inMilliseconds.toDouble().clamp(
                0,
                duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              ),
              max: duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: duration > Duration.zero && onSeek != null
                  ? (v) => onSeek!(Duration(milliseconds: v.round()))
                  : null,
            ),
          ),
          Text('${clock(position)} / ${clock(duration)}'),
        ],
      ),
      Row(
        children: [
          Icon(Icons.volume_up, semanticLabel: raftText(context, 'Volume')),
          Expanded(
            child: Slider(
              value: volume.clamp(0, 100),
              max: 100,
              onChanged: onVolume,
              semanticFormatterCallback: (v) => '${v.round()}%',
            ),
          ),
        ],
      ),
    ],
  );
}
