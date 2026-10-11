import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/mobile_tabbar_preferences.dart';
import '../data/workspace_controller.dart';

/// Settings > Bottom bar (mobile): the device's bottom-bar tabs. Changes are
/// written to [store] at once, so the workspace's real bar follows live.
/// Tabs this account may not open are not listed and do not count toward the
/// limit; they keep their place if the account regains access.
class MobileTabbarSettingsPage extends StatelessWidget {
  const MobileTabbarSettingsPage({
    super.key,
    required this.controller,
    required this.store,
  });
  final WorkspaceController controller;
  final MobileTabbarStore store;

  static const tabs = [
    RaftMobileTabOption(
      id: MobileTabs.home,
      label: 'Home',
      glyph: RaftGlyph.home,
    ),
    RaftMobileTabOption(
      id: MobileTabs.tasks,
      label: 'Tasks',
      glyph: RaftGlyph.checkSquare,
    ),
    RaftMobileTabOption(
      id: MobileTabs.members,
      label: 'Members',
      glyph: RaftGlyph.users,
    ),
    RaftMobileTabOption(
      id: MobileTabs.computers,
      label: 'Computers',
      glyph: RaftGlyph.monitor,
    ),
    RaftMobileTabOption(
      id: MobileTabs.activity,
      label: 'Activity',
      glyph: RaftGlyph.activity,
    ),
  ];
  static const settingsTab = RaftMobileTabOption(
    id: MobileTabs.settings,
    label: 'Settings',
    glyph: RaftGlyph.settings,
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, controller]),
    builder: (context, _) {
      final guest = controller.server?.string('role') == 'guest';
      final permitted = {
        for (final id in MobileTabs.configurable)
          if (mobileTabPermitted(id, guest: guest, can: controller.can)) id,
      };
      final stored = store.settings;
      return RaftMobileTabbarConfigView(
        tabs: tabs,
        settingsTab: settingsTab,
        config: RaftMobileTabbarConfig(
          order: [
            for (final id in stored.order)
              if (permitted.contains(id)) id,
          ],
          enabled: stored.enabled.intersection(permitted),
          maxTabs: MobileTabs.maxTabs,
        ),
        onChanged: (next) => store.update(
          stored.merged(
            MobileTabbarSettings(order: next.order, enabled: next.enabled),
            permitted,
          ),
        ),
        onReset: stored.isDefault ? null : store.reset,
      );
    },
  );
}
