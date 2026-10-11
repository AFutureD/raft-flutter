import 'package:raft_ui/raft_ui.dart';

import 'agent_metadata_projection.dart';

/// Shared mounted avatar mapping; the caller owns current display authority.
RaftAvatarPresence? agentAvatarPresence(AgentAmbientDisplay? display) {
  if (display == null || !display.showPresence) return null;
  return RaftAvatarPresence(
    activity: switch (display.activity) {
      'working' => RaftAvatarActivity.working,
      'thinking' => RaftAvatarActivity.thinking,
      'error' => RaftAvatarActivity.error,
      'offline' => RaftAvatarActivity.offline,
      _ => RaftAvatarActivity.online,
    },
    online: display.online,
    external: display.external,
    label: display.detail.isEmpty ? null : display.detail,
  );
}

/// Presence of a directory row: the live `activity` (agent:activity event) or
/// the row's own `activity`, else its `status` (`agentStatusFallbackActivity`).
RaftAvatarPresence agentRowPresence(Map<String, dynamic> json, {String? live}) {
  final activity = live ?? json['activity'];
  return RaftAvatarPresence(
    activity: switch (activity) {
      'online' => RaftAvatarActivity.online,
      'thinking' => RaftAvatarActivity.thinking,
      'working' => RaftAvatarActivity.working,
      'error' => RaftAvatarActivity.error,
      'offline' => RaftAvatarActivity.offline,
      _ =>
        json['status'] == 'active'
            ? RaftAvatarActivity.online
            : RaftAvatarActivity.offline,
    },
  );
}
