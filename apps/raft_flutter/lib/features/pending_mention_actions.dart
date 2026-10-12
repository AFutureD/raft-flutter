// Web MessageInput.tsx pending-mention handling: after a send whose receipt
// carries `pendingMentionActions`, the composer shows
// PendingMentionActionStrip; Add / Notify call
// `POST /messages/mention-actions/execute`, a success marks the row
// (Added / Queued), fades it at 450ms and removes it at 750ms; Ignore removes
// it immediately.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'composer_attachments_view.dart';
import 'public_avatar_url.dart';

class PendingMentionActions extends StatefulWidget {
  const PendingMentionActions({
    super.key,
    required this.controller,
    this.thread = false,
  });
  final WorkspaceController controller;
  final bool thread;
  @override
  State<PendingMentionActions> createState() => _PendingMentionActionsState();
}

class _PendingMentionActionsState extends State<PendingMentionActions> {
  WorkspaceController get w => widget.controller;
  final state = <String, RaftPendingMentionState>{};
  final executing = <String, RaftPendingMentionState>{};
  final removing = <String>{};
  final timers = <String, List<Timer>>{};
  String? notice;

  @override
  void dispose() {
    for (final list in timers.values) {
      for (final timer in list) {
        timer.cancel();
      }
    }
    super.dispose();
  }

  void clearLocal(String id) {
    for (final timer in timers.remove(id) ?? const <Timer>[]) {
      timer.cancel();
    }
    state.remove(id);
    executing.remove(id);
    removing.remove(id);
  }

  void remove(String id) {
    clearLocal(id);
    w.dismissPendingMention(id, thread: widget.thread);
  }

  void scheduleRemoval(String id, RaftPendingMentionState outcome) {
    for (final timer in timers.remove(id) ?? const <Timer>[]) {
      timer.cancel();
    }
    setState(() => state[id] = outcome);
    timers[id] = [
      Timer(const Duration(milliseconds: 450), () {
        if (mounted) setState(() => removing.add(id));
      }),
      Timer(const Duration(milliseconds: 750), () {
        if (mounted) remove(id);
      }),
    ];
  }

  Future<void> mark(List<String> ids, RaftPendingMentionState outcome) async {
    setState(() {
      notice = null;
      for (final id in ids) {
        executing[id] = outcome;
      }
    });
    try {
      final ok = await w.executeMentionActions(
        outcome == RaftPendingMentionState.added ? 'add' : 'notify',
        ids,
      );
      if (!mounted) return;
      for (final id in ids.where(ok.contains)) {
        scheduleRemoval(id, outcome);
      }
      if (ok.length < ids.length) {
        setState(
          () => notice = raftText(context, 'Mention action failed. Try again.'),
        );
      }
    } catch (e) {
      if (mounted) setState(() => notice = '$e');
    } finally {
      if (mounted) {
        setState(() {
          for (final id in ids) {
            executing.remove(id);
          }
        });
      }
    }
  }

  Widget? avatar(Map<String, dynamic> row) {
    final url = row['targetAvatarUrl'];
    final type = row['targetType'];
    if ((type != 'agent' && type != 'user') || url is! String || url.isEmpty) {
      return null;
    }
    final pixel = url.startsWith('pixel:') ? url.substring(6) : null;
    final agent = type == 'agent';
    return RaftAvatar(
      name: '${row['targetHandle']}',
      size: 20,
      kind: agent ? RaftAvatarKind.agent : RaftAvatarKind.human,
      mountedContext: RaftMountedAvatarContext.compactList,
      content: RaftAvatarContent(
        name: '${row['targetHandle']}',
        kind: agent ? RaftAvatarContentKind.agent : RaftAvatarContentKind.human,
        pixelKey: pixel,
        uploadedUrl: pixel == null
            ? raftPublicAvatarUrl(w.client.origin, url)
            : null,
        fallback: RaftMountedAvatarFallback(
          avatarContext: RaftMountedAvatarContext.compactList,
          identity: agent
              ? RaftMountedAvatarIdentity.agent
              : RaftMountedAvatarIdentity.human,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: w,
    builder: (context, _) {
      final rows = w.pendingMentionsFor(thread: widget.thread);
      if (rows.isEmpty) return const SizedBox.shrink();
      final actions = [
        for (final row in rows)
          RaftPendingMention(
            resolutionId: row['resolutionId'] as String,
            targetType: row['targetType'] as String,
            targetHandle: '${row['targetHandle'] ?? ''}',
            availableActions: [
              for (final a in row['availableActions'] as List) '$a',
            ],
            avatar: avatar(row),
          ),
      ];
      return RaftPendingMentionSlot(
        notice: notice,
        strip: RaftPendingMentionActionStrip(
          actions: actions,
          channelName: w.channel?.name ?? '',
          state: state,
          executing: executing,
          removing: removing,
          onMark: (id, outcome) => mark([id], outcome),
          onAddAll: (ids) => mark(ids, RaftPendingMentionState.added),
          onDismiss: (id) => setState(() => remove(id)),
        ),
      );
    },
  );
}

/// MessageInput slots above the composer card, in Web order: the error
/// `Banner`, then the PendingMentionActionStrip.
Widget? raftComposerAccessory(
  BuildContext context,
  WorkspaceController w, {
  bool thread = false,
}) {
  final error = w.composerErrorFor(thread: thread);
  // Shared content added before its destination was re-checked: the check
  // refused it. The draft and files stay; Send is off (chat_view `canSend`).
  final shared = w.shareNoticeFor(thread: thread);
  // Web `billingUploadQuotaError`: the quota failure keeps its chip and
  // leaves the message in its own banner.
  final quota = w
      .uploads(thread: thread)
      .where((d) => isBillingUploadQuotaError(d.error))
      .map((d) => d.error!)
      .firstOrNull;
  final mentions = w.pendingMentionsFor(thread: thread).isNotEmpty;
  // Web order: error, quota, delivery warning (DM), unresolved mentions
  // (channel), then the strip. Both warnings carry a dismiss X.
  final warnings = w.sendWarningsFor(thread: thread);
  final dm = !thread && w.channel?.type == 'dm';
  final stopped = dm && warnings.agentStopped;
  final unresolved = !dm && warnings.unresolved.isNotEmpty;
  if (error == null &&
      shared == null &&
      quota == null &&
      !stopped &&
      !unresolved &&
      !mentions) {
    return null;
  }
  final banners = <Widget>[
    if (shared != null)
      RaftComposerNotice(
        key: const Key('shared-destination-notice'),
        message: raftText(context, shared),
      ),
    if (error != null) RaftComposerNotice(message: error),
    if (quota != null) RaftComposerNotice(message: quota),
    if (stopped)
      RaftComposerNotice(
        message: raftText(
          context,
          'Message sent, but this agent is stopped and was not notified.',
        ),
        dismissLabel: raftText(context, 'Dismiss delivery warning'),
        onDismiss: () => w.dismissSendWarnings(thread: thread),
      ),
    if (unresolved)
      RaftComposerNotice(
        message: raftFormat(
          context,
          'Not notified: {handles}. Select a person or agent from the mention picker and try again if needed.',
          {'handles': warnings.unresolved.join(', ')},
        ),
        dismissLabel: raftText(context, 'Dismiss unnotified mention warning'),
        onDismiss: () => w.dismissSendWarnings(thread: thread),
      ),
  ];
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < banners.length; i++) ...[
        if (i > 0) const RaftComposerGap(),
        banners[i],
      ],
      if (banners.isNotEmpty && mentions) const RaftComposerGap(),
      if (mentions) PendingMentionActions(controller: w, thread: thread),
    ],
  );
}
