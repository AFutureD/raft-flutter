import '../agent_mode/agent_steering.dart';
import 'actions/orb_action_declarations.dart'
    show orbActionCapabilities, orbDrivingCapabilities;
import 'actions/orb_action_prompt.dart';
import 'orb_prompt.dart';
import 'screen/orb_screen_prompt.dart';

/// What the conversation is doing, which decides what the text agent is told
/// and which tools it has (the realtime session always has all of them).
enum OrbMode {
  /// Nothing waits and the car is parked: the whole app.
  normal,

  /// Driving mode is on: one item at a time, reads, and the low-risk actions.
  driving,

  /// A confirm card is on the screen: answer for it, or change or drop it.
  confirming,
}

/// The state of the orb: a card waiting wins over driving mode.
OrbMode orbModeOf({required bool pending, required bool driving}) => pending
    ? OrbMode.confirming
    : driving
    ? OrbMode.driving
    : OrbMode.normal;

const _all = {OrbMode.normal, OrbMode.driving, OrbMode.confirming};
const _free = {OrbMode.normal};
const _moving = {OrbMode.normal, OrbMode.driving};

/// The modes each tool belongs to. Reading is always there; moving the app is
/// not while a card waits; the operations that change something are in the
/// modes that can ask for them (while driving the card, and the asking, are
/// narrowed again to [orbDrivingCapabilities]); `confirm` and `cancel_action`
/// only mean something with a card up.
///
/// A tool this table does not know is given in every mode, so that nothing
/// new becomes unreachable; the parity test asks for a place here.
const orbToolModes = <String, Set<OrbMode>>{
  // Reading.
  'describe_page': _all,
  'read_conversation': _all,
  'get_briefing': _all,
  'list_tasks': _all,
  'task_detail': _all,
  'list_targets': _all,
  'find': _all,
  'query': _all,
  // Moving the app.
  'navigate': _moving,
  'open_item': _moving,
  'screen_action': _free,
  'show_orb_sheet': _free,
  'hide_orb_sheet': _free,
  // Driving.
  'set_driving_mode': _all,
  'driving_next': {OrbMode.driving},
  'next_task': {OrbMode.driving},
  // Asking for a change (one card at a time; a new ask replaces the card).
  'reply': _all,
  'send_message': _all,
  'reply_in_thread': _all,
  'react': _all,
  'mark_read': _all,
  'mark_done': _all,
  'create_task': _all,
  'set_task_status': _all,
  'assign_task': _all,
  'unassign_task': _all,
  'join_channel': _all,
  'reject_task': _all,
  'snooze_item': _all,
  'nudge_task': _all,
  'act': _all,
  'undo': _free,
  // Answering the card.
  'confirm': {OrbMode.confirming},
  'cancel_action': {OrbMode.confirming},
};

/// The tools that ask for a change, by name.
/// Every tool that asks for a change.
final Set<String> orbChangeTools = {
  ...orbActionCapabilities.keys,
  'act',
  'reply',
};

/// What `reply` replaces for the text agent: it never gets these two (the
/// realtime model does).
const orbAgentReplaced = {'send_message', 'reply_in_thread'};

/// The change tools that are fine while the car moves.
final Set<String> orbDrivingChangeTools = {
  for (final e in orbActionCapabilities.entries)
    if (orbDrivingCapabilities.contains(e.value)) e.key,
  'reply',
};

/// Whether the tool [name] is given in [mode] ([driving]: the car is moving,
/// also while a card waits).
bool orbToolIn(String name, OrbMode mode, {required bool driving}) {
  if (orbAgentReplaced.contains(name)) return false;
  final modes = orbToolModes[name];
  if (modes != null && !modes.contains(mode)) return false;
  if (driving && orbChangeTools.contains(name)) {
    return orbDrivingChangeTools.contains(name);
  }
  // While driving, nothing that moves the app by touch or hides the layer.
  if (driving && (name == 'screen_action' || name == 'hide_orb_sheet')) {
    return false;
  }
  return true;
}

/// What the text agent is given in the state it is in: the sections of the
/// prompt that state needs and only its tools. [declarations] are all the
/// orb's tools; [pending] is the summary of the card on the screen.
AgentScope orbAgentScope({
  required OrbMode mode,
  required bool driving,
  required Iterable<Map<String, Object?>> declarations,
  required String channels,
  String style = '',
  String? memory,
  String? pending,
  String? extra,
}) => AgentScope(
  systemPrompt: orbAgentPrompt(
    mode: mode,
    driving: driving,
    channels: channels,
    style: style,
    memory: memory,
    pending: pending,
    extra: extra,
  ),
  tools: [
    for (final d in declarations)
      if (orbToolIn('${d['name']}', mode, driving: driving)) d,
  ],
);

/// The instruction of [mode]: the same sections as [orbSystemPrompt]'s, the
/// ones the state needs, and the confirm card's part as the agent layer has
/// it (the app says the card aloud).
String orbAgentPrompt({
  required OrbMode mode,
  required bool driving,
  required String channels,
  String style = '',
  String? memory,
  String? pending,
  String? extra,
}) {
  final b = StringBuffer(orbPromptIdentity);
  if (memory != null) b.write('\n$memory\n\n');
  b
    ..write(orbPromptPersona)
    ..write(orbPromptSpeaking);
  switch (mode) {
    case OrbMode.normal:
      b
        ..write(orbPromptInApp)
        ..write(orbPromptProactive)
        ..write(orbPromptFacts)
        ..write(orbPromptDiscussionAgent)
        ..write(orbPromptOperating)
        ..write(orbPromptDrivingEnter)
        ..write('\n')
        ..write(orbActionBasicsAgent)
        ..write(orbActionReplyAgent)
        ..write(orbActionConfirmAgent)
        ..write('\n')
        ..write(orbScreenPrompt);
    case OrbMode.driving:
      b
        ..write(orbPromptInApp)
        ..write(orbPromptFacts)
        ..write(orbPromptDrivingEnter)
        ..write(orbPromptDrivingRules)
        ..write('\n')
        ..write(orbActionBasicsAgent)
        ..write(orbActionReplyAgent)
        ..write(orbActionConfirmAgent)
        ..write(orbActionDriving)
        ..write('\n')
        ..write(orbActionTaskPassAgent);
    case OrbMode.confirming:
      b
        ..write(orbPromptFacts)
        ..write('\n')
        ..write(orbActionConfirming(pending ?? '一项操作'))
        ..write(driving ? orbActionDriving : '');
  }
  if (extra != null) b.write('\n$extra');
  b
    ..write('\n')
    ..write(orbPromptListening)
    ..write('\n')
    ..write(orbPromptTail(channels: channels, style: style));
  return '$b';
}
