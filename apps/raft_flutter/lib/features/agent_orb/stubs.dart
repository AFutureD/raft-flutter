import 'orb_tool.dart';

export 'briefing/orb_briefing_tools.dart' show orbBriefingTools;

// The navigation workstream (cindy/orb-nav) exports the real list from
// agent_orb/nav/; this stub goes when it is merged.

/// `navigate`, `describe_page`, `read_conversation` (agent_orb/nav).
List<OrbTool> orbNavigationTools() => const [];
