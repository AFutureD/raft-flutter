import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'tap_slop.dart';
import 'icons.dart';
import 'localization.dart';
import 'recipe_surface.dart';
import 'recipes/composer_suggestion_list.g.dart';
import 'theme.dart';

/// MessageInput normal/compact host, distinct from the generic RUI Composer.
enum RaftComposerVariant { normal, compact }

/// Mounted MessageInput + RUI Composer slots, pinned at 26f77ef / RUI 0.5.27.
/// The caller owns overlay positioning, loading and whether SafeArea was consumed.
@immutable
class RaftComposerRecipe {
  const RaftComposerRecipe(
    this.tokens, {
    required this.desktop,
    this.variant = RaftComposerVariant.normal,
    this.bottomSafeInset = 0,
  }) : assert(bottomSafeInset >= 0);

  final RaftTokens tokens;
  final bool desktop;
  final RaftComposerVariant variant;
  final double bottomSafeInset;
  bool get compact => variant == RaftComposerVariant.compact;

  // MessageInput2490; index.css755. The recipe stays pure: RaftComposer passes
  // raftBottomInset (MediaQuery.paddingOf, 0 while the keyboard is up).
  EdgeInsets get hostInset => compact
      ? EdgeInsets.zero
      : EdgeInsets.fromLTRB(12, 12, 12, 16 + bottomSafeInset);
  BoxDecoration get hostDecoration => BoxDecoration(
    color: tokens.panel,
    border: compact
        ? null
        : Border(
            top: BorderSide(color: tokens.colors['line-muted']!, width: 1),
          ),
  );
  EdgeInsets get shellInset => EdgeInsets.zero;
  double get shellGap => 8;
  double get shellRadius => 8;
  BoxDecoration shellDecoration({required bool focused}) => BoxDecoration(
    color: tokens.panel,
    borderRadius: BorderRadius.circular(shellRadius),
    // CSS ring sits outside the border box: use a spread shadow, never an
    // interior Flutter Border that changes the editor's content bounds.
    boxShadow: tokens.dark
        ? [
            if (focused)
              BoxShadow(
                color: tokens.colors['accent-400']!.withValues(alpha: .7),
                spreadRadius: .5,
              ),
          ]
        : [
            ...tokens.shadows,
            BoxShadow(color: tokens.colors['ink-6']!, spreadRadius: 1),
          ],
  );

  // MessageInput product override wins over generic Elegant min-h-16.
  double get editorMinimum => desktop ? 40 : 20;
  double get editorMaximum => 128;
  EdgeInsets get editorInset => const EdgeInsets.fromLTRB(12, 12, 12, 0);
  TextStyle get editorText => RaftTypography.heading(
    tokens,
    size: desktop ? 14 : 16,
    line: 20,
    weight: FontWeight.w400,
  ).copyWith(color: tokens.strong);
  TextStyle get placeholder =>
      editorText.copyWith(color: tokens.colors['foreground-placeholder']);
  EdgeInsets get toolbarInset => const EdgeInsets.fromLTRB(10, 4, 10, 10);
  Offset get toolbarPaintOffset => const Offset(0, 4);
  double get toolbarGap => 8;
  double get actionGap => 6;
  double get metaGap => 12; // Actual task + submit wrapper, MessageInput2970.
  double get actionFace => 28;
  double get submitFace => 28;
  double get glyphSize => 14;

  // composer-suggestion.recipe.ts / index.mjs13809–13910.
  double get suggestionMaximum => 204;
  double get suggestionBottomGap => 4;
  // Brutal `border-2` sits inside the box: content starts inside it.
  EdgeInsets get suggestionInset => EdgeInsets.all(4);
  BoxDecoration get suggestionDecoration => BoxDecoration(
    color: tokens.popover,
    borderRadius: BorderRadius.circular(8),
    boxShadow: [
      ...tokens.shadows,
      if (!tokens.dark)
        BoxShadow(color: tokens.colors['ink-6']!, spreadRadius: 1),
    ],
  );
  EdgeInsets get suggestionGroupInset =>
      const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
  TextStyle get suggestionGroupLabel => RaftTypography.body(
    tokens,
    size: 11,
    line: 11,
    weight: FontWeight.w500,
    color: tokens.strong.withValues(alpha: .45),
  ).copyWith(letterSpacing: -.055);
  Color suggestionBackground({
    required bool highlighted,
    bool hovered = false,
  }) =>
      RaftComposerSuggestionListRecipe.resolve(
        theme: tokens.recipeTheme,
        states: tokens.recipeStates(
          hovered: hovered,
          extra: [if (highlighted) 'data-highlighted=true'],
        ),
        tokens: tokens.recipeTokens,
      ).item.backgroundColor?.resolve(tokens.recipeTokens) ??
      Colors.transparent;
  TextStyle suggestionTitle({
    required bool highlighted,
    bool hovered = false,
  }) => RaftTypography.body(
    tokens,
    size: 13,
    line: 19.5,
    weight: FontWeight.w500,
    color: highlighted || hovered ? tokens.ink : tokens.muted,
  ).copyWith(letterSpacing: -.065);

  /// `ComposerSuggestionIcon variant="auxiliary"`: brutal `text-black/40`.
  Color get suggestionAuxiliary => tokens.colors['foreground-placeholder']!;

  /// `ComposerSuggestionMeta variant="code"`: `text-xs font-mono`
  /// (brutal `text-black/40`), bold with the highlighted option.
  TextStyle suggestionCode({bool highlighted = false}) => TextStyle(
    fontFamily: tokens.monoFont,
    fontSize: 12,
    height: 16 / 12,
    fontWeight: highlighted ? FontWeight.w700 : FontWeight.w500,
    color: tokens.colors['foreground-placeholder'],
  );

  TextStyle get suggestionMeta => suggestionMetaFor();

  /// Meta sets no weight: it inherits the option's `font-medium`, or
  /// `data-[highlighted=true]:font-bold` (brutal).
  TextStyle suggestionMetaFor({bool highlighted = false}) =>
      RaftTypography.body(
        tokens,
        size: 12,
        line: 16,
        weight: FontWeight.w500,
        color: tokens.colors['foreground-placeholder'],
      );
}

/// ComposerIconButton uses Button's interaction machinery but its own surface.
class _ComposerAttachRecipe extends RaftControlRecipe {
  const _ComposerAttachRecipe(RaftTokens tokens)
    : super(tokens, variant: RaftControlVariant.ghost);
  @override
  Color get background => Colors.transparent;
  @override
  Color backgroundForInteraction({
    bool hovered = false,
    bool pressed = false,
  }) => hovered || pressed
      ? tokens.colors['fill-strong']!.withValues(alpha: .8)
      : Colors.transparent;
  @override
  Color foregroundFor({bool hovered = false}) =>
      hovered ? tokens.strong : tokens.colors['foreground-icon']!;
  @override
  Color get foreground => foregroundFor();
  @override
  BorderSide side({bool hovered = false}) => BorderSide.none;
  @override
  BorderRadius get radius => BorderRadius.circular(6);
  @override
  // ds-allow: Web raft-ui/composer.recipe.ts iconButton `p-[7px]` (elegant), `p-1` (brutal)
  EdgeInsets get padding => EdgeInsets.all(7);
  @override
  Gradient? get overlayGradient => null;
  @override
  double get insetHighlightAlpha => 0;
  @override
  List<BoxShadow> shadows({
    bool hovered = false,
    bool pressed = false,
    bool focused = false,
  }) => [if (focused) BoxShadow(color: focusRing, spreadRadius: 2)];
}

/// Pointer activation preserves editor focus; keyboard traversal remains enabled.
/// A picker may deliberately blur the editor in its app-owned callback.
class RaftComposerAction extends StatefulWidget {
  const RaftComposerAction({
    super.key,
    required this.glyph,
    required this.tooltip,
    required this.onPressed,
    this.submit = false,
    this.busy = false,
    this.spinner = false,
  });
  final RaftGlyph glyph;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool submit, busy;

  /// Spinner glyph on an otherwise plain (disabled) action, Web `Send` while
  /// files are checked or uploaded.
  final bool spinner;
  @override
  State<RaftComposerAction> createState() => _RaftComposerActionState();
}

class _RaftComposerActionState extends State<RaftComposerAction> {
  final focus = FocusNode();
  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final size = widget.submit ? 28.0 : 28.0;
    // Web sizes these buttons 26-28px with no touch inflation; Android's
    // 48dp guideline is met by routing nearby touches to them instead
    // (RaftTapSlopHost in the composer). Desktop keeps the exact box.
    final touch = RaftDensityScope.of(context) == RaftDensity.touch;
    return Listener(
      onPointerDown: (_) {},
      onPointerUp: (_) => focus.canRequestFocus = true,
      onPointerCancel: (_) => focus.canRequestFocus = true,
      child: RaftTapSlopAnchor(
        minSize: touch ? const Size.square(RaftMetrics.touchTarget) : Size.zero,
        child: RaftControl(
          focusNode: focus,
          focusOnPointer: false,
          visualWidth: size,
          visualHeight: size,
          minimumTargetSize: size,
          padding: widget.submit ? EdgeInsets.zero : null,
          variant: widget.submit
              ? RaftControlVariant.accent
              : RaftControlVariant.ghost,
          recipe: widget.submit ? null : _ComposerAttachRecipe(t),
          busy: widget.busy,
          semanticLabel: raftText(context, widget.tooltip),
          tooltip: raftText(context, widget.tooltip),
          onPressed: widget.onPressed,
          child: widget.busy || widget.spinner
              ? const RaftSpinner()
              : RaftIcon(widget.glyph, size: 14),
        ),
      ),
    );
  }
}
