import 'package:flutter/foundation.dart';

import '../../data/workspace_controller.dart';
import 'briefing/orb_briefing_models.dart';
import 'briefing/orb_briefing_service.dart';
import 'nav/orb_nav_tools.dart' show OrbArrivalBrief, OrbKind, OrbMatch;
import 'orb_tool.dart';

/// How long the model may take to word the briefing `navigate` brings along;
/// past it the rules' sentences are used (same people, places and asks).
const orbArrivalModelWait = Duration(seconds: 5);

/// The briefing scope of a place `navigate` opened: the Activity, or one
/// conversation (a channel, a private conversation, a discussion); null for
/// any other page.
OrbBriefScope? orbArrivalScope(OrbMatch match) => switch (match.kind) {
  OrbKind.page when match.id == 'activity' => OrbBriefScope.activity,
  OrbKind.channel || OrbKind.dm => OrbBriefScope.conversation(match.id),
  OrbKind.thread when match.data['threadChannelId'] is String =>
    OrbBriefScope.conversation(match.data['threadChannelId']! as String),
  _ => null,
};

/// What `navigate` adds on arrival at a conversation or the Activity: the
/// same facts `get_briefing` gives (needsYou, progress, routine count), always
/// the whole picture rather than only what is new since the last briefing.
/// [serviceFor] gives the service of a workspace (tests pass one with a fake
/// model).
OrbArrivalBrief orbArrivalBrief({
  OrbBriefingService Function(WorkspaceController w)? serviceFor,
}) => (OrbToolContext ctx, OrbMatch match) async {
  final scope = orbArrivalScope(match);
  if (scope == null) return null;
  final briefing = await (serviceFor ?? OrbBriefingService.of)(ctx.workspace)
      .brief(scope, full: true, modelWait: orbArrivalModelWait);
  if (!kReleaseMode) {
    for (final i in briefing.needsYou) {
      debugPrint(
        'orb-brief needsYou ${i.reason.name} who=${i.who} '
        'where=${i.where} title=${i.title}',
      );
    }
  }
  return briefing.toJson(ordered: ctx.agentLayer);
};
