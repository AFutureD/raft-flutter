import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'icons.dart';
import 'indicators.dart';
import 'localization.dart';
import 'recipe_surface.dart';
import 'components.dart';
import 'settings_layout.dart';
import 'theme.dart';
import '../recipes.dart';

/// SettingsPanel.tsx DesktopNativeNotificationsCard mounted composition: a
/// SectionHeader (Bell) over a card holding the title, description and status
/// pill, the system hint, an optional warning Banner or success message and
/// one action button. The caller owns the copy, the permission facts and the
/// server mute form (phones only; Web's desktop card has none).
class RaftNotificationSettingsCard extends StatelessWidget {
  const RaftNotificationSettingsCard({
    super.key,
    required this.title,
    required this.description,
    required this.status,
    required this.actionLabel,
    required this.muted,
    this.sectionLabel = 'Notifications',
    this.hint,
    this.error,
    this.message,
    this.muteDescription,
    this.actionTone = RaftButtonRecipeVariant.success,
    this.saveLabel = 'Save',
    this.onAction,
    this.onRetry,
    this.onMutedChanged,
    this.onSave,
  });
  final String sectionLabel, title, description, status, actionLabel, saveLabel;
  final String? hint, error, message, muteDescription;
  final bool muted;
  final RaftButtonRecipeVariant actionTone;
  final VoidCallback? onAction, onRetry, onSave;
  final ValueChanged<bool>? onMutedChanged;

  /// `inline-flex shrink-0 border border-line-strong bg-primary-soft px-2 py-1
  /// text-[10px] font-bold uppercase text-primary-strong theme-brutal:border-2
  /// theme-brutal:border-black theme-brutal:bg-soft-signal theme-brutal:text-black`.
  static Widget statusPill(BuildContext context, String label) {
    final t = RaftTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: t.colors[t.brutal ? 'color-soft-signal' : 'primary-soft'],
        border: Border.all(
          color: t.brutal ? Colors.black : t.colors['line-strong']!,
          width: t.brutal ? 2 : 1,
        ),
      ),
      child: Text(
        raftText(context, label).toUpperCase(),
        maxLines: 1,
        softWrap: false,
        style: RaftTypography.body(
          t,
          size: 10,
          line: 15,
          weight: FontWeight.w700,
          color: t.brutal ? Colors.black : t.colors['primary-strong'],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final inherited = DefaultTextStyle.of(context).style;
    final titleStyle = inherited.copyWith(
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w700,
      color: RaftSettingsText(t).strong,
    );
    final hintStyle = inherited.copyWith(
      fontSize: 12,
      height: 16 / 12,
      color: RaftSettingsText(t).muted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftSettingsSectionHeader(label: sectionLabel, glyph: RaftGlyph.bell),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: RaftSettingsCard.decoration(t)
              .copyWith(color: t.brutal ? Colors.white : t.card),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(raftText(context, title), style: titleStyle),
                        const SizedBox(height: 2),
                        Text(raftText(context, description), style: hintStyle),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  statusPill(context, status),
                ],
              ),
              if (hint != null) ...[
                const SizedBox(height: 12),
                Text(raftText(context, hint!), style: hintStyle),
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  child: RaftRecipeBox(
                    style: RaftBannerRecipe.resolve(
                      theme: t.recipeTheme,
                      status: RaftBannerRecipeStatus.warning,
                      size: RaftBannerRecipeSize.sm,
                      states: t.recipeStates(),
                      tokens: t.recipeTokens,
                    ).root,
                    tokens: t.recipeTokens,
                    child: Text(
                      raftText(context, error!),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                if (onRetry != null) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: RaftButton(
                      label: 'Retry',
                      tone: RaftButtonRecipeVariant.outline,
                      size: RaftButtonRecipeSize.sm,
                      onPressed: onRetry,
                    ),
                  ),
                ],
              ],
              if (message != null) ...[
                const SizedBox(height: 12),
                Semantics(
                  liveRegion: true,
                  // `border border-line-muted bg-success-soft p-2 text-xs
                  // font-bold text-success-strong theme-brutal:border-2
                  // theme-brutal:border-black theme-brutal:bg-brutal-lime/30
                  // theme-brutal:text-black`.
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: t.brutal
                          ? t.colors['color-brutal-lime']!.withValues(alpha: .3)
                          : t.colors['success-soft'],
                      border: Border.all(
                        color: t.brutal
                            ? Colors.black
                            : t.colors['line-muted']!,
                        width: t.brutal ? 2 : 1,
                      ),
                    ),
                    child: Text(
                      message!,
                      style: hintStyle.copyWith(
                        fontWeight: FontWeight.w700,
                        color: t.brutal
                            ? Colors.black
                            : t.colors['success-strong'],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: RaftButton(
                  key: const ValueKey('notification-settings-action'),
                  label: actionLabel,
                  tone: actionTone,
                  size: RaftButtonRecipeSize.sm,
                  onPressed: onAction,
                ),
              ),
              if (muteDescription != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.only(top: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: t.brutal
                            ? Colors.black.withValues(alpha: .2)
                            : t.colors['line-muted']!,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        excludeFromSemantics: true,
                        onTap: onMutedChanged == null
                            ? null
                            : () => onMutedChanged!(!muted),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: RaftCheckbox(
                                value: muted,
                                size: RaftCheckboxRecipeSize.md,
                                semanticLabel: raftText(
                                  context,
                                  'Mute this server',
                                ),
                                onChanged: onMutedChanged,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    raftText(context, 'Mute this server'),
                                    style: titleStyle,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(muteDescription!, style: hintStyle),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: RaftButton(
                          key: const ValueKey('notification-settings-save'),
                          label: saveLabel,
                          tone: RaftButtonRecipeVariant.accent,
                          size: RaftButtonRecipeSize.sm,
                          onPressed: onSave,
                        ),
                      ),
                    ],
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
