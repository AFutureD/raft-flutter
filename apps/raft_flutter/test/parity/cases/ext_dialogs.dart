// raft-flutter parity EXTENSION suite builders (tool/parity-ext): official
// dialog cases at desktop width. NOT official cases; ids are
// `components.dialogs.desktop.<key>.<theme>`, dispatched on props.official
// exactly like tool/parity-ext/host/DesktopDialogCases.tsx.
//
// Each case reuses the official [ParityCase] of `props.official` (the Create
// channel / Create agent dialogs the phone cases already mount); only the
// viewport (1280x800, set by the case) differs, so the product dialog is
// laid out at desktop width over the page.
import '../parity_harness.dart';
import 'home_tasks.dart' show homeTaskCases;
import 'members_settings.dart' show membersSettingsCases;

const _keys = {
  'create-channel': 'components.home.create-channel.dialog',
  'create-agent': 'components.members.create-agent.dialog',
  'create-agent-error': 'components.members.create-agent.dialog-error',
  'create-agent-empty': 'components.members.create-agent.dialog-empty',
  'create-agent-claude': 'components.members.create-agent.claude-dialog',
};

ParityCase _official(String id) {
  final c = homeTaskCases[id] ?? membersSettingsCases[id];
  if (c == null) throw StateError('no official parity case $id');
  return c;
}

/// Every extension desktop dialog case, keyed by id (3 themes each).
final Map<String, ParityCase> extDialogCases = {
  for (final MapEntry(:key, value: official) in _keys.entries)
    for (final theme in const ['brutal', 'elegant', 'elegant-dark'])
      'components.dialogs.desktop.$key.$theme': _official(official),
};
