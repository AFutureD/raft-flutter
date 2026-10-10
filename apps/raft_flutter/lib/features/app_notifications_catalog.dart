/// Pinned mounted App Notifications permission catalog.
const appNotificationGroups = [
  "server",
  "agent",
  "channel",
  "computer",
  "agent_reminder_write",
];
const appNotificationEventGroups = <String, List<String>>{
  "server.member_added": ["server"],
  "server.member_removed": ["server"],
  "server.member_role_changed": ["server"],
  "server.config_updated": ["server"],
  "server.public_channel_created": ["server", "channel"],
  "server.public_channel_archived": ["server", "channel"],
  "server.plan_changed": ["server"],
  "agent.status_changed": ["agent"],
  "agent.profile_updated": ["agent"],
  "agent.runtime_changed": ["agent"],
  "agent.model_changed": ["agent"],
  "channel.member_added": ["channel"],
  "channel.member_removed": ["channel"],
  "channel.config_updated": ["channel"],
  "channel.archived": ["channel"],
  "thread.created": ["channel"],
  "thread.resolved": ["channel"],
  "computer.online": ["computer"],
  "computer.offline": ["computer"],
  "computer.version_changed": ["computer"],
  "computer.agent_started": ["computer", "agent"],
  "computer.agent_stopped": ["computer", "agent"],
};

/// AppNotificationsControls.tsx GROUP_META labels (English catalog).
const appNotificationGroupLabels = <String, String>{
  "server": "Server",
  "agent": "Agent",
  "channel": "Channel",
  "computer": "Computer",
  "agent_reminder_write": "Agent reminders",
};

/// AppNotificationsControls.tsx EVENT_LABEL_ID (English catalog).
const appNotificationEventLabels = <String, String>{
  "server.member_added": "Member added",
  "server.member_removed": "Member removed",
  "server.member_role_changed": "Member role changed",
  "server.config_updated": "Server configuration updated",
  "server.public_channel_created": "Public channel created",
  "server.public_channel_archived": "Public channel archived",
  "server.plan_changed": "Plan status changed",
  "agent.status_changed": "Agent status changed",
  "agent.profile_updated": "Agent profile updated",
  "agent.runtime_changed": "Agent runtime changed",
  "agent.model_changed": "Agent model changed",
  "channel.member_added": "Public channel member added",
  "channel.member_removed": "Public channel member removed",
  "channel.config_updated": "Public channel configuration updated",
  "channel.archived": "Public channel archived",
  "thread.created": "Public thread created",
  "thread.resolved": "Public thread resolved",
  "computer.online": "Computer online",
  "computer.offline": "Computer offline",
  "computer.version_changed": "Computer version changed",
  "computer.agent_started": "Agent process started",
  "computer.agent_stopped": "Agent process stopped",
};
