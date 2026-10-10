import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_primitives.dart';
import 'icons.dart';
import 'mobile_page_header.dart';
import 'theme.dart';

/// Source Lightbox viewport shell. The caller owns route scope and private media.
/// SafeArea keeps interactive controls above native system bars and gestures.
class RaftAttachmentLightbox extends StatelessWidget {
  const RaftAttachmentLightbox({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.actions = const [],
    this.footer,
    this.titleBold = false,
    this.closeLabel = 'Close preview',
    this.onResetZoom,
    this.page = false,
  });
  final String title, closeLabel;
  final Widget child;
  final VoidCallback onClose;
  final List<Widget> actions;
  final Widget? footer;
  final bool titleBold;
  final bool page;

  /// Source ImageLightbox: the 0 key resets zoom and pan.
  final VoidCallback? onResetZoom;
  @override
  Widget build(BuildContext context) {
    final recipe = RaftLightboxRecipe(RaftTokens.of(context));
    final content = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): onClose,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): onClose,
        if (onResetZoom != null) ...{
          const SingleActivator(LogicalKeyboardKey.digit0): onResetZoom!,
          const SingleActivator(LogicalKeyboardKey.numpad0): onResetZoom!,
        },
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          child: Column(
            children: [
              if (page)
                RaftMobilePageHeader(
                  background: recipe.surface,
                  title: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: recipe.title.copyWith(
                      fontWeight: titleBold ? FontWeight.w700 : FontWeight.w400,
                    ),
                  ),
                  onBack: onClose,
                  backLabel: closeLabel,
                  actions: actions,
                )
              else
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: recipe.surface,
                    border: Border(bottom: recipe.navigationBorder),
                  ),
                  child: SizedBox(
                    height: recipe.toolbarHeight,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: recipe.headerInset.left,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: recipe.title.copyWith(
                                fontWeight: titleBold
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                          for (final action in actions) ...[
                            SizedBox(width: recipe.actionsGap),
                            action,
                          ],
                          SizedBox(width: recipe.actionsGap),
                          RaftIconButton(
                            glyph: RaftGlyph.x,
                            tooltip: closeLabel,
                            visualSize: 32,
                            minimumTargetSize: 48,
                            variant: RaftControlVariant.ghost,
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(child: child),
              if (footer != null)
                ColoredBox(
                  color: recipe.surface,
                  child: SizedBox(width: double.infinity, child: footer!),
                ),
            ],
          ),
        ),
      ),
    );
    return page
        ? Material(color: recipe.backdrop, child: content)
        : Dialog.fullscreen(backgroundColor: recipe.backdrop, child: content);
  }
}
