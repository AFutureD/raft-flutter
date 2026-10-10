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

/// Sidebar `AgentActivityDot`: the agent row's own `activity` (falling back to
/// its `status`), shown on every agent row, offline included.
RaftAvatarPresence agentRowPresence(Map<String, dynamic> row) =>
    RaftAvatarPresence(
      activity: switch (row['activity']) {
        'working' => RaftAvatarActivity.working,
        'thinking' => RaftAvatarActivity.thinking,
        'error' => RaftAvatarActivity.error,
        'offline' => RaftAvatarActivity.offline,
        'online' => RaftAvatarActivity.online,
        _ =>
          row['status'] == 'active'
              ? RaftAvatarActivity.online
              : RaftAvatarActivity.offline,
      },
    );
