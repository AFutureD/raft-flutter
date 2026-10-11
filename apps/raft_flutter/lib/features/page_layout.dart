import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/recipes.dart' as recipes;

/// The product panel header shared by the source's individual page columns.
/// Platform safe-area insets are supplied by the host, outside this rectangle.
double raftPageHeaderHeight(BuildContext context) =>
    RaftLayoutMetrics.shellHeaderHeight(
      RaftTokens.of(context),
      MediaQuery.sizeOf(context).height,
    );

class RaftPageHeader extends StatelessWidget implements PreferredSizeWidget {
  const RaftPageHeader({
    super.key,
    required this.title,
    required this.height,
    this.subtitle,
    this.icon,
    this.leading,
    this.actions = const [],
    this.mobile = false,
    this.variant = RaftPanelHeaderVariant.canonical,
    this.leftInset,
    this.bottomRule = false,
  });

  /// Elegant desktop only: the host's own left padding (ActivityInboxPanel
  /// `pl-3`) and the `border-b` rule it adds under the header.
  final double? leftInset;
  final bool bottomRule;
  final String title;
  final String? subtitle;
  final Widget? icon, leading;
  final List<Widget> actions;
  final double height;
  final bool mobile;
  final RaftPanelHeaderVariant variant;

  @override
  Size get preferredSize =>
      Size.fromHeight(mobile ? RaftMobilePageHeader.height : height);

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final recipe = RaftPanelHeaderRecipe(
      t,
      viewportHeight: MediaQuery.sizeOf(context).height,
      mobile: mobile,
      variant: variant,
    );
    if (mobile) {
      return RaftMobilePageHeader(
        leading: leading,
        background: recipe.background,
        border: recipe.border,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: RaftTypography.heading(t, size: 16, line: 20),
            ),
            if (subtitle?.isNotEmpty == true)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: RaftTypography.body(
                  t,
                  size: 12,
                  line: 16,
                  color: t.muted,
                ),
              ),
          ],
        ),
        actions: actions,
      );
    }
    final canonical = variant == RaftPanelHeaderVariant.canonical;
    if (canonical && !t.brutal) {
      // Elegant desktop PanelHeader: the 36px `fill-muted` icon tile and the
      // title with its meta inline (the same bar the Agent / Human panels use).
      return RaftPanelHeaderBar(
        key: const Key('page-header-surface'),
        title: title,
        subtitle: subtitle,
        leftPadding: leftInset,
        bottomRule: bottomRule,
        iconSlot: icon == null ? null : RaftPanelHeaderMutedTile(icon: icon!),
        actions: actions,
      );
    }
    final source = recipes.RaftPanelHeaderRecipe.resolve(
      theme: t.recipeTheme,
      states: recipes.RaftRecipeStates(
        {if (t.dark) recipes.RaftRecipeStates.dark},
        MediaQuery.sizeOf(context).width,
        MediaQuery.sizeOf(context).height,
      ),
      tokens: t.recipeTokens,
    );
    final titleStyle = canonical
        ? source.title.text(t.recipeTokens, base: RaftTypography.body(t))
        : recipe.title;
    final subtitleStyle = canonical && !t.brutal
        ? source.meta.text(t.recipeTokens, base: RaftTypography.body(t))
        : recipe.subtitle;
    final gap = canonical && !t.brutal
        ? RaftResourceMetrics.elegantHeaderGap
        : RaftLayoutMetrics.panelGap;
    return Container(
      key: const Key('page-header-surface'),
      height: height,
      padding: canonical && !t.brutal && mobile
          ? RaftResourceMetrics.elegantMobileHeaderInset
          : EdgeInsets.symmetric(horizontal: RaftLayoutMetrics.panelInset),
      decoration: BoxDecoration(
        color: recipe.background,
        border: Border(
          bottom: canonical && !t.brutal && mobile
              ? BorderSide(color: t.line)
              : recipe.border,
        ),
      ),
      child: Row(
        children: [
          if (leading != null) ...[leading!, SizedBox(width: gap)],
          if (!mobile && icon != null) ...[
            Container(
              width: RaftLayoutMetrics.panelIcon,
              height: RaftLayoutMetrics.panelIcon,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: recipe.iconBackground,
                border: Border.all(color: t.line, width: t.border),
                borderRadius: recipe.iconRadius,
              ),
              child: IconTheme.merge(
                data: IconThemeData(size: 18, color: t.ink),
                child: icon!,
              ),
            ),
            SizedBox(width: gap),
          ],
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!canonical)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                if (canonical)
                  RaftCssText(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                if (canonical &&
                    !t.brutal &&
                    subtitle != null &&
                    subtitle!.isNotEmpty)
                  const SizedBox(
                    height: RaftResourceMetrics.elegantHeaderMetaGap,
                  ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  canonical
                      ? RaftCssText(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: subtitleStyle,
                        )
                      : Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: subtitleStyle,
                        ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Page body limits from the source's settings forms, independent of viewport.
class RaftSettingsSection extends StatelessWidget {
  const RaftSettingsSection({
    super.key,
    required this.title,
    required this.child,
    this.description,
  });
  final String title;
  final String? description;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: RaftTypography.heading(t, size: 14, line: 21)),
        if (description != null) ...[
          const SizedBox(height: 4),
          Text(
            description!,
            style: RaftTypography.body(t, size: 12, line: 18, color: t.muted),
          ),
        ],
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

/// Standalone routes use the same mobile geometry as workspace panels.
PreferredSizeWidget raftPageAppBar(
  BuildContext context, {
  required Widget title,
  List<Widget> actions = const [],
}) {
  if (MediaQuery.sizeOf(context).width >= RaftLayoutMetrics.desktopBreakpoint) {
    // ds-allow: Native Scaffold AppBar preserves desktop sizing and automatic route Back.
    return AppBar(title: title, actions: actions);
  }
  final navigator = Navigator.of(context);
  return PreferredSize(
    preferredSize: const Size.fromHeight(RaftMobilePageHeader.height),
    // ds-allow: Native Scaffold appBar ink host and safe-area background; raft_ui owns the header content.
    child: Material(
      color: RaftTokens.of(context).panel,
      child: SafeArea(
        bottom: false,
        child: RaftMobilePageHeader(
          title: DefaultTextStyle(
            style: RaftTypography.heading(
              RaftTokens.of(context),
              size: 16,
              line: 20,
            ),
            child: title,
          ),
          onBack: navigator.canPop() ? () => navigator.maybePop() : null,
          actions: actions,
        ),
      ),
    ),
  );
}
