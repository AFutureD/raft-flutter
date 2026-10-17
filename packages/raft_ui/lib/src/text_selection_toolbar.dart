import 'dart:math' as math;
import 'dart:ui' show SemanticsRole;

import 'package:flutter/cupertino.dart' show CupertinoTextSelectionToolbar;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'control_typography.dart';
import 'design_primitives.dart';
import 'icons.dart';
import 'recipe_surface.dart';
import 'recipes/message_text_selection_toolbar.g.dart';
import 'theme.dart';

/// Android text selection actions painted with the current Raft theme.
///
/// The caller supplies Flutter's actions and selection anchors. Other platforms
/// keep their adaptive toolbar. Unlike Material's fixed 44dp row, this toolbar
/// grows with text and scrolls its overflow page at large system font sizes.
class RaftTextSelectionToolbar extends StatefulWidget {
  const RaftTextSelectionToolbar.buttonItems({
    super.key,
    required this.anchors,
    required this.buttonItems,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  /// Shared builder for fields and [SelectableText], including the system
  /// context menu on platforms that support it.
  static Widget editableText(BuildContext context, EditableTextState state) =>
      SystemContextMenu.isSupportedByField(state)
      ? SystemContextMenu.editableText(editableTextState: state)
      : RaftTextSelectionToolbar.buttonItems(
          anchors: state.contextMenuAnchors,
          buttonItems: state.contextMenuButtonItems,
        );

  static Widget selectableRegion(
    BuildContext context,
    SelectableRegionState state,
  ) => RaftTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: state.contextMenuButtonItems,
  );

  @override
  State<RaftTextSelectionToolbar> createState() =>
      _RaftTextSelectionToolbarState();
}

class _RaftTextSelectionToolbarState extends State<RaftTextSelectionToolbar> {
  bool overflowOpen = false;

  @override
  void didUpdateWidget(RaftTextSelectionToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.buttonItems != widget.buttonItems) overflowOpen = false;
  }

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).platform != TargetPlatform.android) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: widget.anchors,
        buttonItems: widget.buttonItems,
      );
    }
    if (widget.buttonItems.isEmpty) return const SizedBox.shrink();
    final t = RaftTokens.of(context), rt = t.recipeTokens;
    final recipe = RaftMessageTextSelectionToolbarRecipe.resolve(
      theme: t.recipeTheme,
      states: t.recipeStates(),
      tokens: rt,
    );
    final textStyle = RaftControlTypography.of(
      context,
      recipe.button.text(
        rt,
        base: recipe.toolbar.text(rt, base: DefaultTextStyle.of(context).style),
      ),
    );
    final labels = [
      for (final item in widget.buttonItems)
        AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
    ];
    const screenGap = CupertinoTextSelectionToolbar.kToolbarScreenPadding;
    final safe = MediaQuery.paddingOf(context);
    final insets = EdgeInsets.fromLTRB(
      safe.left + screenGap,
      safe.top + screenGap,
      safe.right + screenGap,
      math.max(safe.bottom, MediaQuery.viewInsetsOf(context).bottom) +
          screenGap,
    );
    final adjustment = Offset(insets.left, insets.top);
    final above =
        widget.anchors.primaryAnchor - adjustment - const Offset(0, 8);
    final below =
        (widget.anchors.secondaryAnchor ?? widget.anchors.primaryAnchor) -
        adjustment +
        const Offset(0, TextSelectionToolbar.kToolbarContentDistanceBelow);
    return Padding(
      padding: insets,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final border = recipe.toolbar.borderWidth;
          final inset = recipe.toolbar.padding + border;
          final width = math.max(0.0, constraints.maxWidth - inset.horizontal);
          final widths = [
            for (final label in labels)
              _labelWidth(
                context,
                label,
                textStyle,
                recipe.button.padding,
                width,
              ),
          ];
          final gap = recipe.toolbar.columnGap ?? 0;
          final navigationWidth = math.min(RaftMetrics.touchTarget, width);
          var count = widths.length;
          final fullWidth =
              widths.fold(0.0, (sum, w) => sum + w) + gap * (widths.length - 1);
          if (fullWidth > width) {
            count = 0;
            var used = navigationWidth;
            while (count < widths.length &&
                used + gap + widths[count] <= width) {
              used += gap + widths[count++];
            }
          }
          final hasOverflow = count < widths.length;
          final open = hasOverflow && overflowOpen;
          final rowWidth =
              widths.take(count).fold(0.0, (sum, w) => sum + w) +
              gap * math.max(0, count - 1) +
              (hasOverflow ? navigationWidth + (count > 0 ? gap : 0) : 0);
          final menuWidth = open
              ? math.max(rowWidth, widths.skip(count).reduce(math.max))
              : rowWidth;
          final aboveSpace = above.dy.clamp(0.0, constraints.maxHeight);
          final belowSpace = (constraints.maxHeight - below.dy).clamp(
            0.0,
            constraints.maxHeight,
          );
          // The SDK delegate uses the actual child height to choose its side.
          // Constrain scrolling to the larger free side so it also fits below.
          final height = math.max(aboveSpace, belowSpace);
          return CustomSingleChildLayout(
            delegate: TextSelectionToolbarLayoutDelegate(
              anchorAbove: above,
              anchorBelow: below,
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.escape):
                    ContextMenuController.removeAny,
              },
              child: FocusTraversalGroup(
                child: Semantics(
                  role: SemanticsRole.menu,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height),
                    child: RaftRecipeBox(
                      style: recipe.toolbar,
                      tokens: rt,
                      clip: true,
                      child: SizedBox(
                        width: menuWidth,
                        child: SingleChildScrollView(
                          child: open
                              ? Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Align(
                                      alignment: AlignmentDirectional.centerEnd,
                                      child: navigation(context, back: true),
                                    ),
                                    for (var i = count; i < labels.length; i++)
                                      _SelectionButton(
                                        label: labels[i],
                                        onPressed:
                                            widget.buttonItems[i].onPressed,
                                      ),
                                  ],
                                )
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  spacing: gap,
                                  children: [
                                    for (var i = 0; i < count; i++)
                                      SizedBox(
                                        width: widths[i],
                                        child: _SelectionButton(
                                          label: labels[i],
                                          onPressed:
                                              widget.buttonItems[i].onPressed,
                                        ),
                                      ),
                                    if (hasOverflow) navigation(context),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget navigation(BuildContext context, {bool back = false}) => SizedBox(
    width: RaftMetrics.touchTarget,
    child: _SelectionButton(
      label: back
          ? MaterialLocalizations.of(context).backButtonTooltip
          : MaterialLocalizations.of(context).moreButtonTooltip,
      glyph: back ? RaftGlyph.arrowLeft : RaftGlyph.ellipsis,
      onPressed: () => setState(() => overflowOpen = !back),
    ),
  );
}

double _labelWidth(
  BuildContext context,
  String label,
  TextStyle style,
  EdgeInsets padding,
  double available,
) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.localeOf(context),
  )..layout();
  final width = painter.width + padding.horizontal;
  painter.dispose();
  return width.clamp(math.min(RaftMetrics.touchTarget, available), available);
}

class _SelectionButton extends StatelessWidget {
  const _SelectionButton({required this.label, this.onPressed, this.glyph});
  final String label;
  final VoidCallback? onPressed;
  final RaftGlyph? glyph;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), rt = t.recipeTokens;
    return RaftInteractive(
      onPressed: onPressed,
      focusOnPointer: false,
      button: false,
      semanticRole: SemanticsRole.menuItem,
      semanticLabel: glyph == null ? null : label,
      tooltip: glyph == null ? null : label,
      builder: (context, state) => RaftRecipeBox(
        style: RaftMessageTextSelectionToolbarRecipe.resolve(
          theme: t.recipeTheme,
          states: t.recipeStates(
            hovered: state.hovered,
            pressed: state.pressed,
            focusVisible: state.focusVisible,
            disabled: onPressed == null,
          ),
          tokens: rt,
        ).button,
        tokens: rt,
        height: RaftMetrics.touchTarget,
        controlLabel: true,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: RaftMetrics.touchTarget),
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: glyph == null ? Text(label) : RaftIcon(glyph!),
          ),
        ),
      ),
    );
  }
}
