// Web ChatPanel footer states (components/message/ChatPanel.tsx, the
// `ConversationPanelFooter` chain): which of composer / archived notice /
// joint-locked banner / guest read-only banner / Join CTA the channel shows,
// the joint over-limit grace banner above it, and their recipes.
//
// The read-only quota branch (`isReadOnlyByQuota`) is absent on purpose:
// shared PLAN_CONFIG maxChannels is -1 for every plan, so Web never reaches it.
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/source_time_formatter.dart';
import '../data/workspace_controller.dart';

enum ChannelFooterKind { composer, archived, jointLocked, guestReadOnly, join }

/// Source isJointChannelReadOnly: the server flag, or the grace deadline passed.
bool jointChannelReadOnly(Map<String, dynamic> channel, DateTime now) {
  if (channel['type'] != 'joint') return false;
  if (channel['jointBillingLocked'] == true) return true;
  final deadline = DateTime.tryParse('${channel['jointOverLimitGraceEndsAt']}');
  return deadline != null && !now.isBefore(deadline);
}

/// Source jointChannelGraceEndsAt: the deadline while over the limit and not
/// yet read-only; null otherwise.
String? jointChannelGraceEndsAt(Map<String, dynamic> channel, DateTime now) {
  if (channel['type'] != 'joint') return null;
  final ends = channel['jointOverLimitGraceEndsAt'];
  if (ends is! String || ends.isEmpty) return null;
  return jointChannelReadOnly(channel, now) ? null : ends;
}

/// The footer a regular (non-thread) channel conversation shows, or null when
/// membership is not hydrated or the viewer may not join (Web renders nothing).
ChannelFooterKind? channelFooterKind(WorkspaceController w, DateTime now) {
  final channel = w.channel;
  if (channel == null) return null;
  final json = channel.json;
  if (channel.archived) return ChannelFooterKind.archived;
  if (jointChannelReadOnly(json, now)) return ChannelFooterKind.jointLocked;
  final guest = w.server?.string('role') == 'guest';
  final implicitlyJoined = const ['dm', 'thread'].contains(channel.type);
  final joined = implicitlyJoined ? true : channel.joined;
  final guestJoinable = json['guestJoinable'] == true;
  if (guest && (joined || !guestJoinable)) {
    return ChannelFooterKind.guestReadOnly;
  }
  if (joined) return ChannelFooterKind.composer;
  return ChannelFooterKind.join;
}

/// `border-t border-line-muted bg-layer-panel` / brutal `border-t-2 border-black bg-white`.
BoxDecoration _footerDecoration(RaftTokens t, {Color? color}) => BoxDecoration(
  color: color ?? t.panel,
  border: Border(
    top: BorderSide(
      color: t.brutal ? Colors.black : t.colors['line-muted']!,
      width: t.brutal ? 2 : 1,
    ),
  ),
);

/// The joint over-limit grace banner (`px-3 pt-3` host) above the footer.
class ChannelGraceBanner extends StatelessWidget {
  const ChannelGraceBanner({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      key: const ValueKey('joint-over-limit-grace-banner'),
      decoration: _footerDecoration(t),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: RaftBanner(
        textAlign: TextAlign.center,
        description: message,
      ),
    );
  }
}

/// A warning Banner footer with an optional underlined action link
/// (`justify-center text-center font-bold`).
class ChannelBannerFooter extends StatelessWidget {
  const ChannelBannerFooter({
    super.key,
    required this.message,
    this.linkLabel,
    this.onLink,
  });
  final String message;
  final String? linkLabel;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      decoration: _footerDecoration(t),
      padding: const EdgeInsets.all(12),
      child: RaftBanner(
        textAlign: TextAlign.center,
        description: message,
        descriptionTailWeight: FontWeight.w700,
        descriptionTail: linkLabel == null
            ? null
            : (label: linkLabel!, onPressed: onLink ?? () {}),
      ),
    );
  }
}

/// `This channel is archived.` + `Unarchive` on `bg-warning-soft` /
/// brutal `bg-brutal-orange/20`.
class ChannelArchivedFooter extends StatelessWidget {
  const ChannelArchivedFooter({
    super.key,
    required this.message,
    this.linkLabel,
    this.onLink,
  });
  final String message;
  final String? linkLabel;
  final VoidCallback? onLink;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final color = t.brutal ? Colors.black : t.colors['warning-strong'];
    final text = RaftTypography.heading(t, size: 14, line: 20, color: color);
    return Container(
      key: const ValueKey('channel-archived-footer'),
      decoration: _footerDecoration(
        t,
        color: t.brutal
            ? t.colors['color-brutal-orange']!.withValues(alpha: .2)
            : t.colors['warning-soft'],
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        spacing: 8,
        children: [
          Flexible(child: Text(raftText(context, message), style: text)),
          if (linkLabel != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onLink,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Text(
                  raftText(context, linkLabel!),
                  style: text.copyWith(
                    color: t.brutal ? Colors.black : t.strong,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// `Join #name` accent button (+ the guest explanation line).
class ChannelJoinFooter extends StatelessWidget {
  const ChannelJoinFooter({
    super.key,
    required this.channelName,
    required this.onJoin,
    this.explanation,
  });
  final String channelName;
  final VoidCallback onJoin;
  final String? explanation;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Container(
      key: const ValueKey('channel-join-footer'),
      decoration: _footerDecoration(t),
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          RaftRecipeButton(
            variant: RaftButtonRecipeVariant.accent,
            size: RaftButtonRecipeSize.md,
            glyph: RaftGlyph.logIn,
            glyphSize: 14,
            gap: 6,
            expand: true,
            fontWeight: FontWeight.w700,
            label: raftFormat(context, 'Join #{channel}', {
              'channel': channelName,
            }),
            onPressed: onJoin,
          ),
          if (explanation != null)
            Text(
              raftText(context, explanation!),
              textAlign: TextAlign.center,
              style: RaftTypography.heading(
                t,
                size: 12,
                line: 16,
                weight: FontWeight.w500,
                color: t.brutal ? Colors.black.withValues(alpha: .6) : t.muted,
              ),
            ),
        ],
      ),
    );
  }
}

/// Formats [ends] for the grace banner copy.
String channelGraceDeadlineLabel(SourceTimeFormatter formatter, String ends) =>
    formatter.mediumDateTime(ends);
