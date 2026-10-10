import 'package:flutter/widgets.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/upload_mime.dart';
import '../data/workspace_controller.dart';

// Web MessageInput pending attachments (SortableAttachment + failed-upload
// rows) over the controller's per-draft-scope uploads. Presentation is
// raft_ui's `RaftComposerAttachments`; this file only maps upload state.

/// Web `isBillingUploadQuotaError`.
bool isBillingUploadQuotaError(String? error) =>
    error != null && error.contains('Monthly file upload quota exceeded');

/// The view model of one draft, with fixed copy localized.
RaftComposerAttachment composerAttachmentFor(
  BuildContext context,
  UploadDraft draft,
) {
  final status = draft.checking
      ? RaftComposerAttachmentStatus.checking
      : draft.error != null
      ? RaftComposerAttachmentStatus.failed
      : draft.id != null || draft.queued
      ? RaftComposerAttachmentStatus.ready
      : RaftComposerAttachmentStatus.uploading;
  final mime = draft.mimeType;
  return RaftComposerAttachment(
    id: '${draft.key}',
    name: draft.filename,
    mimeType: mime,
    preview: isPreviewableImageMime(mime) && draft.bytes.isNotEmpty
        ? draft.bytes
        : null,
    status: status,
    // Web clamps a live progress event to 1..99 and shows "Uploading" at 0.
    progress: draft.progress > 0
        ? (draft.progress * 100).round().clamp(1, 99)
        : 0,
    error: draft.error == null ? null : raftText(context, draft.error!),
    canRetry: draft.canRetry,
    quotaBlocked: isBillingUploadQuotaError(draft.error),
  );
}

/// The `ComposerAttachments` slot for the composer of [thread]'s scope, or
/// null while nothing is pending.
Widget? composerAttachmentsFor(
  BuildContext context,
  WorkspaceController w, {
  required bool thread,
  required ValueChanged<UploadDraft> onPreview,
}) {
  final drafts = w.uploads(thread: thread);
  if (drafts.isEmpty) return null;
  final byId = {
    for (final draft in drafts) composerAttachmentFor(context, draft).id: draft,
  };
  return RaftComposerAttachments(
    items: [for (final draft in drafts) composerAttachmentFor(context, draft)],
    onRemove: (item) {
      final draft = byId[item.id];
      if (draft != null) w.removeUpload(draft, thread: thread);
    },
    onRetry: (item) {
      final draft = byId[item.id];
      if (draft != null) w.retryUpload(draft, thread: thread);
    },
    onPreview: (item) {
      final draft = byId[item.id];
      if (draft != null) onPreview(draft);
    },
  );
}

/// Web `message.composer.*` title for the send action while files are not
/// sendable, or null when none applies.
String? composerSendBlockTitle(BuildContext context, List<UploadDraft> drafts) {
  if (drafts.any((d) => d.checking)) {
    return raftText(context, 'Checking attachments…');
  }
  if (drafts.any((d) => d.error == null && d.id == null && !d.queued)) {
    return raftText(context, 'Uploading attachments…');
  }
  if (drafts.any((d) => d.error != null)) {
    return raftText(context, 'Retry or remove failed attachments');
  }
  return null;
}

/// Web `handleSubmit`: the notice a blocked send leaves in the banner.
String? composerSendBlockNotice(
  BuildContext context,
  List<UploadDraft> drafts,
) {
  if (drafts.any((d) => d.checking)) {
    return raftText(
      context,
      'Wait for attachment checks to finish before sending.',
    );
  }
  if (drafts.any((d) => d.error == null && d.id == null && !d.queued)) {
    return raftText(
      context,
      'Wait for attachments to finish uploading before sending.',
    );
  }
  if (drafts.any((d) => d.error != null)) {
    return raftText(
      context,
      'Remove or retry failed attachments before sending.',
    );
  }
  return null;
}
