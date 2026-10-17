import 'dart:ui' show SemanticsAction;

import '../nav/orb_page_description.dart' show orbPageTitle;
import '../orb_tool.dart';
import 'orb_screen.dart';
import 'orb_screen_contract.dart';
import 'orb_screen_snapshot.dart';

export 'orb_screen.dart' show OrbScreen, OrbScreenConfirm, OrbScreenHold;
export 'orb_screen_contract.dart' show OrbScreenDetail, orbScreenShort;

/// The screen tool of the Agent orb: `screen_action`. What is on the screen
/// comes with `navigate`, `open_item` and `describe_page` (their `screen`
/// field), in every page, from the app's semantics.
List<OrbTool> orbScreenTools() => [
  OrbTool(declaration: _screenActionDeclaration, handler: _screenAction),
];

const _actions = [
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

const _screenActionDeclaration = <String, Object?>{
  'name': 'screen_action',
  'description':
      '在当前页面上做一件事，就像用户点了屏幕：点一个按钮、切一个标签、打开一行、往输入框里填字、滚动。'
      'id 来自最近一次读屏幕的结果（navigate / open_item / describe_page 返回里 screen.actions 的 id，或 screen.scroll 的 id），action 必须是那一项 do 里列出的。'
      '先读再做，不要猜 id。id 只对那一次读到的屏幕有效：返回 error 并带 snapshot 时，说明屏幕变了，snapshot 就是新读到的屏幕，照它再选一次（只重试一次）。'
      'setText 把 text 填进输入框，不会发送。发送、删除、移除、批准、合并、发布、退出、归档这类有后果的控件会返回 needsConfirm: true 和 describe：'
      '先向用户说清楚要做什么，用户同意后，再带 confirmed: true 重新调用同一个 id；没有同意就不要重试。'
      '成功后返回 {ok, snapshot}：snapshot 是做完以后的屏幕；页面换了会带 route 和 title。',
  'parameters': {
    'type': 'object',
    'properties': {
      'id': {
        'type': 'string',
        'description': '控件的 id，例如 a12，来自屏幕读数的 actions / scroll',
      },
      'action': {
        'type': 'string',
        'enum': _actions,
        'description': 'tap 点一下 / longPress 长按 / setText 填字 / increase decrease 滑块或步进 / scrollUp scrollDown 滚动 / dismiss 关掉 / expand collapse 展开收起',
      },
      'text': {'type': 'string', 'description': 'action 是 setText 时要填的文字'},
      'confirmed': {
        'type': 'boolean',
        'description': '用户已经明确同意这件有后果的事之后才设 true',
      },
    },
    'required': ['id', 'action'],
  },
};

SemanticsAction? _actionOf(String name) => switch (name) {
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

final _riskyWords = RegExp(
  r'\b(send|delete|remove|approve|merge|publish|leave|archive|sign\s*out|log\s*out)\b|发送|删除|移除|批准|合并|发布|退出|归档',
  caseSensitive: false,
);

/// A control whose name says it has consequences (send, delete, remove,
/// approve, merge, publish, leave, archive, sign out and their Chinese
/// names). A long text on a row is a message, not a command.
bool orbScreenRisky(String label, String role) =>
    (role != 'row' || label.length <= 60) && _riskyWords.hasMatch(label);

String? _str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;

Future<Map<String, Object?>> _screenAction(
  Map<String, Object?> args,
  OrbToolContext ctx,
) async {
  final w = ctx.workspace;
  if (w.server == null) return {'error': '还没有进入工作区'};
  final screen = OrbScreen.of(w);
  final context = ctx.navigatorContext;
  final id = _str(args['id']);
  final name = _str(args['action']);
  if (id == null || name == null) return {'error': '要给 id 和 action'};
  final action = _actionOf(name);
  if (action == null) return {'error': 'action 只能是 ${_actions.join('、')} 之一'};

  Future<Map<String, Object?>> stale(String why) async => {
    'error': why,
    'snapshot': await screen.contract(context),
  };

  final snapshot = screen.latest;
  if (snapshot == null) return stale('还没有读过屏幕：先看一下下面的 snapshot，再选');
  final control = snapshot.byId(id);
  final scroller = control == null ? snapshot.scrollById(id) : null;
  if (control == null && scroller == null) {
    return stale('屏幕已经变了，$id 不在最新读到的屏幕上：照下面新读到的 snapshot 再选一次，不要猜 id');
  }
  final node = control?.node ?? scroller!.node;
  final label = control?.label ?? scroller!.label;
  final offered = control?.actions ?? scroller!.actions;
  if (!node.attached) return stale('这个控件已经不在屏幕上了：照下面新读到的 snapshot 再选一次');
  if (control != null) {
    final why = screen.staleReason(snapshot, control);
    if (why != null) return stale('$why：照下面新读到的 snapshot 再选一次');
  }
  if (control != null && !control.enabled) {
    return {'error': '「$label」现在是灰的，点不了', 'available': offered};
  }
  if (!offered.contains(name)) {
    return {
      'error': '「${label.isEmpty ? id : label}」不支持 $name',
      'available': offered,
    };
  }
  String? text;
  if (action == SemanticsAction.setText) {
    final t = args['text'];
    if (t is! String) return {'error': 'setText 要给 text'};
    text = t;
  }

  // The consequences are the person's to allow.
  if ((action == SemanticsAction.tap || action == SemanticsAction.longPress) &&
      control != null &&
      orbScreenRisky(control.label, control.role)) {
    final key = '$id|$name';
    final describe =
        '要${name == 'tap' ? '点' : '长按'}「${control.label}」（${control.role}，在屏幕${control.at.isEmpty ? '上' : control.at}）。这个操作有后果';
    final confirm = screen.confirm;
    if (confirm != null) {
      if (!await confirm(context, describe)) {
        return {'declined': true, 'note': '用户没有同意，没有做'};
      }
    } else if (args['confirmed'] == true && screen.pendingConfirm == key) {
      screen.pendingConfirm = null;
    } else {
      screen.pendingConfirm = key;
      return {
        'needsConfirm': true,
        'describe': describe,
        'note': '先向用户说清楚要做什么；用户同意后，带 confirmed: true 再调用一次同一个 id 和 action。没有同意就不要重试。',
      };
    }
  }

  final before = w.location.toString();
  ctx.operating.value = true;
  try {
    // The person touching the screen while this was read takes over.
    if (!ctx.operating.value) {
      return {'cancelled': true, 'note': '用户碰了屏幕，Agent 已让出控制'};
    }
    screen.perform(context, control ?? _asControl(scroller!), action, text);
    final after = await screen.contract(context);
    final moved = w.location.toString() != before;
    return {
      'ok': true,
      'did': '$name「${label.isEmpty ? id : label}」',
      if (moved) 'route': w.location.toString(),
      if (moved) 'title': orbPageTitle(w, w.location),
      'snapshot': after,
    };
  } finally {
    ctx.operating.value = false;
  }
}

OrbScreenNode _asControl(OrbScreenScroll s) => OrbScreenNode(
  id: s.id,
  role: 'scroll',
  label: s.label,
  actions: s.actions,
  node: s.node,
);
