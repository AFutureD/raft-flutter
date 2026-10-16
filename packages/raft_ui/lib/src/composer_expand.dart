import 'package:flutter/material.dart';

import 'composer_recipe.dart';
import 'composer_tool_button.dart';
import 'design_primitives.dart';
import 'dialog_card.dart'
    show
        RaftRecipeButton,
        RaftRecipeCard,
        RaftRecipeSegmentedControl,
        RaftShadowSet;
import 'icons.dart';
import 'localization.dart';
import 'markdown_editing.dart';
import 'message_body.dart';
import 'recipes/button_variants.g.dart';
import 'settings_layout.dart' show RaftSpace;
import 'text_scaling.dart' show RaftScaled;
import 'tap_slop.dart';
import 'theme.dart';

// The expandable composer: the expand button on the inline editor, the
// Markdown toolbar, and the expanded editor (desktop dialog / phone page).

/// Frames the inline editor: from [expandAtLines] lines on, a small expand
/// button sits at the editor's top-right and the text keeps clear of it.
///
/// The line count is always measured with the button's slot reserved, so
/// showing the button never changes whether it is shown (no flicker at the
/// threshold). The editor stays at the same position in the tree whether or
/// not the button is shown, so focus and the IME connection survive.
class RaftComposerExpandable extends StatelessWidget {
  const RaftComposerExpandable({
    super.key,
    required this.text,
    required this.recipe,
    required this.onExpand,
    required this.builder,
  });

  /// Lines at which the expand button appears ("more than two lines").
  static const expandAtLines = 3;

  final String text;
  final RaftComposerRecipe recipe;
  final VoidCallback? onExpand;

  /// Builds the editor with the inset it must use.
  final Widget Function(EdgeInsets inset) builder;

  static const _face = RaftMetrics.buttonXs;
  static const _slot = _face + RaftSpace.x1;

  static int lineCount(
    String text,
    TextStyle style,
    double width,
    TextScaler scaler,
  ) {
    if (text.isEmpty || width <= 0) return 1;
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
    )..layout(maxWidth: width);
    final lines = painter.computeLineMetrics().length;
    painter.dispose();
    return lines;
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final base = recipe.editorInset;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - base.horizontal - _slot;
        final show =
            lineCount(text, recipe.editorText, width, scaler) >= expandAtLines;
        final inset = show ? base.copyWith(right: base.right + _slot) : base;
        return Stack(
          children: [
            builder(inset),
            if (show)
              Positioned(
                top: (base.top - RaftSpace.x1).clamp(0.0, double.infinity),
                right: (base.right - RaftSpace.x1).clamp(0.0, double.infinity),
                child: RaftComposerToolButton(
                  key: const ValueKey('composer-expand'),
                  glyph: RaftGlyph.maximize2,
                  tooltip: 'Expand editor',
                  face: _face,
                  framed: true,
                  prominent: true,
                  onPressed: onExpand,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// The Markdown toolbar: only styles the message renderer draws. Each button
/// edits the draft through [RaftMarkdownFormat] and leaves the editor focused.
class RaftComposerFormatToolbar extends StatelessWidget {
  const RaftComposerFormatToolbar({
    super.key,
    required this.controller,
    this.preview,
    this.onPreview,
  });
  final TextEditingController controller;

  /// Desktop only: whether the preview pane is showing, and its toggle.
  final bool? preview;
  final VoidCallback? onPreview;

  void _apply(TextEditingValue Function(TextEditingValue) op) =>
      controller.value = op(controller.value);

  @override
  Widget build(BuildContext context) {
    final line = _ruleColor(RaftTokens.of(context));
    Widget sep() => Padding(
      padding: const EdgeInsets.symmetric(horizontal: RaftSpace.x1_5),
      child: SizedBox(
        width: 1,
        height: RaftSpace.x4,
        child: ColoredBox(color: line),
      ),
    );
    Widget b(
      RaftGlyph glyph,
      String tooltip,
      TextEditingValue Function(TextEditingValue) op,
    ) => RaftComposerToolButton(
      glyph: glyph,
      tooltip: tooltip,
      onPressed: () => _apply(op),
    );
    const gap = SizedBox(width: RaftSpace.half);
    return Semantics(
      container: true,
      label: raftText(context, 'Formatting'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: RaftSpace.x2,
          vertical: RaftSpace.x1_5,
        ),
        child: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    b(
                      RaftGlyph.bold,
                      'Bold',
                      (v) => RaftMarkdownFormat.wrap(v, '**'),
                    ),
                    gap,
                    b(
                      RaftGlyph.italic,
                      'Italic',
                      (v) => RaftMarkdownFormat.wrap(v, '*'),
                    ),
                    gap,
                    b(
                      RaftGlyph.strikethrough,
                      'Strikethrough',
                      (v) => RaftMarkdownFormat.wrap(v, '~~'),
                    ),
                    sep(),
                    b(RaftGlyph.heading, 'Heading', RaftMarkdownFormat.heading),
                    gap,
                    b(
                      RaftGlyph.textQuote,
                      'Quote',
                      (v) => RaftMarkdownFormat.linePrefix(v, '> '),
                    ),
                    gap,
                    b(
                      RaftGlyph.list,
                      'Bulleted list',
                      (v) => RaftMarkdownFormat.linePrefix(v, '- '),
                    ),
                    gap,
                    b(
                      RaftGlyph.listOrdered,
                      'Numbered list',
                      (v) => RaftMarkdownFormat.linePrefix(
                        v,
                        '1. ',
                        ordered: true,
                      ),
                    ),
                    gap,
                    b(
                      RaftGlyph.listChecks,
                      'Task list',
                      (v) => RaftMarkdownFormat.linePrefix(v, '- [ ] '),
                    ),
                    sep(),
                    b(
                      RaftGlyph.code,
                      'Inline code',
                      (v) =>
                          RaftMarkdownFormat.wrap(v, '`', placeholder: 'code'),
                    ),
                    gap,
                    b(
                      RaftGlyph.terminal,
                      'Code block',
                      RaftMarkdownFormat.codeBlock,
                    ),
                    gap,
                    b(RaftGlyph.link, 'Link', RaftMarkdownFormat.link),
                    gap,
                    b(
                      RaftGlyph.table,
                      'Table',
                      (v) => RaftMarkdownFormat.insert(
                        v,
                        RaftMarkdownFormat.table,
                      ),
                    ),
                    gap,
                    b(
                      RaftGlyph.minus,
                      'Divider',
                      (v) =>
                          RaftMarkdownFormat.insert(v, RaftMarkdownFormat.rule),
                    ),
                    sep(),
                    b(
                      RaftGlyph.atSign,
                      'Mention',
                      (v) => RaftMarkdownFormat.trigger(v, '@'),
                    ),
                    gap,
                    b(
                      RaftGlyph.hash,
                      'Channel or task',
                      (v) => RaftMarkdownFormat.trigger(v, '#'),
                    ),
                  ],
                ),
              ),
            ),
            if (preview != null) ...[
              const SizedBox(width: RaftSpace.x2),
              RaftComposerToolButton(
                key: const ValueKey('composer-preview-toggle'),
                glyph: preview! ? RaftGlyph.eye : RaftGlyph.eyeOff,
                tooltip: preview! ? 'Hide preview' : 'Show preview',
                on: preview!,
                onPressed: onPreview,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Color _ruleColor(RaftTokens t) =>
    t.brutal ? Colors.black : t.colors['line-muted']!;

class _Rule extends StatelessWidget {
  const _Rule({this.vertical = false});
  final bool vertical;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final w = t.brutal ? 2.0 : 1.0;
    return vertical
        ? SizedBox(
            width: w,
            child: ColoredBox(color: _ruleColor(t)),
          )
        : SizedBox(
            height: w,
            child: ColoredBox(color: _ruleColor(t)),
          );
  }
}

/// The expanded editor. Desktop (wide): the card of a centered dialog with the
/// editor and a live preview side by side. Phone ([phone]): a full-screen page
/// with a Write / Preview switch and the toolbar above the keyboard.
///
/// It borrows everything from the composer that opened it: [editor] is that
/// composer's own text field (same controller, so the draft, selection and
/// mentions are shared), [footer] its action row, [frameEditor] wraps the field
/// for the @ / # suggestions.
class RaftComposerExpandedView extends StatefulWidget {
  const RaftComposerExpandedView({
    super.key,
    required this.phone,
    required this.title,
    required this.controller,
    required this.editor,
    required this.footer,
    required this.onCollapse,
    this.attachments,
    this.previewBuilder,
  });
  final bool phone;
  final String title;
  final TextEditingController controller;

  /// The composer's text field, built for the expanded editor.
  final Widget editor;

  /// Builds the action row (attach, task, send) for the given recipe.
  final Widget Function(RaftComposerRecipe recipe) footer;
  final VoidCallback onCollapse;
  final Widget? attachments;

  /// Renders the Markdown as it will be sent; defaults to [RaftMessageBody].
  final Widget Function(BuildContext context, String content)? previewBuilder;

  static const dialogMaxWidth = 1040.0, dialogMaxHeight = 760.0;

  @override
  State<RaftComposerExpandedView> createState() =>
      _RaftComposerExpandedViewState();
}

class _RaftComposerExpandedViewState extends State<RaftComposerExpandedView> {
  // Desktop: the preview pane shows by default. Phone: Write first.
  late bool preview = !widget.phone;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final phone = widget.phone;
    final recipe = RaftComposerRecipe(t, desktop: !phone, bottomSafeInset: 0);
    final inset = recipe.editorInset;
    final text = widget.controller.text.trim();

    final editor = Padding(
      padding: EdgeInsets.fromLTRB(
        inset.left,
        inset.top,
        inset.right,
        RaftSpace.x2,
      ),
      child: widget.editor,
    );
    final previewPane = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            RaftSpace.x4,
            RaftSpace.x3,
            RaftSpace.x4,
            0,
          ),
          child: Text(
            raftText(context, 'Preview · as sent'),
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
            key: const ValueKey('composer-preview'),
            padding: const EdgeInsets.fromLTRB(
              RaftSpace.x4,
              RaftSpace.x2,
              RaftSpace.x4,
              RaftSpace.x3,
            ),
            child: text.isEmpty
                ? Text(
                    raftText(context, 'Nothing to preview yet.'),
                    style: recipe.placeholder,
                  )
                : (widget.previewBuilder?.call(context, text) ??
                      RaftMessageBody(content: text)),
          ),
        ),
      ],
    );
    final toolbar = RaftComposerFormatToolbar(
      controller: widget.controller,
      preview: phone ? null : preview,
      onPreview: phone ? null : () => setState(() => preview = !preview),
    );
    final Widget body = phone
        ? (preview ? previewPane : editor)
        : (preview
              ? Row(
                  children: [
                    Expanded(child: editor),
                    const _Rule(vertical: true),
                    Expanded(child: previewPane),
                  ],
                )
              : editor);

    final card = DecoratedBox(
      key: const ValueKey('composer-expanded-card'),
      decoration: recipe.shellDecoration(focused: true),
      child: Padding(
        padding: recipe.shellInset,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(recipe.shellRadius),
          child: RaftTapSlopHost(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Desktop: toolbar above the text. Phone: between the text and
                // the action row, so it rides directly above the keyboard.
                if (!phone) ...[toolbar, const _Rule()],
                Expanded(child: body),
                if (phone && !preview) ...[const _Rule(), toolbar],
                if (widget.attachments != null) widget.attachments!,
                SizedBox(height: recipe.shellGap),
                widget.footer(recipe),
              ],
            ),
          ),
        ),
      ),
    );

    final grows = RaftScaled.grows(context);
    final title = Text(
      widget.title,
      maxLines: grows ? null : 1,
      overflow: grows ? TextOverflow.clip : TextOverflow.ellipsis,
      style: RaftTypography.heading(t, size: 18, line: 28, color: t.ink),
    );
    final collapse = RaftRecipeButton(
      key: const ValueKey('composer-collapse'),
      variant: RaftButtonRecipeVariant.ghost,
      size: RaftButtonRecipeSize.iconSm,
      glyph: RaftGlyph.minimize2,
      tooltip: raftText(context, 'Collapse editor'),
      onPressed: widget.onCollapse,
      foreground: t.brutal ? Colors.black : t.colors['foreground-muted'],
      brutalSurface: (t, hovered) => BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.black, width: 2),
        boxShadow: RaftShadowSet.brutalSm,
      ),
    );

    if (!phone) {
      return Semantics(
        scopesRoute: true,
        namesRoute: true,
        explicitChildNodes: true,
        label: widget.title,
        child: RaftRecipeCard(
          maxWidth: RaftComposerExpandedView.dialogMaxWidth,
          padding: const EdgeInsets.all(RaftSpace.x6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                spacing: RaftSpace.x4,
                children: [
                  Expanded(child: title),
                  collapse,
                ],
              ),
              const SizedBox(height: RaftSpace.x4),
              Flexible(child: card),
            ],
          ),
        ),
      );
    }
    final insets = MediaQuery.viewInsetsOf(context);
    // Larger text reflows: the Write / Preview switch drops under the title.
    Widget switcher({
      required Widget collapse,
      required Widget title,
      required Widget segmented,
    }) => grows
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: RaftSpace.x2,
            children: [
              Row(
                spacing: RaftSpace.x2,
                children: [
                  collapse,
                  Expanded(child: title),
                ],
              ),
              segmented,
            ],
          )
        : Row(
            spacing: RaftSpace.x2,
            children: [
              collapse,
              Expanded(child: title),
              segmented,
            ],
          );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: widget.title,
      child: ColoredBox(
        color: t.panel,
        child: Padding(
          padding: EdgeInsets.only(bottom: insets.bottom),
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      RaftSpace.x3,
                      RaftSpace.x2,
                      RaftSpace.x3,
                      RaftSpace.x2,
                    ),
                    child: switcher(
                      collapse: collapse,
                      title: title,
                      segmented: RaftRecipeSegmentedControl<bool>(
                        value: preview,
                        items: [
                          (false, null, raftTextZh(context, 'Write', '编辑')),
                          (true, RaftGlyph.eye, 'Preview'),
                        ],
                        onChanged: (v) => setState(() => preview = v),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        RaftSpace.x3,
                        0,
                        RaftSpace.x3,
                        RaftSpace.x3,
                      ),
                      child: card,
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

/// Layout of the dialog route: centered, capped, with the dialog's inset.
class RaftComposerExpandedDialog extends StatelessWidget {
  const RaftComposerExpandedDialog({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(RaftSpace.x4),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: RaftComposerExpandedView.dialogMaxWidth,
            maxHeight: RaftComposerExpandedView.dialogMaxHeight,
          ),
          child: SizedBox(height: size.height - RaftSpace.x4 * 2, child: child),
        ),
      ),
    );
  }
}
