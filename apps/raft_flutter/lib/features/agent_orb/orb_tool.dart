import 'package:flutter/widgets.dart';
import '../../data/workspace_controller.dart';

/// What a tool handler gets: the live workspace, a context under the app's
/// Navigator (for routing and for opening sheets), and the orb's notifier for
/// "Agent is operating" (set true while a tool changes the screen).
class OrbToolContext {
  const OrbToolContext({required this.workspace, required this.navigatorContext, required this.operating});
  final WorkspaceController workspace;
  final BuildContext navigatorContext;
  final ValueNotifier<bool> operating;
}

/// A tool the model may call: a Gemini FunctionDeclaration (same shape as
/// agent_mode/agent_tools.dart) and its handler. The handler returns a JSON-able
/// map; it must not throw for ordinary failures — return {'error': '...'}.
class OrbTool {
  const OrbTool({required this.declaration, required this.handler});
  final Map<String, Object?> declaration;
  final Future<Map<String, Object?>> Function(Map<String, Object?> args, OrbToolContext ctx) handler;
  String get name => declaration['name']! as String;
}
