// apps/raft_flutter/lib/features/agent_orb/orb_tool.dart  (written by SHELL; NAV/BRIEFING copy this exact file into their branch unchanged so they compile, Cindy dedups at merge)
import 'package:flutter/widgets.dart';

import '../../data/workspace_controller.dart';
import 'briefing/orb_briefing_models.dart';

/// What a tool handler gets: the live workspace, a context under the app's
/// Navigator (for routing and for opening sheets), and the orb's notifier for
/// "Agent is operating" (set true while a tool changes the screen).
class OrbToolContext {
  OrbToolContext({
    required this.workspace,
    required this.navigatorContext,
    required this.operating,
  });
  final WorkspaceController workspace;
  final BuildContext navigatorContext;
  final ValueNotifier<bool> operating;

  /// The briefing of the place a tool arrived at (set by `navigate`), for
  /// the orb to lay out as cards when the model asks it to show them.
  OrbBriefing? arrived;
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
