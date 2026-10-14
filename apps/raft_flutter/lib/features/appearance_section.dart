import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/personal_presentation.dart';
import '../data/rail_side_preference.dart';
import '../platform/app_icon.dart';
import 'app_icon_settings_section.dart';

/// Component tokens traced to SettingsPanel.tsx AppearanceSection cards p-4,
/// border-line-muted/bg-layer-panel/shadow-raft-sm and14/20,12/16 hierarchy.
class RaftAppearanceSectionRecipe {
  const RaftAppearanceSectionRecipe(this.t);
  final RaftTokens t;
  static const inset = EdgeInsets.all(16);
  static const gap = 16.0;
  static const gapAbove = EdgeInsets.only(top: gap);
  BoxDecoration get card => RaftSettingsCard.decoration(t);
  TextStyle get heading =>
      RaftTypography.body(t, size: 14, line: 20, weight: FontWeight.w700);
  TextStyle get description =>
      RaftTypography.body(t, size: 12, line: 16, color: t.muted);
  TextStyle get annotation => RaftTypography.body(
    t,
    size: 11,
    line: 16,
    color: t.muted,
    weight: FontWeight.w700,
  );
}

class RaftAppearanceSection extends StatelessWidget {
  const RaftAppearanceSection({
    super.key,
    required this.appearance,
    required this.onAppearance,
    required this.presentation,
    this.railSide,
  });
  final RaftAppearance appearance;
  final ValueChanged<RaftAppearance> onAppearance;
  final PersonalPresentationStore presentation;

  /// The device's rail side choice. Offered only where the phone layout can
  /// show the rail (a wide or short window); null hides the row.
  final RailSideStore? railSide;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: presentation,
    builder: (context, _) {
      final r = RaftAppearanceSectionRecipe(RaftTokens.of(context)),
          value = presentation.value,
          captured = presentation.key;
      Widget card(List<Widget> children, {double spacing = 0}) => Container(
        padding: RaftAppearanceSectionRecipe.inset,
        decoration: r.card,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: spacing,
          children: children,
        ),
      );
      Widget title(String heading, String description) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(raftText(context, heading), style: r.heading),
          const SizedBox(height: 4),
          Text(raftText(context, description), style: r.description),
        ],
      );
      Widget toggle(
        String key,
        String heading,
        String description,
        bool current,
        void Function(bool) changed,
      ) => card([
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title(heading, description),
                  const SizedBox(height: 8),
                  Text(
                    raftText(context, 'Saved on this device.'),
                    style: r.annotation,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            RaftSwitch(
              key: ValueKey(key),
              value: current,
              semanticLabel: heading,
              semanticDescription: description,
              onChanged: captured == null ? null : changed,
            ),
          ],
        ),
      ]);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          card([
            title(
              'Theme',
              'Choose the visual style for this browser. Your choice is saved on this device.',
            ),
            const SizedBox(height: 12),
            RaftAppearancePicker(
              appearance: appearance,
              onChanged: onAppearance,
            ),
          ]),
          if (NativeAppIcon.instance.mobile) ...[
            const SizedBox(height: RaftAppearanceSectionRecipe.gap),
            const RaftSettingsSectionHeader(
              label: 'App icon',
              glyph: RaftGlyph.smartphone,
            ),
            const AppIconSettingsSection(),
          ],
          const SizedBox(height: RaftAppearanceSectionRecipe.gap),
          const RaftSettingsSectionHeader(
            label: 'Appearance',
            glyph: RaftGlyph.type,
          ),
          card([
            title(
              'Message font size',
              'Adjust rendered message text on this device, including headings, code blocks, inline code, and reference chips. Buttons, labels, and sidebar keep their fixed UI sizes.',
            ),
            const SizedBox(height: 16),
            RaftSegmentedControl<String>(
              style: RaftSegmentedStyle.tabs,
              value: value.font,
              label: 'Message font size',
              items: [
                RaftSegmentedOption(
                  value: 'sm',
                  label: raftText(context, 'Small'),
                ),
                RaftSegmentedOption(
                  value: 'md',
                  label: raftText(context, 'Medium'),
                ),
                RaftSegmentedOption(
                  value: 'lg',
                  label: raftText(context, 'Large'),
                ),
              ],
              onChanged: captured == null
                  ? null
                  : (font) => presentation.update(captured, font: font),
            ),
            const SizedBox(height: 16),
            Text(
              raftText(context, 'Saved on this device.'),
              style: r.annotation,
            ),
            const SizedBox(height: 16),
            Text(
              raftText(context, 'Preview').toUpperCase(),
              style: r.annotation,
            ),
            const SizedBox(height: 8),
            IgnorePointer(
              child: Semantics(
                label: raftText(context, 'Message font size preview'),
                child: RaftMessageTile(
                  author: 'Cindy',
                  content:
                      '@Joy #proj-uiux love the new design — doing a `git pull` now to try it locally.',
                  timestamp: '',
                  badge: 'Agent',
                  bodyFontSize: value.fontSize,
                  body: RaftMessageBody(
                    content:
                        '@Joy #proj-uiux love the new design — doing a `git pull` now to try it locally.',
                    fontSize: value.fontSize,
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: RaftAppearanceSectionRecipe.gap),
          toggle(
            'appearance-live-activity',
            'Live agent activity',
            'Show the latest agent status at the bottom of the sidebar and above the mobile tab bar.',
            value.liveActivity,
            (show) => presentation.update(captured, liveActivity: show),
          ),
          const SizedBox(height: RaftAppearanceSectionRecipe.gap),
          toggle(
            'appearance-agent-model',
            'Show agent model',
            'Show each agent’s model next to its name in chat. On by default in the desktop app.',
            value.modelName,
            (show) => presentation.update(captured, modelName: show),
          ),
          const SizedBox(height: RaftAppearanceSectionRecipe.gap),
          toggle(
            'appearance-hide-empty',
            'Hide empty sidebar sections',
            'Hide sidebar sections while they have nothing in them (empty Pinned, Joint Channels, Direct Messages). On by default in the desktop app.',
            value.hideEmptySections,
            (hide) => presentation.update(captured, hideEmptySections: hide),
          ),
          if (railSide != null && railChoiceAvailable(context))
            Padding(
              padding: RaftAppearanceSectionRecipe.gapAbove,
              child: ListenableBuilder(
                listenable: railSide!,
                builder: (context, _) {
                  final rtl = Directionality.of(context) == TextDirection.rtl;
                  // The options name the side the user sees, in any direction.
                  String visual(bool right) => right
                      ? raftTextZh(context, 'Right', '右侧')
                      : raftTextZh(context, 'Left', '左侧');
                  return card([
                    title(
                      'Navigation rail',
                      'Which side the navigation rail sits on when the window is wide or short, such as in landscape or on an unfolded screen.',
                    ),
                    RaftSegmentedControl<RaftRailSide>(
                      key: const ValueKey('appearance-rail-side'),
                      style: RaftSegmentedStyle.tabs,
                      value: railSide!.side,
                      label: raftText(context, 'Navigation rail'),
                      items: [
                        RaftSegmentedOption(
                          value: RaftRailSide.start,
                          label: visual(rtl),
                        ),
                        RaftSegmentedOption(
                          value: RaftRailSide.end,
                          label: visual(!rtl),
                        ),
                      ],
                      onChanged: railSide!.update,
                    ),
                    Text(
                      raftText(context, 'Saved on this device.'),
                      style: r.annotation,
                    ),
                  ], spacing: RaftAppearanceSectionRecipe.gap);
                },
              ),
            ),
        ],
      );
    },
  );
}

/// Whether this window can show the phone rail on either side. The window
/// decides (size and shape), so a tall phone in portrait, and the desktop
/// layout, do not get a setting that has no effect there.
bool railChoiceAvailable(BuildContext context) =>
    RaftAdaptiveWorkspace.phoneRailOf(context, side: RaftRailSide.start) ||
    RaftAdaptiveWorkspace.phoneRailOf(context, side: RaftRailSide.end);
