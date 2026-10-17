import 'package:raft_agent_ui/raft_agent_ui.dart' show AgentSpeaker;

import '../agent_mode/agent_summary.dart';

/// Tools that only move or read: a session that did nothing else made no
/// decision and took no action.
const orbReadOnlyTools = {
  'navigate',
  'describe_page',
  'read_conversation',
  'get_briefing',
  'show_orb_sheet',
  'hide_orb_sheet',
};

/// Whether a session of the orb is worth a summary to the shared agent: the
/// person spoke at least twice, and it was not only looking around (every
/// tool it ran was navigation or reading). A quick "go to X" or a test of the
/// microphone leaves nothing to remember.
bool orbSummaryWorthSending(
  List<(AgentSpeaker, String)> transcript,
  List<AgentToolOutcome> outcomes,
) {
  final turns = transcript
      .where((l) => l.$1 == AgentSpeaker.you && l.$2.trim().isNotEmpty)
      .length;
  if (turns < 2) return false;
  if (outcomes.isNotEmpty &&
      outcomes.every((o) => orbReadOnlyTools.contains(o.name))) {
    return false;
  }
  return true;
}
