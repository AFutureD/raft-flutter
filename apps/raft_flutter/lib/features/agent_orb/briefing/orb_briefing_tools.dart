import '../../../data/raft_location.dart';
import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/agent_capability.dart'
    show AgentCapabilityError;
import '../../agent_mode/capabilities/capability_support.dart'
    show channelByRef;
import '../orb_tool.dart';
import '../orb_tool_docs.dart' show orbToolDescription;
import 'orb_briefing_models.dart';
import 'orb_briefing_service.dart';

/// Opens an item's [OrbBriefItem.link] in the app: the app's navigation goes
/// to the item's route. The orb's layer calls it when a card is tapped.
void defaultOrbOpenLink(OrbBriefItem item, OrbToolContext ctx) {
  try {
    ctx.workspace.navigation.navigate(RaftLocation.parse(item.link));
  } on Object {
    // A route that is not in the bound server cannot be opened from here.
  }
}

/// Shows a briefing as cards in the orb's immersive layer.
typedef OrbShowBriefing = void Function(
  OrbBriefing briefing,
  OrbToolContext ctx,
);

const orbBriefingToolName = 'get_briefing';

final orbBriefingDeclaration = <String, Object?>{
  'name': orbBriefingToolName,
  'description': orbToolDescription(orbBriefingToolName),
  'parameters': {
    'type': 'object',
    'properties': {
      'scope': {
        'type': 'string',
        'description': 'activity（动态，默认）或某个频道、私信、讨论的名字或 id；没指定地方就不给',
        'maxLength': 120,
      },
      'show': {
        'type': 'boolean',
        'description':
            '设 true 同时在屏幕上铺简报卡片（全部都铺）：用户说“看”“拿出来看”“给我看”；只要听就不设。驾驶中不用管：App 一直会铺',
      },
      'full': {
        'type': 'boolean',
        'description': '设 true 连上次说过的也列出：用户说“全部”“没读的都”“再来一遍”',
      },
    },
  },
};

/// The briefing tools of the orb: `get_briefing`.
///
/// [showBriefing] puts the cards in the orb's immersive layer (without it
/// `show` is not claimed);
/// [serviceFor] gives the service of a workspace (tests pass one with a fake
/// model).
List<OrbTool> orbBriefingTools({
  OrbShowBriefing? showBriefing,
  OrbBriefingService Function(WorkspaceController w)? serviceFor,
}) => [
  OrbTool(
    declaration: orbBriefingDeclaration,
    handler: (args, ctx) async {
      final String? conversation;
      try {
        conversation = _scopeOf(ctx.workspace, args['scope']);
      } on AgentCapabilityError catch (e) {
        // Which channel? The candidates are the answer.
        return e.toJson();
      } on Object {
        return {'error': '没有找到这个频道或私信'};
      }
      final scope = conversation == null
          ? OrbBriefScope.activity
          : OrbBriefScope.conversation(conversation);
      final OrbBriefing briefing;
      try {
        briefing = await (serviceFor ?? OrbBriefingService.of)(ctx.workspace)
            // The cards on the screen are the whole picture: what `navigate`
            // brought a moment ago would otherwise leave them empty.
            .brief(scope, full: args['full'] == true || args['show'] == true);
      } on Object {
        return {'error': '简报没读出来，稍后再试'};
      }
      var shown = false;
      if (args['show'] == true &&
          showBriefing != null &&
          ctx.navigatorContext.mounted) {
        shown = true;
        // The layer stays up while the model speaks: nothing to await.
        showBriefing(briefing, ctx);
      }
      return {...briefing.toJson(ordered: ctx.agentLayer), 'shown': shown};
    },
  ),
];

/// The conversation id the `scope` argument names; null for the Activity.
String? _scopeOf(WorkspaceController w, Object? scope) {
  final ref = scope is String ? scope.trim() : '';
  if (ref.isEmpty ||
      const {'activity', '动态', 'inbox', '首页'}.contains(ref.toLowerCase())) {
    return null;
  }
  if (ref.startsWith('conversation:')) return ref.substring(13);
  return channelByRef(w, ref).id;
}
