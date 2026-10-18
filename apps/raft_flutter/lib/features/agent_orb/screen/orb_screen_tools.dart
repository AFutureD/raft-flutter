import '../nav/orb_page_description.dart' show orbPageTitle;
import '../orb_tool.dart';
import '../orb_tool_docs.dart' show orbToolDescription;
import 'orb_screen.dart';
import 'orb_screen_capability.dart';

export 'orb_screen.dart' show OrbScreen, OrbScreenAsk;
export 'orb_screen_contract.dart' show OrbScreenDetail, orbScreenShort;

/// The screen tool of the Agent orb: `screen_action`. What is on the screen
/// comes with `navigate`, `open_item` and `describe_page` (their `screen`
/// field), on every page, from the app's semantics.
List<OrbTool> orbScreenTools() => [
  OrbTool(declaration: _screenActionDeclaration, handler: _screenAction),
];

final _screenActionDeclaration = <String, Object?>{
  'name': 'screen_action',
  'description': orbToolDescription('screen_action'),
  'parameters': {
    'type': 'object',
    'properties': {
      'id': {
        'type': 'string',
        'description': '控件的 id，例如 a12，来自屏幕读数的 actions / scroll',
      },
      'action': {
        'type': 'string',
        'enum': orbScreenActions,
        'description': 'tap 点；longPress 长按；setText 填字；increase/decrease 步进；scrollUp/Down 滚动；dismiss 关掉；expand/collapse 展开收起',
      },
      'text': {'type': 'string', 'description': 'action 是 setText 时要填的文字'},
      'confirmed': {
        'type': 'boolean',
        'description': '只在没有确认卡可用、用户已经明确同意之后才设 true',
      },
    },
    'required': ['id', 'action'],
  },
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
  screen.context = context;
  final id = _str(args['id']);
  final name = _str(args['action']);
  if (id == null || name == null) return {'error': '要给 id 和 action'};
  final action = orbScreenSemanticsAction(name);
  if (action == null) {
    return {'error': 'action 只能是 ${orbScreenActions.join('、')} 之一'};
  }

  // A reading is what the model is shown again when its id does not hold.
  Future<Map<String, Object?>> stale(String why) async => {
    'error': '$why：照下面新读到的 snapshot 再选一次，不要猜 id',
    'snapshot': await screen.contractFor(ctx),
  };

  final found = screen.resolve(id);
  final control = found.node;
  final scroller = found.scroll;
  if (control == null && scroller == null) {
    return stale(found.stale ?? '屏幕已经变了');
  }
  final label = control?.label ?? scroller!.label;
  final offered = control?.actions ?? scroller!.actions;
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
  if (name == 'setText') {
    final t = args['text'];
    if (t is! String) return {'error': 'setText 要给 text'};
    text = t;
  }

  // The consequences are the person's to allow: the orb's confirm card.
  if ((name == 'tap' || name == 'longPress') &&
      control != null &&
      orbScreenRisky(control.label, control.role)) {
    final ask = screen.ask;
    if (ask != null) return ask({'id': id, 'action': name, 'text': ?text});
    final key = '$id|$name';
    if (args['confirmed'] == true && screen.pendingConfirm == key) {
      screen.pendingConfirm = null;
    } else {
      screen.pendingConfirm = key;
      return {
        'needsConfirm': true,
        'describe':
            '要${name == 'tap' ? '点' : '长按'}「${control.label}」（${control.role}，在屏幕${control.at.isEmpty ? '上' : control.at}）。这个操作有后果',
        'note': '先向用户说清楚要做什么；用户同意后，带 confirmed: true 再调用一次同一个 id 和 action。没有同意就不要重试。',
      };
    }
  }

  final before = w.location.toString();
  ctx.operating.value = true;
  try {
    final acted = await screen.act(
      context,
      id,
      action,
      text: text,
      // The person touching the screen while this was read takes over.
      stillMine: () => ctx.operating.value,
    );
    if (acted.cancelled) {
      return {'cancelled': true, 'note': '用户碰了屏幕，Agent 已让出控制'};
    }
    if (acted.unavailable) return {'error': '读不到屏幕上的控件，没有做'};
    if (acted.stale != null) {
      return {
        'error': '${acted.stale}：照下面新读到的 snapshot 再选一次，不要猜 id',
        'snapshot': acted.screen,
      };
    }
    final moved = w.location.toString() != before;
    return {
      'ok': true,
      'did': '$name「${label.isEmpty ? id : label}」',
      if (moved) 'route': w.location.toString(),
      if (moved) 'title': orbPageTitle(w, w.location),
      'snapshot': acted.screen,
    };
  } finally {
    ctx.operating.value = false;
  }
}
