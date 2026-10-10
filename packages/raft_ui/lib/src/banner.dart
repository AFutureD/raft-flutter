import 'dart:ui' show SemanticsRole;

import 'package:flutter/widgets.dart';

import 'icons.dart';
import 'localization.dart';
import 'recipe_surface.dart';
import 'recipes/banner.g.dart';
import 'recipes/recipe_runtime.dart' show RaftSlotStyle, RaftTokenResolver;
import 'theme.dart';

export 'recipes/banner.g.dart'
    show RaftBannerRecipeStatus, RaftBannerRecipeSize;

/// Product ui/Banner.tsx composition: BannerDescription keeps its own font
/// weight even when the caller makes the root bold. Geometry and colors come
/// from the generated public Banner recipe, including the real density axis.
class RaftBanner extends StatelessWidget {
  const RaftBanner({
    super.key,
    required this.description,
    this.title,
    this.status = RaftBannerRecipeStatus.warning,
    this.size = RaftBannerRecipeSize.md,
    this.strongPrefix,
    this.leading,
    this.descriptionWeight,
    this.titleGap,
    this.glyph,
    this.action,
  });

  /// ui/Banner.tsx `withIcon` / `icon`: the leading `svg` grid cell
  /// (`[&>svg]` size and intent colour from the recipe).
  final RaftGlyph? glyph;

  /// `actions` -> `BannerAction` (trailing grid cell, `gap-x` from the
  /// recipe).
  final Widget? action;

  /// Measured space between title and description where the Web grid adds
  /// it (MachineDetailPanel disk-low banner: 4px); null keeps the recipe.
  final double? titleGap;

  /// Icon / Status node before the copy (Web Banner `icon`, `gap-x-2`).
  final Widget? leading;

  /// Callsite weight of the description content (e.g. a `font-bold` span).
  final FontWeight? descriptionWeight;

  /// Leading part of [description] rendered `<strong>` (rich catalog copy).
  final String? strongPrefix;
  final String description;
  final String? title;
  final RaftBannerRecipeStatus status;
  final RaftBannerRecipeSize size;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context), tokens = t.recipeTokens;
    final recipe = RaftBannerRecipe.resolve(
      theme: t.recipeTheme,
      status: status,
      size: size,
      states: t.recipeStates(
        extra: {
          'group/banner:data-size=${size.css}',
          'group/banner:data-status=${status.css}',
          if (glyph != null) 'has:>svg',
          if (action != null) 'has:>data-slot=banner-action',
          if (title != null)
            'has:>data-slot=banner-description+has:>data-slot=banner-title',
        },
      ),
      tokens: tokens,
    );
    final base = recipe.root.text(
      tokens,
      base: DefaultTextStyle.of(context).style,
    );
    return Semantics(
      role: SemanticsRole.alert,
      child: RaftRecipeBox(
        style: recipe.root,
        tokens: tokens,
        child: _withLeading(
          recipe,
          tokens,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  // Measured: Web's Banner grid leaves 2px (Brutal) / 4px between title and description
                  // (also at `lg`) although the recipe declares no row gap.
                  padding: recipe.title.margin.copyWith(
                    bottom: titleGap ?? (RaftTokens.of(context).brutal ? 2 : 4),
                  ),
                  child: Text(
                    raftText(context, title!),
                    style: recipe.title.text(tokens, base: base),
                  ),
                ),
              if (strongPrefix != null && description.startsWith(strongPrefix!))
                Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: strongPrefix,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: description.substring(strongPrefix!.length),
                      ),
                    ],
                  ),
                  style: recipe.description.text(tokens, base: base),
                )
              else
                Text(
                  raftText(context, description),
                  style: recipe.description
                      .text(tokens, base: base)
                      .copyWith(fontWeight: descriptionWeight),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _withLeading(
    RaftBannerRecipeStyle recipe,
    RaftTokenResolver tokens,
    Widget content,
  ) {
    if (glyph == null && action == null) {
      return leading == null
          ? content
          : Row(
              children: [
                leading!,
                const SizedBox(width: 8),
                Expanded(child: content),
              ],
            );
    }
    final gap = recipe.root.columnGap ?? 8;
    final svg = recipe.root.target('& > svg');
    // Title + description: the svg spans both rows at the top (`mt-0.5`).
    final stacked = title != null;
    final brutal = recipe.root.borderWidth.top > 0;
    return LayoutBuilder(
      builder: (context, box) {
        // `@max-[24rem]` on the root container: the action drops to its own
        // full-width row, end aligned (`mt-2` Brutal / `mt-1` Elegant).
        final below = action != null && box.maxWidth <= 384;
        final main = _rowOf(
          stacked,
          gap,
          svg,
          recipe,
          tokens,
          content,
          below ? null : action,
        );
        if (!below) return main;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            main,
            Padding(
              padding: EdgeInsets.only(top: brutal ? 8 : 4),
              child: Align(alignment: Alignment.centerRight, child: action),
            ),
          ],
        );
      },
    );
  }

  Widget _rowOf(
    bool stacked,
    double gap,
    RaftSlotStyle? svg,
    RaftBannerRecipeStyle recipe,
    RaftTokenResolver tokens,
    Widget content,
    Widget? action,
  ) {
    return Row(
      crossAxisAlignment: stacked
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (glyph != null) ...[
          Padding(
            padding: EdgeInsets.only(top: stacked ? 2 : 0),
            child: RaftIcon(
              glyph!,
              size: svg?.width ?? 16,
              color:
                  svg?.textStyle(tokens).color ??
                  recipe.root.textStyle(tokens).color,
            ),
          ),
          SizedBox(width: gap),
        ],
        Expanded(child: content),
        if (action != null) ...[SizedBox(width: gap), action],
      ],
    );
  }
}
