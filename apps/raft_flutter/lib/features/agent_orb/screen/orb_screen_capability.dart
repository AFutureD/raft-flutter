import 'dart:ui' show SemanticsAction;

import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/action_support.dart';
import '../../agent_mode/capabilities/agent_capability.dart';
import '../../agent_mode/capabilities/capability_support.dart';
import '../nav/orb_page_description.dart' show orbPageTitle;
import 'orb_screen.dart';
import 'orb_screen_snapshot.dart';

/// The `screen_action` of a control whose name says it has consequences,
/// carried by the orb's capability layer: the confirm card shows what will be
/// pressed, the person taps 确认 (or says yes), and only then does the press
/// happen. Orb only: Agent mode has no screen to press.
///
/// It is not for the model to look up: `screen_action` asks for it when the
/// label of the control is risky (see `orbScreenRisky`).
const orbScreenActions = [
  'tap',
  'longPress',
  'setText',
  'increase',
  'decrease',
  'scrollUp',
  'scrollDown',
  'dismiss',
  'expand',
  'collapse',
];

SemanticsAction? orbScreenSemanticsAction(String name) => switch (name) {
  'tap' => SemanticsAction.tap,
  'longPress' => SemanticsAction.longPress,
  'setText' => SemanticsAction.setText,
  'increase' => SemanticsAction.increase,
  'decrease' => SemanticsAction.decrease,
  'scrollUp' => SemanticsAction.scrollUp,
  'scrollDown' => SemanticsAction.scrollDown,
  'dismiss' => SemanticsAction.dismiss,
  'expand' => SemanticsAction.expand,
  'collapse' => SemanticsAction.collapse,
  _ => null,
};

({OrbScreenNode node, String action}) _target(
  WorkspaceController w,
  Map<String, Object?> args,
) {
  final id = '${args['id'] ?? ''}'.trim();
  final action = '${args['action'] ?? ''}'.trim();
  final found = OrbScreen.of(w).resolve(id);
  final node = found.node;
  if (node == null) {
    throw AgentCapabilityError(
      '${found.stale ?? '屏幕已经变了'}：什么都没做。再读一次屏幕（describe_page），照新的再选',
    );
  }
  if (!node.actions.contains(action)) {
    throw AgentCapabilityError('「${node.label}」不支持 $action');
  }
  return (node: node, action: action);
}

final orbScreenCapability = AgentCapability(
  id: 'screen.action',
  title: '在当前屏幕上按一个有后果的控件（发送、删除、批准……）：先出确认卡，用户确认后才按',
  kind: AgentCapabilityKind.action,
  risk: AgentCapabilityRisk.change,
  keywords: const ['屏幕', '按钮', '点一下', '点击', 'screen action'],
  paramsSchema: objectSchema(
    {
      'id': strArg('控件的 id（来自屏幕读数的 actions）', max: 40),
      'action': strArg(
        'tap / longPress / ...',
        values: orbScreenActions,
        max: 20,
      ),
      'text': strArg('action 是 setText 时填的字', max: 4000),
    },
    required: const ['id', 'action'],
  ),
  resultSummary: 'done',
  preview: (w, args, env) async {
    final t = _target(w, args);
    final label = t.node.label.isEmpty ? t.node.role : t.node.label;
    return AgentActionPreview(
      summary:
          '${t.action == 'longPress' ? '长按' : '点'}「${quote(label, 30)}」'
          '（${orbPageTitle(w, w.location)}）',
      changes: [
        change('按', '', quote(label, 40)),
        change('页面', '', orbPageTitle(w, w.location)),
        if (t.node.at.isNotEmpty) change('位置', '', '屏幕${t.node.at}'),
      ],
    );
  },
  run: (w, args, env) async {
    final t = _target(w, args);
    final screen = OrbScreen.of(w);
    final context = screen.context;
    if (context == null || !context.mounted) {
      throw const AgentCapabilityError('界面没有准备好，什么都没做');
    }
    final text = args['text'];
    final acted = await screen.act(
      context,
      t.node.id,
      orbScreenSemanticsAction(t.action)!,
      text: t.action == 'setText' && text is String ? text : null,
    );
    if (!acted.done) {
      throw AgentCapabilityError(
        '${acted.stale ?? '屏幕上按不了'}：什么都没做。再读一次屏幕，照新的再选',
      );
    }
    return actionResult(
      '已${t.action == 'longPress' ? '长按' : '点'}「${quote(t.node.label, 30)}」',
    );
  },
);
