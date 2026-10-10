import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';

/// The image lightbox route content: Web ImageLightbox for one image.
class AttachmentImageLightbox extends StatelessWidget {
  const AttachmentImageLightbox({
    super.key,
    required this.title,
    required this.zoom,
    required this.onClose,
    required this.onDownload,
    required this.child,
  });
  final String title;
  final TransformationController zoom;
  final VoidCallback onClose;
  final Future<void> Function()? onDownload;
  final Widget child;

  @override
  Widget build(BuildContext context) => RaftAttachmentLightbox(
    title: title,
    titleBold: true,
    onResetZoom: () => zoom.value = Matrix4.identity(),
    onClose: onClose,
    footer: RaftTextButton(
      label: 'Download original',
      glyph: RaftGlyph.download,
      onPressed: onDownload,
      variant: RaftControlVariant.ghost,
    ),
    child: child,
  );
}

/// Lightbox body: the full-resolution original, decoded only while open.
/// The list preview stands in until it is ready (Web shows the thumbnail).
class AttachmentLightboxImage extends StatefulWidget {
  const AttachmentLightboxImage({
    super.key,
    required this.imageKey,
    required this.zoom,
    this.acquire,
    this.image,
    required this.placeholder,
    required this.previewFailed,
  });
  final Key imageKey;
  final TransformationController zoom;

  /// Leases the full-resolution original; null when [image] is already known.
  final WorkspaceAttachmentImageLease Function()? acquire;

  /// An already decoded original (tests and callers that hold the bitmap).
  final ImageProvider? image;
  final ImageProvider? placeholder;
  final bool previewFailed;
  @override
  State<AttachmentLightboxImage> createState() => AttachmentLightboxImageState();
}

class AttachmentLightboxImageState extends State<AttachmentLightboxImage> {
  WorkspaceAttachmentImageLease? lease;
  ImageProvider? full;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    full = widget.image;
    if (widget.acquire != null) unawaited(load());
  }

  Future<void> load() async {
    final WorkspaceAttachmentImageLease next;
    try {
      next = widget.acquire!();
    } catch (_) {
      failed = true;
      return;
    }
    lease = next;
    final ready = next.lease.value;
    if (ready != null) {
      full = ready;
      return;
    }
    try {
      final provider = await next.lease.ready;
      if (mounted && identical(lease, next)) setState(() => full = provider);
    } catch (_) {
      if (mounted && identical(lease, next)) setState(() => failed = true);
    }
  }

  @override
  void dispose() {
    // The full-resolution bitmap is not kept once the lightbox closes; its
    // bytes stay in the persistent store for the next open.
    lease?.release(discard: true);
    lease = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = full ?? widget.placeholder;
    const unavailable = Text(
      'Preview unavailable. Download the original file.',
    );
    return Center(
      child: provider == null
          ? failed || widget.previewFailed
                ? unavailable
                : const RaftSpinner(inverse: true)
          : InteractiveViewer(
              transformationController: widget.zoom,
              child: Image(
                image: provider,
                key: widget.imageKey,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => unavailable,
              ),
            ),
    );
  }
}
