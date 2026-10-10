import 'package:flutter/material.dart';

import 'dialog_card.dart';
import 'form_controls.dart';
import 'icons.dart';
import 'localization.dart';
import 'recipes/button_variants.g.dart';
import 'recipes/input_group.g.dart' show RaftInputGroupRecipeVariant;
import 'recipes/token_binding.dart';
import 'recipes/card.g.dart';
import 'theme.dart';

/// layout/SidebarSectionDialog.tsx: `Modal closeOnBackdrop` + `Card w-full
/// max-w-sm p-5`, a `text-base font-bold uppercase` title with a close
/// button, then the Name field (emoji picker addon + input) and the
/// Cancel / submit row. The product owns the emoji picker and persistence.
class RaftSidebarSectionDialog extends StatefulWidget {
  const RaftSidebarSectionDialog({
    super.key,
    required this.title,
    required this.submitLabel,
    required this.onSubmit,
    required this.onClose,
    this.initialName = '',
    this.initialEmoji = '',
    this.emojiButtonKey,
  });
  final String title, submitLabel, initialName, initialEmoji;
  final void Function(String name, String? emoji) onSubmit;
  final VoidCallback onClose;
  final Key? emojiButtonKey;

  @override
  State<RaftSidebarSectionDialog> createState() =>
      _RaftSidebarSectionDialogState();
}

class _RaftSidebarSectionDialogState extends State<RaftSidebarSectionDialog> {
  late final controller = TextEditingController(text: widget.initialName)
    ..addListener(() => setState(() {}));
  late String emoji = widget.initialEmoji;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void submit() {
    final name = controller.text.trim();
    if (name.isEmpty) return;
    final e = emoji.trim();
    widget.onSubmit(name, e.isEmpty ? null : e);
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final tokens = RaftRecipeTokens(t);
    final titleSlot = RaftCardRecipe.resolve(
      theme: raftRecipeThemeOf(t),
      tokens: tokens,
    ).title;
    final canSubmit = controller.text.trim().isNotEmpty;
    return RaftRecipeCard(
      maxWidth: 384, // max-w-sm
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      raftText(context, widget.title).toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: raftCssTextStyle(
                        family: titleSlot.fontFamily ?? t.headingFont,
                        step: RaftTextSteps.base,
                        weight: FontWeight.w700,
                        color: t.ink,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                RaftCloseButton(onPressed: widget.onClose),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              raftText(context, 'Name').toUpperCase(),
              style: raftCssTextStyle(
                family: t.headingFont,
                step: RaftTextSteps.xs,
                weight: FontWeight.w700,
                color: t.ink,
              ),
            ),
          ),
          RaftPrefixedInput(
            prefix: '',
            variant: RaftInputGroupRecipeVariant.default_,
            controller: controller,
            maxLength: 80,
            hintText: raftText(context, 'My Project'),
            semanticLabel: raftText(context, 'Name'),
            onSubmitted: (_) => submit(),
            leading: _EmojiButton(
              key: widget.emojiButtonKey,
              emoji: emoji,
              onPressed: null,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              RaftRecipeButton(
                label: raftText(context, 'Cancel'),
                variant: RaftButtonRecipeVariant.outline,
                size: RaftButtonRecipeSize.sm,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                textStep: RaftTextSteps.sm,
                onPressed: widget.onClose,
              ),
              const SizedBox(width: 8),
              RaftRecipeButton(
                label: raftText(context, widget.submitLabel),
                variant: RaftButtonRecipeVariant.accent,
                size: RaftButtonRecipeSize.sm,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                textStep: RaftTextSteps.sm,
                disabled: !canSubmit,
                onPressed: canSubmit ? submit : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// SidebarSectionEmojiPicker trigger: `Button ghost icon-md text-xl` showing
/// the chosen emoji or a `SmilePlus 18` glyph.
class _EmojiButton extends StatelessWidget {
  const _EmojiButton({super.key, required this.emoji, required this.onPressed});
  final String emoji;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => RaftRecipeButton(
    variant: RaftButtonRecipeVariant.ghost,
    size: RaftButtonRecipeSize.iconMd,
    glyph: emoji.isEmpty ? RaftGlyph.smilePlus : null,
    glyphSize: 18,
    child: emoji.isEmpty
        ? null
        : Text(emoji, style: const TextStyle(fontSize: 20, height: 28 / 20)),
    onPressed: onPressed ?? () {},
  );
}

/// Opens [RaftSidebarSectionDialog] over a [RaftModalBackdrop] that closes on
/// a backdrop press (`Modal closeOnBackdrop`). [cardKey] marks the card.
Future<void> showRaftSidebarSectionDialog(
  BuildContext context, {
  required String title,
  required String submitLabel,
  required void Function(String name, String? emoji) onSubmit,
  String initialName = '',
  String initialEmoji = '',
  Key? cardKey,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: false,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.transparent,
  transitionDuration: Duration.zero,
  pageBuilder: (dialogContext, _, _) {
    void close() => Navigator.of(dialogContext).pop();
    return Material(
      type: MaterialType.transparency,
      child: RaftModalBackdrop(
        onBackdrop: close,
        child: KeyedSubtree(
          key: cardKey,
          child: RaftSidebarSectionDialog(
            title: title,
            submitLabel: submitLabel,
            initialName: initialName,
            initialEmoji: initialEmoji,
            onClose: close,
            onSubmit: (name, emoji) {
              close();
              onSubmit(name, emoji);
            },
          ),
        ),
      ),
    );
  },
);
