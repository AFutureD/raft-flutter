import 'action_capabilities.dart';
import 'approval_capabilities.dart';
import 'agent_capability.dart';
import 'audit_capabilities.dart';
import 'task_action_capabilities.dart';
import 'agent_capabilities.dart';
import 'agent_ops_capabilities.dart';
import 'channel_action_capabilities.dart';
import 'channel_capabilities.dart';
import 'digest_capabilities.dart';
import 'fleet_capabilities.dart';
import 'message_action_capabilities.dart';
import 'message_capabilities.dart';
import 'open_page_capabilities.dart';
import 'snooze_capabilities.dart';
import 'task_capabilities.dart';
import 'task_more_capabilities.dart';

/// Every capability the app registers: the reads, the audit log and the
/// high-frequency operations. Adding a domain or an operation is one entry
/// here; the generic tools and the prompt do not change (the one-step action
/// tools are listed in agent_direct_tools.dart).
final agentStandardCapabilities = AgentCapabilityRegistry([
  ...channelCapabilities,
  ...messageCapabilities,
  ...taskCapabilities,
  ...agentCapabilities,
  ...fleetCapabilities,
  ...auditCapabilities,
  ...actionCapabilities,
  ...taskActionCapabilities,
  ...taskMoreCapabilities,
  ...taskFromMessageCapabilities,
  ...digestCapabilities,
  ...agentOpsCapabilities,
  ...channelActionCapabilities,
  ...messageActionCapabilities,
  ...approvalCapabilities,
  ...snoozeCapabilities,
  ...openPageCapabilities,
]);
