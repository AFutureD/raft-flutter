/// Hard null assertions allowed in render code by null_assertion_guard_test.dart:
/// file -> trimmed source line -> why it cannot be absent. Prefer publishing
/// state atomically or rendering a loading/fallback state over adding to this
/// list. One entry covers every identical line in the file.
const nullAssertionAllow = <String, Map<String, String>>{
  'apps/raft_flutter/lib/features/channel_members.dart': {
    'agentRows[c.id]!,':
        'Guarded by `agentRows[c.id] != null` on the line above.',
  },
  'apps/raft_flutter/lib/features/chat_view.dart': {
    ': {reactionFailures[m.id]!},': 'Guarded by `reactionFailures[m.id] == null ? const {} : ...` on the line above.',
  },
  'apps/raft_flutter/lib/features/conversation_panel.dart': {
    'tab = RaftConversationTabId.values.firstWhere(': 'RaftLocation.chatTab only returns chat, tasks or files, all enum names.',
  },
  'apps/raft_flutter/lib/features/create_agent_dialog.dart': {
    'createAgentRuntimeNames[o[\'runtimeId\']]!,': 'runtimeOptions are filtered with createAgentRuntimeNames.containsKey when loaded.',
  },
  'apps/raft_flutter/lib/features/im_bridges_view.dart': {
    'label: _checkLabels[id]!,': '_checkLabels covers every check id the projection can emit (SlackBridgeProjection.parse fails closed).',
    ': _pairsValid && pairs.every((pair) => _isMember(p, pair[\'slackChannelId\']!))),': 'Channel pair rows always carry both ids (the pair editor and parse fill them).',
    ': _pairsValid && pairs.every((pair) => _isMember(p, pair[\'slackChannelId\']!))) &&': 'Channel pair rows always carry both ids (the pair editor and parse fill them).',
  },
  'apps/raft_flutter/lib/features/incoming_share_picker.dart': {
    ': (id) => load(servers.firstWhere((s) => s.id == id)),': 'The id comes from the server chips built from the same `servers` list in this build.',
  },
  'apps/raft_flutter/lib/features/message_action_card.dart': {
    'confirmLabel: verbs[type]!,': 'Only reached for known action types; `verbs` lists every type _knownCard renders.',
    '}[key]!,': '`key` iterates the same fixed list of five keys the literal map covers.',
  },
  'apps/raft_flutter/lib/features/provider_views.dart': {
    'computerId: v[\'computerId\']!,': 'Submit values of the form dialog: every field id is present in the submitted map.',
    'model: v[\'model\']!,': 'Submit values of the form dialog: every field id is present in the submitted map.',
  },
  'apps/raft_flutter/lib/features/quick_switcher.dart': {
    'final allRow = rows.firstWhere((r) => r.all);': 'rows always includes the \'all\' row (built with `const _Row(_allKey, all: true)` in the same method).',
    'hit(groups[key]!.first)': '`order` and `groups` are built together from the same keys; each group holds at least one row.',
    '_threadGroup(context, data, groups[key]!, selectedRow, hit),':
        '`order` and `groups` are built together from the same keys.',
  },
  'apps/raft_flutter/lib/features/resource_view.dart': {
    '? BoxConstraints(minHeight: activityGestureHeights[rowKey(row)]!)': 'Guarded by `activityGestureHeights[rowKey(row)] != null` on the line above.',
    'taskSection(status, groups[status]!, scope),': '`groups` is initialised with one list per raftTaskStatuses entry and `status` iterates raftTaskStatuses.',
    '}[advanced.timeRange]!,': 'timeRange is validated against the four known values when restored (search_memory.dart) and only set from the dropdown.',
  },
  'apps/raft_flutter/lib/features/runtime_form_dialog.dart': {
    'controller: c.editors[f.key]!,': 'load() publishes definition and editors in one synchronous block (test/runtime_form_loading_test.dart); boolean and unsupported fields are branched out earlier.',
    'c.editors[f.key]!.text = o[\'value\'];': 'Tap handler of a rendered field; its editor exists for the same reason as the line above.',
  },
  'apps/raft_flutter/lib/features/search_filter_bar.dart': {
    'timeRanges[filters.timeRange]!,': 'timeRange is validated when restored (search_memory.dart) and only set from this dropdown.',
  },
  'apps/raft_flutter/lib/features/server_views.dart': {
    'final link = InviteLink.fromInput(values[\'token\']!);': 'Submit values of the form dialog: every field id is present in the submitted map.',
  },
  'apps/raft_flutter/lib/features/sidebar_preferences_view.dart': {
    'title: Text(labels[ids[index]]!),':
        '`labels` and `ids` are built together from the same section list.',
  },
  'apps/raft_flutter/lib/features/workspace_grid_view.dart': {
    '? \'\${raftText(context, \'Thread\')} \${sessions.threadRefs[id]!.messagePrefix}\'':
        'Guarded by `threadRefs.containsKey(id)` on the line above.',
    'controller: sessions.controllers[id]!,': 'Guarded by `sessions.controllers[id] == null ? SizedBox.shrink : ...` in the same expression.',
    '.controllers[id]!': 'Same tab body as the guarded entries; read in a tap callback of a tab that exists only while the controller does.',
  },
  'packages/raft_ui/lib/chat_composition_previews.dart': {
    'expanded: expanded[kind]!,':
        'Preview-only widget; the map is built over every kind.',
  },
  'packages/raft_ui/lib/mobile_tabbar_config_previews.dart': {
    'label: _tabs.firstWhere((t) => t.id == id).label,':
        'Preview-only widget with a fixed tab list and ids taken from it.',
    'glyph: _tabs.firstWhere((t) => t.id == id).glyph,':
        'Preview-only widget with a fixed tab list and ids taken from it.',
  },
  'packages/raft_ui/lib/rich_visual_previews.dart': {
    '? inputs[widget.kind]!':
        'Preview-only widget; inputs has an entry for every kind.',
  },
  'packages/raft_ui/lib/src/attachment_gallery.dart': {
    'final d = dimensions.single;':
        'Inside the `dimensions.length == 1` branch.',
  },
  'packages/raft_ui/lib/src/computer_detail.dart': {
    'final current = options.firstWhere((o) => o.\$1 == mode);':
        '`options` is a fixed list holding every mode the state can take.',
  },
  'packages/raft_ui/lib/src/emoji_picker.dart': {
    'label: _categoryNames[key]!,': 'Static category-name map covering every category key of the generated emoji data.',
  },
  'packages/raft_ui/lib/src/feedback_inbox.dart': {
    'raftText(context, RaftFeedbackFilterTabs.labels[value]!),':
        '`value` iterates the fixed filter tab ids that labels covers.',
    'label: raftText(context, labels[status]!),':
        '`labels` covers every RaftFeedbackStatus; status is that enum.',
    'final (title, body) = copy[kind]!;':
        '`copy` covers every empty-state kind; kind is a fixed enum.',
  },
  'packages/raft_ui/lib/src/forward_composer.dart': {
    'label: names[id]!,': '`id` is taken from names.keys in the same builder.',
  },
  'packages/raft_ui/lib/src/inline_badge_editor.dart': {
    'focusNode: nodes[option.id]!,': 'updateNodes() runs in initState and didUpdateWidget, before build, for every widget.options entry.',
  },
  'packages/raft_ui/lib/src/message_body.dart': {
    '? children!.single': 'Inside the `children!.length == 1` branch; children is set in initState.',
  },
  'packages/raft_ui/lib/src/message_reference_chip.dart': {
    '}, tokens: resolver)[\'root\']!;': 'The recipe evaluator always returns the \'root\' node it was asked for.',
  },
};
