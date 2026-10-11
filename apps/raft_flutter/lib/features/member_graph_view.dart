// The /members/graph page (Web MainLayout `MemberGraphRoute` +
// settings/MemberGraphSection.tsx): GET /servers/:id/member-graph, the
// Graph header (Experimental) and RaftMemberGraphView with a profile hover card
// on every node. Guests are sent home like the Web route does.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_client/raft_client.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/recipes.dart';

import '../data/raft_location.dart';
import '../data/raft_navigation_history.dart';
import '../data/workspace_controller.dart';
import 'profile_preview.dart';
import 'sender_avatar_projection.dart';

/// `layout.memberGraph.*` page: header, scrolling body and the section.
class MemberGraphPage extends StatefulWidget {
  const MemberGraphPage({
    super.key,
    required this.controller,
    this.onBack,
    this.sectionLabel = 'Connections',
  });
  final WorkspaceController controller;

  /// The mobile back chevron (`useMobileBack`): back to the members list.
  final VoidCallback? onBack;
  final String sectionLabel;
  @override
  State<MemberGraphPage> createState() => _MemberGraphPageState();
}

class _MemberGraphPageState extends State<MemberGraphPage> {
  WorkspaceController get w => widget.controller;
  RaftMemberGraphData? data;
  bool loading = false;
  String? error;
  int request = 0;
  late String openedServer = w.server?.id ?? '';

  bool get guest => w.server?.string('role') == 'guest';

  @override
  void initState() {
    super.initState();
    w.addListener(serverChanged);
    if (guest) {
      WidgetsBinding.instance.addPostFrameCallback((_) => leaveForGuest());
    } else {
      unawaited(load());
    }
  }

  @override
  void dispose() {
    w.removeListener(serverChanged);
    super.dispose();
  }

  /// `<Navigate to={serverSlug ? `/s/${serverSlug}` : "/"} replace />`.
  void leaveForGuest() {
    if (!mounted || !guest) return;
    w.navigation.navigate(
      RaftLocation.at(serverSlug: w.location.serverSlug, route: RaftRoute.home),
      kind: RaftNavigationKind.replace,
    );
    w.notifyListeners();
  }

  /// `useEffect(..., [current?.id])`: a new workspace reloads the graph.
  void serverChanged() {
    final id = w.server?.id ?? '';
    if (id == openedServer) return;
    openedServer = id;
    request++;
    setState(() {
      data = null;
      error = null;
      loading = false;
    });
    if (guest) {
      leaveForGuest();
    } else if (id.isNotEmpty) {
      unawaited(load());
    }
  }

  Future<void> load() async {
    final server = w.server;
    if (server == null) return;
    final ticket = ++request;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final value = await w.client.get('/servers/${server.id}/member-graph');
      if (!mounted || ticket != request) return;
      setState(() => data = _parse(value));
    } catch (e) {
      if (!mounted || ticket != request) return;
      setState(
        () => error = e is RaftApiException && e.message.isNotEmpty
            ? e.message
            : raftText(context, 'Failed to load member graph'),
      );
    } finally {
      if (mounted && ticket == request) setState(() => loading = false);
    }
  }

  static RaftMemberGraphData _parse(Object? value) {
    if (value is! Map) return const RaftMemberGraphData();
    List<T> rows<T>(String key, T Function(Map<String, dynamic>) make) => [
      for (final row in value[key] as List? ?? const [])
        if (row is Map) make(Map<String, dynamic>.from(row)),
    ];
    return RaftMemberGraphData(
      humans: rows('humans', RaftGraphMember.fromJson),
      agents: rows('agents', RaftGraphMember.fromJson),
      channels: rows('channels', RaftGraphChannel.fromJson),
    );
  }

  /// `AvatarSlot` of a graph member: uploaded / Gravatar / pixel artwork with
  /// the user / bot glyph as fallback.
  Widget avatar(
    BuildContext context,
    RaftGraphMember member, {
    required bool compact,
  }) {
    final row = {
      'id': member.id,
      'userId': member.id,
      'avatarUrl': member.avatarUrl,
      'gravatarHash': member.gravatarHash.isEmpty ? null : member.gravatarHash,
    };
    final projection = projectSenderAvatar(
      origin: w.client.origin,
      senderId: member.id,
      senderType: member.agent ? 'agent' : 'user',
      agents: member.agent ? [row] : const [],
      members: member.agent ? const [] : [row],
      requestSize: compact ? 20 : 36,
    );
    final t = RaftTokens.of(context);
    // The Avatar recipe's placeholder fill and glyph colour (`bg-fill-muted`
    // / `text-foreground-placeholder` in Elegant, the brutal swatches there).
    final recipe = RaftAvatarRecipe.resolve(
      theme: t.recipeTheme,
      type_: member.agent
          ? RaftAvatarRecipeType.agent
          : RaftAvatarRecipeType.human,
      size: RaftAvatarRecipeSize.xl,
      states: t.recipeStates(),
      tokens: t.recipeTokens,
    );
    final glyph = RaftIcon(
      member.agent ? RaftGlyph.bot : RaftGlyph.user,
      size: compact ? 12 : 18,
      color: recipe.fallback.color?.resolve(t.recipeTokens),
    );
    final content = RaftAvatarContent(
      name: member.label,
      kind: member.agent
          ? RaftAvatarContentKind.agent
          : RaftAvatarContentKind.human,
      uploadedUrl: projection.uploadedUrl,
      gravatarUrl: projection.gravatarUrl,
      pixelKey: projection.pixelKey,
      fallback: Center(child: glyph),
    );
    return compact
        ? RaftAvatarSlot(
            name: member.label,
            agent: member.agent,
            avatarUrl: member.avatarUrl,
            slot: RaftAvatarSlotContext.compactList,
            content: content,
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              color: recipe.root.decoration(t.recipeTokens).color,
            ),
            child: content,
          );
  }

  @override
  Widget build(BuildContext context) {
    if (guest) return const SizedBox.shrink();
    final t = RaftTokens.of(context);
    final narrow = MediaQuery.sizeOf(context).width < 768;
    return RaftPanelTextScope(
      child: Column(
        key: const ValueKey('member-graph-page'),
        children: [
          // PanelHeader: GitBranch 18, `bg-primary-soft theme-brutal:bg-soft-signal`
          // (Elegant `border-0 bg-fill-muted`), `Badge.Experimental` suffix.
          Container(
            color: t.brutal
                ? RaftPrimitiveColors.white
                : t.colors['layer-canvas-muted'],
            child: RaftPanelHeaderBar(
              title: raftText(context, 'Graph'),
              onBack: narrow ? widget.onBack : null,
              backTooltip: raftText(context, 'Back'),
              backKey: const ValueKey('member-graph-mobile-back'),
              titleSuffix: Transform.translate(
                offset: const Offset(0, -1),
                // `<Badge.Experimental>`: solid success variant, uppercase.
                child: RaftRecipeBadge(
                  raftText(context, 'Experimental'),
                  appearance: RaftBadgeRecipeAppearance.solid,
                  variant: RaftBadgeRecipeVariant.success,
                  uppercase: true,
                ),
              ),
              iconSlot: RaftPanelHeaderIconTile(
                glyph: RaftGlyph.gitBranch,
                background: t.brutal
                    ? t.product.softSignal
                    : t.colors['fill-muted']!,
                borderless: !t.brutal,
              ),
            ),
          ),
          Expanded(
            child: RaftMemberGraphPageBody(
              child: RaftMemberGraphView(
                data: data,
                loading: loading,
                error: error,
                sectionLabel: widget.sectionLabel,
                avatar: avatar,
                onRefresh: () => unawaited(load()),
                nodeWrapper: (context, member, node) => ProfilePreviewHoverCard(
                  controller: w,
                  agent: member.agent,
                  id: member.id,
                  child: node,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
