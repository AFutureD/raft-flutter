import '../agent_catalog.dart';
import '../agent_tools.dart';
import '../capabilities/agent_capability.dart';
import '../capabilities/agent_capability_standard.dart';
import '../capabilities/agent_capability_tools.dart';
import '../capabilities/agent_direct_tools.dart';
import '../capabilities/agent_read_tools.dart';

/// Every function the voice model may call in agent mode, as declarations:
/// the screen tools, the tools that compose a screen, the direct read tools
/// (one call, the app draws the answer), the direct action tools, and `find`,
/// `query`, `act`, `confirm`, `undo`, `resolve` for the long tail.
///
/// [AgentRuntime] adds the turn parameters (`additive`) to the ones that
/// start a request.
List<Map<String, Object?>> agentModeToolDeclarations([
  AgentCapabilityRegistry? registry,
]) => [
  ...agentToolDeclarations,
  ...agentReadToolDeclarations,
  ...directActionDeclarations(registry ?? agentStandardCapabilities),
  ...capabilityToolDeclarations,
  ...groundedToolDeclarations(agentStandardCatalog),
];
