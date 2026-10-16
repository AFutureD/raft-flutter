// PROTOTYPE for GitHub issue #153 (expandable message composer). Design
// proposal only: nothing here is wired into RaftComposer or the app. It reuses
// the composer recipe, controls and message renderer so the proposal renders in
// the production style; the real implementation would live inside RaftComposer.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer_editing.dart' show raftProgrammaticEditingText;
import 'composer_composing_text.dart' show RaftComposerEditingController;
import 'composer_recipe.dart';
import 'chat_composition.dart' show RaftComposerTaskToggle;
import 'design_primitives.dart';
import 'dialog_card.dart'
    show RaftRecipeButton, RaftRecipeCard, RaftRecipeSegmentedControl;
import 'icons.dart';
import 'message_body.dart';
import 'message_content_tokens.dart' show MessageContentSemantic;
import 'panel_layout.dart' show RaftCssLineBox;
import 'recipes/button_variants.g.dart';
import 'theme.dart';

// ---------------------------------------------------------------------------
// Markdown editing operations (pure functions over a TextEditingValue).
// Wire format stays Markdown text; every operation only inserts or removes
// Markdown characters, so the draft is identical in both views.
// ---------------------------------------------------------------------------

abstract final class RaftMarkdownFormat {
  static TextSelection _selection(TextEditingValue v) => v.selection.isValid
      ? v.selection
      : TextSelection.collapsed(offset: v.text.length);

  /// Toggles an inline [mark] (`**`, `*`, `~~`, `` ` ``) around the selection.
  static TextEditingValue wrap(
    TextEditingValue v,
    String mark, {
    String placeholder = 'text',
  }) {
    final text = v.text, sel = _selection(v);
    final start = sel.start, end = sel.end, n = mark.length;
    if (start >= n &&
        end + n <= text.length &&
        text.substring(start - n, start) == mark &&
        text.substring(end, end + n) == mark) {
      final next = text
          .replaceRange(end, end + n, '')
          .replaceRange(start - n, start, '');
      return TextEditingValue(
        text: next,
        selection: TextSelection(baseOffset: start - n, extentOffset: end - n),
      );
    }
    final inner = sel.isCollapsed ? placeholder : text.substring(start, end);
    return TextEditingValue(
      text: text.replaceRange(start, end, '$mark$inner$mark'),
      selection: TextSelection(
        baseOffset: start + n,
        extentOffset: start + n + inner.length,
      ),
    );
  }

  /// Adds or removes a line prefix on every selected line. [ordered] numbers
  /// the lines `1.`, `2.`, ...
  static TextEditingValue linePrefix(
    TextEditingValue v,
    String prefix, {
    bool ordered = false,
  }) {
    final text = v.text, sel = _selection(v);
    final from = text.lastIndexOf('\n', math.max(0, sel.start - 1)) + 1;
    final lineStart = sel.start == 0 ? 0 : (from > sel.start ? 0 : from);
    var lineEnd = text.indexOf('\n', sel.end);
    if (lineEnd < 0) lineEnd = text.length;
    final lines = text.substring(lineStart, lineEnd).split('\n');
    final marker = ordered ? RegExp(r'^\d+\. ') : RegExp(RegExp.escape(prefix));
    final all = lines.every((l) => marker.hasMatch(l));
    final out = [
      for (final (i, l) in lines.indexed)
        all
            ? l.replaceFirst(marker, '')
            : '${ordered ? '${i + 1}. ' : prefix}$l',
    ].join('\n');
    return TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, out),
      selection: TextSelection(
        baseOffset: lineStart,
        extentOffset: lineStart + out.length,
      ),
    );
  }

  /// Cycles the heading level of the caret line: none -> ## -> ### -> none.
  static TextEditingValue heading(TextEditingValue v) {
    final text = v.text, sel = _selection(v);
    final lineStart = sel.start == 0
        ? 0
        : text.lastIndexOf('\n', sel.start - 1) + 1;
    var lineEnd = text.indexOf('\n', lineStart);
    if (lineEnd < 0) lineEnd = text.length;
    final line = text.substring(lineStart, lineEnd);
    final m = RegExp(r'^(#{1,6}) ').firstMatch(line);
    final level = m == null ? 0 : m[1]!.length;
    final next = level == 0 ? 2 : (level == 2 ? 3 : 0);
    final body = m == null ? line : line.substring(m[0]!.length);
    final out = next == 0 ? body : '${'#' * next} $body';
    return TextEditingValue(
      text: text.replaceRange(lineStart, lineEnd, out),
      selection: TextSelection.collapsed(offset: lineStart + out.length),
    );
  }

  static TextEditingValue codeBlock(TextEditingValue v) {
    final text = v.text, sel = _selection(v);
    final inner = sel.isCollapsed ? 'code' : text.substring(sel.start, sel.end);
    final lead = sel.start == 0 || text[sel.start - 1] == '\n' ? '' : '\n';
    final open = '$lead```\n';
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, '$open$inner\n```\n'),
      selection: TextSelection(
        baseOffset: sel.start + open.length,
        extentOffset: sel.start + open.length + inner.length,
      ),
    );
  }

  static TextEditingValue link(TextEditingValue v) {
    final text = v.text, sel = _selection(v);
    final label = sel.isCollapsed
        ? 'link text'
        : text.substring(sel.start, sel.end);
    const url = 'https://';
    final next = '[$label]($url)';
    return TextEditingValue(
      text: text.replaceRange(sel.start, sel.end, next),
      selection: TextSelection(
        baseOffset: sel.start + label.length + 3,
        extentOffset: sel.start + label.length + 3 + url.length,
      ),
    );
  }

  static TextEditingValue insert(TextEditingValue v, String snippet) {
    final sel = _selection(v);
    return TextEditingValue(
      text: v.text.replaceRange(sel.start, sel.end, snippet),
      selection: TextSelection.collapsed(offset: sel.start + snippet.length),
    );
  }

  static const rule = '\n\n---\n\n';
  static const table = '\n| Column | Column |\n| --- | --- |\n|  |  |\n';
}

// ---------------------------------------------------------------------------
// Live-styled Markdown source. The text stays the source (markers visible and
// dimmed); only TextSpan styles change, never the characters or their count.
// Styling is skipped while an IME composition is active, so the composing
// range and its underline are exactly the platform's.
// ---------------------------------------------------------------------------

class RaftMarkdownEditingController extends RaftComposerEditingController {
  RaftMarkdownEditingController({super.text});

  /// Styling is on only while the expanded editor shows the draft; the inline
  /// composer keeps today's plain text.
  bool get styled => _styled;
  bool _styled = false;
  set styled(bool value) {
    if (_styled == value) return;
    _styled = value;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final composing = value.composing.isValid && !value.composing.isCollapsed;
    if (!_styled || composing || style == null) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(
      style: style,
      children: _markdownSpans(text, style, RaftTokens.of(context)),
    );
  }
}

final _fenceLine = RegExp(r'^\s*(```|~~~)');
final _headingLine = RegExp(r'^(#{1,6})(\s+)(.*)$');
final _quoteLine = RegExp(r'^(\s*>+\s?)(.*)$');
final _listLine = RegExp(r'^(\s*(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)(.*)$');
final _inline = RegExp(
  r'(`[^`\n]+`)'
  r'|(\*\*[^*\n]+\*\*)'
  r'|(~~[^~\n]+~~)'
  r'|((?<![*\w])\*[^*\s][^*\n]*\*(?![*\w]))'
  r'|((?<![_\w])_[^_\s][^_\n]*_(?![_\w]))'
  r'|(\[[^\]\n]*\]\([^)\n]*\))'
  r'|(https?://[^\s]+)'
  r'|((?<![\w/@])@[\w.-]+)'
  r'|((?<![\w&#])#[\w-]+)',
);

List<InlineSpan> _markdownSpans(String text, TextStyle base, RaftTokens t) {
  final dim = t.colors['foreground-placeholder']!;
  final link = MessageContentSemantic(t).link;
  final quote = MessageContentSemantic(t).quote;
  final mono = base.copyWith(
    fontFamily: t.monoFont,
    fontFamilyFallback: null,
    backgroundColor: t.colors['fill-muted'],
  );
  TextSpan marker(String s, [TextStyle? over]) => TextSpan(
    text: s,
    style: (over ?? base).copyWith(color: dim),
  );

  List<InlineSpan> inline(String s, TextStyle style) {
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > cursor) {
        out.add(TextSpan(text: s.substring(cursor, m.start), style: style));
      }
      final g = m[0]!;
      if (m[1] != null) {
        out
          ..add(marker('`', style))
          ..add(TextSpan(text: g.substring(1, g.length - 1), style: mono))
          ..add(marker('`', style));
      } else if (m[2] != null) {
        out
          ..add(marker('**', style))
          ..add(
            TextSpan(
              text: g.substring(2, g.length - 2),
              style: style.copyWith(fontWeight: FontWeight.w700),
            ),
          )
          ..add(marker('**', style));
      } else if (m[3] != null) {
        out
          ..add(marker('~~', style))
          ..add(
            TextSpan(
              text: g.substring(2, g.length - 2),
              style: style.copyWith(decoration: TextDecoration.lineThrough),
            ),
          )
          ..add(marker('~~', style));
      } else if (m[4] != null || m[5] != null) {
        final mark = g[0];
        out
          ..add(marker(mark, style))
          ..add(
            TextSpan(
              text: g.substring(1, g.length - 1),
              style: style.copyWith(fontStyle: FontStyle.italic),
            ),
          )
          ..add(marker(mark, style));
      } else if (m[6] != null) {
        final close = g.indexOf('](');
        out
          ..add(marker('[', style))
          ..add(
            TextSpan(
              text: g.substring(1, close),
              style: style.copyWith(color: link),
            ),
          )
          ..add(marker(g.substring(close), style));
      } else {
        out.add(
          TextSpan(
            text: g,
            style: style.copyWith(
              color: link,
              fontWeight: m[7] == null ? FontWeight.w600 : null,
            ),
          ),
        );
      }
      cursor = m.end;
    }
    if (cursor < s.length) {
      out.add(TextSpan(text: s.substring(cursor), style: style));
    }
    return out;
  }

  final spans = <InlineSpan>[];
  var fenced = false;
  final lines = text.split('\n');
  for (final (i, line) in lines.indexed) {
    final nl = i == lines.length - 1 ? '' : '\n';
    if (_fenceLine.hasMatch(line)) {
      fenced = !fenced;
      spans.add(
        TextSpan(
          text: line,
          style: mono.copyWith(color: dim),
        ),
      );
    } else if (fenced) {
      spans.add(TextSpan(text: line, style: mono));
    } else if (_headingLine.firstMatch(line) case final m?) {
      final style = base.copyWith(fontWeight: FontWeight.w700);
      spans
        ..add(marker('${m[1]}${m[2]}', style))
        ..addAll(inline(m[3]!, style));
    } else if (_quoteLine.firstMatch(line) case final m?) {
      spans
        ..add(marker(m[1]!))
        ..addAll(inline(m[2]!, base.copyWith(color: quote)));
    } else if (_listLine.firstMatch(line) case final m?) {
      spans
        ..add(marker(m[1]!, base.copyWith(fontWeight: FontWeight.w700)))
        ..addAll(inline(m[2]!, base));
    } else {
      spans.addAll(inline(line, base));
    }
    if (nl.isNotEmpty) spans.add(TextSpan(text: nl, style: base));
  }
  return spans;
}

// ---------------------------------------------------------------------------
// Shared small controls.
// ---------------------------------------------------------------------------

/// Same surface as the composer's attach buttons (transparent, ghost hover).
class _ToolRecipe extends RaftControlRecipe {
  const _ToolRecipe(RaftTokens tokens, {this.on = false, this.framed = false})
    : super(tokens, variant: RaftControlVariant.ghost);

  /// Brutal: the composer's attach-button frame (border + hard shadow); the
  /// dense format toolbar stays flat until a button is on.
  final bool on, framed;
  @override
  Color get background => tokens.brutal ? Colors.white : Colors.transparent;
  @override
  Color backgroundForInteraction({
    bool hovered = false,
    bool pressed = false,
  }) => on
      ? (tokens.brutal
            ? tokens.colors['color-brutal-cyan'] ??
                  tokens.colors['fill-strong']!
            : tokens.colors['fill-strong']!)
      : tokens.brutal
      ? Colors.white
      : hovered || pressed
      ? tokens.colors['fill-strong']!.withValues(alpha: .8)
      : Colors.transparent;
  @override
  Color foregroundFor({bool hovered = false}) => tokens.brutal
      ? Colors.black
      : (hovered || on)
      ? tokens.strong
      : tokens.colors['foreground-icon']!;
  @override
  Color get foreground => foregroundFor();
  @override
  BorderSide side({bool hovered = false}) => tokens.brutal
      ? (on || framed
            ? const BorderSide(color: Colors.black, width: 2)
            : BorderSide.none)
      : BorderSide.none;
  @override
  BorderRadius get radius => BorderRadius.circular(tokens.brutal ? 0 : 6);
  @override
  EdgeInsets get padding => EdgeInsets.all(tokens.brutal ? 4 : 5);
  @override
  Gradient? get overlayGradient => null;
  @override
  double get insetHighlightAlpha => 0;
  @override
  List<BoxShadow> shadows({
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
  }) => [
    if (tokens.brutal && framed)
      BoxShadow(
        color: Colors.black,
        offset: pressed
            ? const Offset(1, 1)
            : hovered
            ? const Offset(4, 4)
            : const Offset(2, 2),
      ),
    if (focused) BoxShadow(color: focusRing, spreadRadius: 2),
  ];
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    super.key,
    this.glyph,
    this.label,
    required this.tooltip,
    required this.onPressed,
    this.on = false,
    this.framed = false,
    this.size = 28,
    this.labelStyle,
  });
  final RaftGlyph? glyph;
  final String? label;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool on, framed;
  final double size;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final recipe = _ToolRecipe(t, on: on, framed: framed);
    return RaftControl(
      focusOnPointer: false,
      visualWidth: size,
      visualHeight: size,
      minimumTargetSize: size,
      variant: RaftControlVariant.ghost,
      recipe: recipe,
      semanticLabel: tooltip,
      tooltip: tooltip,
      onPressed: onPressed,
      child: glyph != null
          ? RaftIcon(glyph!, size: 14)
          : Text(
              label!,
              style:
                  labelStyle ??
                  RaftTypography.heading(
                    t,
                    size: 14,
                    line: 16,
                    color: recipe.foreground,
                  ),
            ),
    );
  }
}

class _Rule extends StatelessWidget {
  const _Rule({this.vertical = false});
  final bool vertical;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final color = t.brutal ? Colors.black : t.colors['line-muted']!;
    final w = t.brutal ? 2.0 : 1.0;
    return vertical
        ? SizedBox(
            width: w,
            child: ColoredBox(color: color),
          )
        : SizedBox(
            height: w,
            child: ColoredBox(color: color),
          );
  }
}

// ---------------------------------------------------------------------------
// 1. The inline composer: grows with its content (1..6 lines, then scrolls);
//    from the 3rd line a small expand button sits at the editor's top-right.
// ---------------------------------------------------------------------------

class RaftExpandableComposerPrototype extends StatefulWidget {
  const RaftExpandableComposerPrototype({
    super.key,
    required this.controller,
    this.focusNode,
    this.hint = 'Message #general',
    this.onExpand,
    this.taskChecked = false,
    this.onTaskChanged,
    this.desktop = true,
    this.hasAttachments = false,
  });
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final VoidCallback? onExpand;
  final bool taskChecked;
  final ValueChanged<bool>? onTaskChanged;
  final bool desktop, hasAttachments;

  /// Lines at which the expand button appears (Kevin: "more than two lines").
  static const expandAtLines = 3;
  static const buttonFace = 24.0;

  @override
  State<RaftExpandableComposerPrototype> createState() =>
      _ExpandableComposerState();
}

class _ExpandableComposerState extends State<RaftExpandableComposerPrototype> {
  late final FocusNode focus = widget.focusNode ?? FocusNode();
  bool focused = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    if (widget.focusNode == null) focus.dispose();
    super.dispose();
  }

  int _lines(String text, TextStyle style, double width, TextScaler scaler) {
    if (text.isEmpty || width <= 0) return 1;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final n = painter.computeLineMetrics().length;
    painter.dispose();
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final recipe = RaftComposerRecipe(
      t,
      desktop: widget.desktop,
      bottomSafeInset: 0,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final text = widget.controller.text;
    final submit = text.trim().isNotEmpty || widget.hasAttachments;
    // The button slot is reserved at the right of the text once shown: the
    // line count is always measured with the slot, so showing the button never
    // changes whether it is shown (no flicker at the threshold).
    final slot = RaftExpandableComposerPrototype.buttonFace + 4;
    return Container(
      decoration: recipe.hostDecoration,
      padding: recipe.hostInset,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final textWidth =
              constraints.maxWidth -
              recipe.shellInset.horizontal -
              recipe.editorInset.horizontal;
          final lines = _lines(
            text,
            recipe.editorText,
            textWidth - slot,
            scaler,
          );
          final showExpand =
              lines >= RaftExpandableComposerPrototype.expandAtLines;
          final editorInset = recipe.editorInset.copyWith(
            right: recipe.editorInset.right + (showExpand ? slot : 0),
          );
          return Focus(
            onFocusChange: (v) => setState(() => focused = v),
            child: Container(
              decoration: recipe.shellDecoration(focused: focused),
              padding: recipe.shellInset,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Stack(
                    children: [
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: recipe.editorMinimum,
                          maxHeight: recipe.editorMaximum,
                        ),
                        child: Padding(
                          padding: editorInset,
                          child: RaftCssLineBox(
                            style: recipe.editorText,
                            textScaler: scaler,
                            child: TextField(
                              controller: widget.controller,
                              focusNode: focus,
                              minLines: 1,
                              maxLines: 6,
                              style: recipe.editorText,
                              decoration: InputDecoration(
                                hintText: widget.hint,
                                hintStyle: recipe.placeholder,
                                filled: false,
                                isDense: true,
                                contentPadding: EdgeInsets.zero,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                              ),
                              textCapitalization: TextCapitalization.sentences,
                            ),
                          ),
                        ),
                      ),
                      if (showExpand)
                        Positioned(
                          top: t.brutal ? 0 : 8,
                          right: t.brutal ? 0 : 8,
                          child: _ToolButton(
                            key: const ValueKey('composer-expand'),
                            glyph: RaftGlyph.maximize2,
                            framed: true,
                            tooltip: 'Expand editor',
                            size: RaftExpandableComposerPrototype.buttonFace,
                            onPressed: widget.onExpand,
                          ),
                        ),
                    ],
                  ),
                  SizedBox(height: recipe.shellGap),
                  _ComposerToolbar(
                    recipe: recipe,
                    taskChecked: widget.taskChecked,
                    onTaskChanged: widget.onTaskChanged,
                    submitEnabled: submit,
                    hint: null,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The composer's own toolbar row (attach, task toggle, send), reused by the
/// expanded editor so both views offer the same actions.
class _ComposerToolbar extends StatelessWidget {
  const _ComposerToolbar({
    required this.recipe,
    required this.taskChecked,
    required this.onTaskChanged,
    required this.submitEnabled,
    required this.hint,
  });
  final RaftComposerRecipe recipe;
  final bool taskChecked, submitEnabled;
  final ValueChanged<bool>? onTaskChanged;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Transform.translate(
      offset: recipe.toolbarPaintOffset,
      child: Padding(
        padding: recipe.toolbarInset,
        child: Row(
          children: [
            RaftComposerAction(
              glyph: RaftGlyph.imagePlus,
              tooltip: 'Attach media',
              onPressed: () {},
            ),
            SizedBox(width: recipe.actionGap),
            RaftComposerAction(
              glyph: RaftGlyph.paperclip,
              tooltip: 'Attach file',
              onPressed: () {},
            ),
            if (hint != null) ...[
              SizedBox(width: recipe.toolbarGap),
              Expanded(
                child: Text(
                  hint!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: recipe.suggestionMeta.copyWith(
                    color: t.colors['foreground-placeholder'],
                  ),
                ),
              ),
            ] else
              const Spacer(),
            SizedBox(width: recipe.toolbarGap),
            RaftComposerTaskToggle(
              checked: taskChecked,
              label: 'As task',
              onChanged: onTaskChanged,
            ),
            SizedBox(width: recipe.metaGap),
            RaftComposerAction(
              glyph: RaftGlyph.send,
              tooltip: 'Send',
              submit: true,
              onPressed: submitEnabled ? () {} : null,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 2. The expanded editor. Desktop: a large dialog (this widget is the card);
//    phone: a full-screen page (phone: true). Same controller as the inline
//    composer, so the draft, selection and undo history are shared.
// ---------------------------------------------------------------------------

class RaftExpandedComposerPrototype extends StatefulWidget {
  const RaftExpandedComposerPrototype({
    super.key,
    required this.controller,
    required this.phone,
    this.channel = '#general',
    this.onCollapse,
    this.taskChecked = false,
    this.onTaskChanged,
    this.showPreview = true,
  });
  final TextEditingController controller;
  final bool phone;
  final String channel;
  final VoidCallback? onCollapse;
  final bool taskChecked;
  final ValueChanged<bool>? onTaskChanged;
  final bool showPreview;

  @override
  State<RaftExpandedComposerPrototype> createState() =>
      _ExpandedComposerState();
}

class _ExpandedComposerState extends State<RaftExpandedComposerPrototype> {
  final focus = FocusNode();
  late bool preview = widget.showPreview;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    focus.dispose();
    super.dispose();
  }

  void apply(TextEditingValue Function(TextEditingValue) op) {
    widget.controller.value = op(widget.controller.value);
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final phone = widget.phone;
    final recipe = RaftComposerRecipe(t, desktop: !phone, bottomSafeInset: 0);
    final scaler = MediaQuery.textScalerOf(context);
    final text = widget.controller.text;
    final editorStyle = recipe.editorText;

    final shortcuts = <ShortcutActivator, VoidCallback>{
      for (final (key, shift, op)
          in <
            (
              LogicalKeyboardKey,
              bool,
              TextEditingValue Function(TextEditingValue),
            )
          >[
            (
              LogicalKeyboardKey.keyB,
              false,
              (v) => RaftMarkdownFormat.wrap(v, '**'),
            ),
            (
              LogicalKeyboardKey.keyI,
              false,
              (v) => RaftMarkdownFormat.wrap(v, '*'),
            ),
            (LogicalKeyboardKey.keyK, false, RaftMarkdownFormat.link),
            (
              LogicalKeyboardKey.keyX,
              true,
              (v) => RaftMarkdownFormat.wrap(v, '~~'),
            ),
          ]) ...{
        SingleActivator(key, control: true, shift: shift): () => apply(op),
        SingleActivator(key, meta: true, shift: shift): () => apply(op),
      },
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          widget.onCollapse?.call(),
    };

    final editor = CallbackShortcuts(
      bindings: shortcuts,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          recipe.editorInset.left,
          recipe.editorInset.top,
          recipe.editorInset.right,
          8,
        ),
        child: RaftCssLineBox(
          style: editorStyle,
          textScaler: scaler,
          child: TextField(
            controller: widget.controller,
            focusNode: focus,
            expands: true,
            minLines: null,
            maxLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: editorStyle,
            decoration: InputDecoration(
              hintText: 'Message ${widget.channel}',
              hintStyle: recipe.placeholder,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
            ),
            textCapitalization: TextCapitalization.sentences,
          ),
        ),
      ),
    );

    Widget previewPane() => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'PREVIEW  ·  as sent',
            style: RaftTypography.body(
              t,
              size: 11,
              line: 16,
              weight: FontWeight.w700,
              color: t.colors['foreground-placeholder'],
            ).copyWith(letterSpacing: .6),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: text.trim().isEmpty
                ? Text('Nothing to preview yet.', style: recipe.placeholder)
                : RaftMessageBody(content: text),
          ),
        ),
      ],
    );

    final formatBar = _FormatToolbar(
      apply: apply,
      preview: preview,
      showPreviewToggle: !phone,
      onPreview: () => setState(() => preview = !preview),
    );

    final Widget body = phone
        ? (preview ? previewPane() : editor)
        : (preview
              ? Row(
                  children: [
                    Expanded(child: editor),
                    const _Rule(vertical: true),
                    Expanded(child: previewPane()),
                  ],
                )
              : editor);

    final card = DecoratedBox(
      decoration: recipe.shellDecoration(focused: true),
      child: Padding(
        padding: recipe.shellInset,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(recipe.shellRadius),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Desktop: toolbar above the text. Phone: between the text and
              // the action row, so it rides directly above the keyboard.
              if (!phone) ...[formatBar, const _Rule()],
              Expanded(child: body),
              if (phone && !preview) ...[const _Rule(), formatBar],
              const _Rule(),
              _ComposerToolbar(
                recipe: recipe,
                taskChecked: widget.taskChecked,
                onTaskChanged: widget.onTaskChanged,
                submitEnabled: text.trim().isNotEmpty,
                hint: phone ? null : 'Enter adds a line  ·  Ctrl+Enter sends',
              ),
            ],
          ),
        ),
      ),
    );

    final title = Text(
      'Message ${widget.channel}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: RaftTypography.heading(t, size: 18, line: 28, color: t.ink),
    );
    final collapse = RaftRecipeButton(
      variant: RaftButtonRecipeVariant.ghost,
      size: RaftButtonRecipeSize.iconSm,
      glyph: RaftGlyph.minimize,
      tooltip: 'Collapse editor',
      onPressed: widget.onCollapse,
      foreground: t.brutal ? Colors.black : t.colors['foreground-muted'],
      brutalSurface: (t, hovered) => BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 2),
        boxShadow: const [
          BoxShadow(color: Color(0xff141111), offset: Offset(2, 2)),
        ],
      ),
    );

    if (!phone) {
      return RaftRecipeCard(
        maxWidth: 1040,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 16,
              children: [
                Expanded(child: title),
                collapse,
              ],
            ),
            const SizedBox(height: 16),
            Flexible(child: card),
          ],
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(color: t.panel),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                spacing: 8,
                children: [
                  collapse,
                  Expanded(child: title),
                  RaftRecipeSegmentedControl<bool>(
                    value: preview,
                    items: const [
                      (false, null, 'Write'),
                      (true, RaftGlyph.eye, 'Preview'),
                    ],
                    onChanged: (v) => setState(() => preview = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: card,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatToolbar extends StatelessWidget {
  const _FormatToolbar({
    required this.apply,
    required this.preview,
    required this.showPreviewToggle,
    required this.onPreview,
  });
  final void Function(TextEditingValue Function(TextEditingValue)) apply;
  final bool preview, showPreviewToggle;
  final VoidCallback onPreview;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final fg = t.brutal ? Colors.black : t.colors['foreground-icon']!;
    TextStyle face({
      FontWeight w = FontWeight.w400,
      FontStyle s = FontStyle.normal,
      TextDecoration d = TextDecoration.none,
    }) => RaftTypography.heading(
      t,
      size: 14,
      line: 16,
      weight: w,
      color: fg,
    ).copyWith(fontStyle: s, decoration: d);
    const gap = SizedBox(width: 2);
    const sep = Padding(
      padding: EdgeInsets.symmetric(horizontal: 6),
      child: SizedBox(height: 16, child: _Rule(vertical: true)),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _ToolButton(
                    label: 'B',
                    labelStyle: face(w: FontWeight.w800),
                    tooltip: 'Bold  (Ctrl+B)',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.wrap(v, '**')),
                  ),
                  gap,
                  _ToolButton(
                    label: 'I',
                    labelStyle: face(s: FontStyle.italic),
                    tooltip: 'Italic  (Ctrl+I)',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.wrap(v, '*')),
                  ),
                  gap,
                  _ToolButton(
                    label: 'S',
                    labelStyle: face(d: TextDecoration.lineThrough),
                    tooltip: 'Strikethrough  (Ctrl+Shift+X)',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.wrap(v, '~~')),
                  ),
                  sep,
                  _ToolButton(
                    label: 'H',
                    labelStyle: face(w: FontWeight.w800),
                    tooltip: 'Heading',
                    onPressed: () => apply(RaftMarkdownFormat.heading),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.textQuote,
                    tooltip: 'Quote',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.linePrefix(v, '> ')),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.list,
                    tooltip: 'Bulleted list',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.linePrefix(v, '- ')),
                  ),
                  gap,
                  _ToolButton(
                    label: '1.',
                    labelStyle: face(w: FontWeight.w600),
                    tooltip: 'Numbered list',
                    onPressed: () => apply(
                      (v) => RaftMarkdownFormat.linePrefix(
                        v,
                        '1. ',
                        ordered: true,
                      ),
                    ),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.listChecks,
                    tooltip: 'Task list',
                    onPressed: () => apply(
                      (v) => RaftMarkdownFormat.linePrefix(v, '- [ ] '),
                    ),
                  ),
                  sep,
                  _ToolButton(
                    glyph: RaftGlyph.code,
                    tooltip: 'Inline code',
                    onPressed: () => apply(
                      (v) =>
                          RaftMarkdownFormat.wrap(v, '`', placeholder: 'code'),
                    ),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.terminal,
                    tooltip: 'Code block',
                    onPressed: () => apply(RaftMarkdownFormat.codeBlock),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.link,
                    tooltip: 'Link  (Ctrl+K)',
                    onPressed: () => apply(RaftMarkdownFormat.link),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.columns3,
                    tooltip: 'Table',
                    onPressed: () => apply(
                      (v) => RaftMarkdownFormat.insert(
                        v,
                        RaftMarkdownFormat.table,
                      ),
                    ),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.minus,
                    tooltip: 'Divider',
                    onPressed: () => apply(
                      (v) =>
                          RaftMarkdownFormat.insert(v, RaftMarkdownFormat.rule),
                    ),
                  ),
                  sep,
                  _ToolButton(
                    glyph: RaftGlyph.atSign,
                    tooltip: 'Mention',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.insert(v, '@')),
                  ),
                  gap,
                  _ToolButton(
                    glyph: RaftGlyph.hash,
                    tooltip: 'Channel or task',
                    onPressed: () =>
                        apply((v) => RaftMarkdownFormat.insert(v, '#')),
                  ),
                ],
              ),
            ),
          ),
          if (showPreviewToggle) ...[
            const SizedBox(width: 8),
            _ToolButton(
              glyph: preview ? RaftGlyph.eye : RaftGlyph.eyeOff,
              tooltip: preview ? 'Hide preview' : 'Show preview',
              on: preview,
              onPressed: onPreview,
            ),
          ],
        ],
      ),
    );
  }
}

/// Sample draft used by the design renders.
String raftComposerExpandSampleDraft() => raftProgrammaticEditingText(
  '## Release plan for 0.2\n'
  '\n'
  'Here is what **ships Friday** and what is *deferred*:\n'
  '\n'
  '- Composer expand button (#153)\n'
  '- ~~Legacy export~~ moved to next sprint\n'
  '\n'
  '1. Cut the branch\n'
  '2. Run `tool/check-project`\n'
  '\n'
  '- [ ] Update the changelog\n'
  '\n'
  '> Reminder: the freeze starts at 17:00.\n'
  '\n'
  '```dart\n'
  'void main() => print(\'hello\');\n'
  '```\n'
  '\n'
  'See the [design notes](https://example.com/design) and ping @cindy in #general. 中文输入也可以。\n'
  '\n'
  '| Surface | Entry |\n'
  '| --- | --- |\n'
  '| Desktop | Dialog |\n'
  '| Phone | Full screen |\n',
);
