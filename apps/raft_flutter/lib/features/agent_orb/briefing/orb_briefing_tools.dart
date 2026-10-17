import 'dart:async';

import 'package:flutter/material.dart' show Navigator;

import '../../../data/raft_location.dart';
import '../../../data/workspace_controller.dart';
import '../../agent_mode/capabilities/agent_capability.dart'
    show AgentCapabilityError;
import '../../agent_mode/capabilities/capability_support.dart'
    show channelByRef;
import '../orb_tool.dart';
import 'orb_briefing_models.dart';
import 'orb_briefing_service.dart';
import 'orb_briefing_sheet.dart';

/// Opens an item's [OrbBriefItem.link] in the app. The host decides how: the
/// default only moves the app's navigation to the location.
typedef OrbOpenLink = FutureOr<void> Function(
  OrbBriefItem item,
  OrbToolContext ctx,
);

/// A suggested-action chip was tapped. Phase 1: the host receives it and
/// confirms with the person before anything is sent.
typedef OrbActionHandler = FutureOr<void> Function(
  OrbBriefItem item,
  OrbSuggestedAction action,
  OrbToolContext ctx,
);

/// The default [OrbOpenLink]: the app's navigation goes to the item's route.
void defaultOrbOpenLink(OrbBriefItem item, OrbToolContext ctx) {
  try {
    ctx.workspace.navigation.navigate(RaftLocation.parse(item.link));
  } on Object {
    // A route that is not in the bound server cannot be opened from here.
  }
}

const orbBriefingToolName = 'get_briefing';

const orbBriefingDeclaration = <String, Object?>{
  'name': orbBriefingToolName,
  'description':
      '读出简报：现在有什么事需要用户关注。用户问“有什么要我处理的”“动态里有什么”“这个频道怎么样了”时调用它。用 navigate 刚到动态、频道、私信、讨论时，返回里已经带了同一份 briefing，不要再调。'
      '返回 overview（一句总览）、needsYou（需要用户处理的事，每件有 who 谁、title 什么事、where 在哪、since 等了多久、ask 要他做什么、suggestedAction 建议的一句话处理）、'
      'progress（有进展的事）、routineCount（常规条数）。'
      '怎么说：先说 overview 这一句；再逐件说 needsYou（谁、什么事、到哪一步了、要他做什么），一件说完停一下，等用户指令或插话；'
      'progress 只在用户问进展时用一句话带过；常规的只说条数（“其余 N 条是常规进度”），不要念内容。'
      '用真实姓名，不要念标题模板，不要念原文；用户要原文时再用读取工具。'
      '再次调用只返回自上次简报以来新的内容（返回里 sinceLastTime 为 true，alreadyBriefed 是上次说过、没有再列出的件数）；用户要听全部时把 full 设为 true。'
      'show 设为 true 会同时在屏幕上打开简报卡片，用户可以瞄一眼、点某一件直接打开。',
  'parameters': {
    'type': 'object',
    'properties': {
      'scope': {
        'type': 'string',
        'description': '简报的范围：activity（动态，默认），或某个频道、私信、讨论的名字或 id',
        'maxLength': 120,
      },
      'show': {'type': 'boolean', 'description': '同时在屏幕上打开简报卡片'},
      'full': {'type': 'boolean', 'description': '要全部内容，而不只是自上次以来新的'},
    },
  },
};

/// The briefing tools of the orb: `get_briefing`.
///
/// [openLink] opens a tapped item in the app (default: the workspace
/// navigation to its route); [onAction] receives the suggested-action chip;
/// [serviceFor] gives the service of a workspace (tests pass one with a fake
/// model).
List<OrbTool> orbBriefingTools({
  OrbOpenLink? openLink,
  OrbActionHandler? onAction,
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
            .brief(scope, full: args['full'] == true);
      } on Object {
        return {'error': '简报没读出来，稍后再试'};
      }
      var shown = false;
      final navigator = ctx.navigatorContext;
      if (args['show'] == true && navigator.mounted) {
        shown = true;
        // The sheet stays up while the model speaks: not awaited.
        unawaited(
          OrbBriefingSheet.show(
            navigator,
            briefing,
            onOpen: (item) {
              Navigator.of(navigator, rootNavigator: true).maybePop();
              (openLink ?? defaultOrbOpenLink)(item, ctx);
            },
            onAction: (item, action) => onAction?.call(item, action, ctx),
          ),
        );
      }
      return {...briefing.toJson(), 'shown': shown};
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
