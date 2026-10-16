import 'agent_capability.dart';
import 'agent_capabilities.dart';
import 'channel_capabilities.dart';
import 'fleet_capabilities.dart';
import 'message_capabilities.dart';
import 'task_capabilities.dart';

/// Every capability the app registers. Phase 1 is read-only: adding a domain
/// or an operation is one entry here, with no change to the tools or the
/// prompt.
final agentStandardCapabilities = AgentCapabilityRegistry([
  ...channelCapabilities,
  ...messageCapabilities,
  ...taskCapabilities,
  ...agentCapabilities,
  ...fleetCapabilities,
]);
