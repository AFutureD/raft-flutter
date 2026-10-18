// apps/raft_flutter/lib/features/agent_orb/orb_tool.dart  (written by SHELL; NAV/BRIEFING copy this exact file into their branch unchanged so they compile, Cindy dedups at merge)
import 'package:flutter/widgets.dart';

import '../../data/workspace_controller.dart';

/// What a tool handler gets: the live workspace, a context under the app's
/// Navigator (for routing and for opening sheets), and the orb's notifier for
/// "Agent is operating" (set true while a tool changes the screen).
class OrbToolContext {
  OrbToolContext({
    required this.workspace,
    required this.navigatorContext,
    required this.operating,
    this.agentLayer = false,
  });
  final WorkspaceController workspace;
  final BuildContext navigatorContext;
  final ValueNotifier<bool> operating;

  /// The model is the app's text agent: the app owns the order and the empty
  /// line, and the tool results say so.
  final bool agentLayer;
}

/// A tool the model may call: a Gemini FunctionDeclaration (same shape as
/// agent_mode/agent_tools.dart) and its handler. The handler returns a JSON-able
/// map; it must not throw for ordinary failures — return {'error': '...'}.
class OrbTool {
  const OrbTool({required this.declaration, required this.handler});
  final Map<String, Object?> declaration;
  final Future<Map<String, Object?>> Function(
    Map<String, Object?> args,
    OrbToolContext ctx,
  )
  handler;
  String get name => declaration['name']! as String;
}
