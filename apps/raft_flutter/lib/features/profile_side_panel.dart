import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/raft_location.dart';
import '../data/workspace_controller.dart';
import 'agent_detail_view.dart';
import 'external_identity.dart';
import 'fleet_views.dart';
import 'member_profile_view.dart';

/// Web `ConnectedProfilePanel`: the profile slot of the URL (`profile=`) as a
/// side panel (desktop column / phone page) for an agent, a member or an
/// external message author. Closing returns to the surface underneath.
class ProfileSidePanel extends StatelessWidget {
  const ProfileSidePanel({
    super.key,
    required this.controller,
    required this.profile,
    required this.agentTab,
    required this.onClose,
    this.onBack,
    this.onMessage,
  });
  final WorkspaceController controller;
  final RaftProfileLocation profile;

  /// `?agentTab=` deep link (the hover card's "Recent activity").
  final String? agentTab;
  final VoidCallback onClose;

  /// Phone page stack: back leads the header (the panel is a full page).
  final VoidCallback? onBack;
  final Future<void> Function(RaftProfileKind kind, String id)? onMessage;

  @override
  Widget build(BuildContext context) {
    final w = controller;
    final key = ValueKey('profile-${profile.kind.name}-${profile.id}');
    final Widget body = switch (profile.kind) {
      RaftProfileKind.agent => FleetDetail(
        key: key,
        controller: w,
        computers: false,
        initial: w.entityDirectory.agent(profile.id) ?? {'id': profile.id},
        initialTab: AgentDetailTab.values.firstWhere(
          (tab) => tab.name == agentTab,
          orElse: () => AgentDetailTab.profile,
        ),
        onClose: onBack ?? onClose,
        closeAction: true,
        // Nested creator / created-agent navigation stays in this panel.
        onOpenAgent: (id) => w.openProfile(RaftProfileKind.agent, id),
      ),
      RaftProfileKind.human => MemberProfileView(
        key: key,
        controller: w,
        userId: profile.id,
        onClose: onClose,
        onBack: onBack,
        onMessage: onMessage == null
            ? null
            : () => onMessage!(RaftProfileKind.human, profile.id),
      ),
      RaftProfileKind.external => ExternalProfileSource(
        key: key,
        controller: w,
        messageId: profile.id,
        channelId: profile.channelId ?? '',
        builder: (author) => ExternalIdentityDetailPanel(
          controller: w,
          profile: author,
          onClose: onClose,
          onBack: onBack,
        ),
        fallback: (failed) => SourceProfileLoadingPanel(
          onBack: onBack,
          onClose: onClose,
          error: failed ? 'Profile unavailable' : null,
        ),
      ),
    };
    return KeyedSubtree(
      key: const Key('profile-panel'),
      child: RaftProfilePanelSurface(child: body),
    );
  }
}
