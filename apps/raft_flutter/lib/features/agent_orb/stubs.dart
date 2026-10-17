import 'orb_tool.dart';

// Phase 1 seams. The navigation and briefing workstreams (cindy/orb-nav,
// cindy/orb-briefing) export the real lists from agent_orb/nav/ and
// agent_orb/briefing/. Cindy replaces these two stubs with those exports at
// merge, and deletes this file.

/// `navigate`, `describe_page`, `read_conversation` (agent_orb/nav).
List<OrbTool> orbNavigationTools() => const [];

/// `get_briefing` (agent_orb/briefing).
List<OrbTool> orbBriefingTools() => const [];
