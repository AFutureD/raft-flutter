import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';

/// Gallery state of the lightbox: the message's raster images (Web
/// `images` / `currentIndex`).
class AttachmentLightboxGallery {
  const AttachmentLightboxGallery({
    required this.index,
    required this.thumbnails,
    required this.onSelect,
  });
  final int index;
  final List<ImageProvider?> thumbnails;
  final ValueChanged<int> onSelect;
  int get count => thumbnails.length;
}

/// The image lightbox route content: Web `ImageLightbox` frame (title bar
/// with the gallery counter and download, stage, arrows and thumbnails).
class AttachmentImageLightbox extends StatelessWidget {
  const AttachmentImageLightbox({
    super.key,
    required this.title,
    required this.zoom,
    required this.onClose,
    required this.onDownload,
    required this.child,
    this.gallery,
  });
  final String title;
  final TransformationController zoom;
  final VoidCallback onClose;
  final Future<void> Function()? onDownload;
  final Widget child;
  final AttachmentLightboxGallery? gallery;

  @override
  Widget build(BuildContext context) {
    final g = gallery != null && gallery!.count > 1 ? gallery : null;
    return RaftAttachmentLightbox(
      title: title,
      titleBold: true,
      onResetZoom: () => zoom.value = Matrix4.identity(),
      onClose: onClose,
      meta: g == null
          ? null
          : RaftLightboxCounter(index: g.index, count: g.count),
      actions: [
        RaftLightboxIconAction(
          key: const ValueKey('attachment-download'),
          glyph: RaftGlyph.download,
          label: 'Download',
          onPressed: onDownload,
        ),
      ],
      overlay: g == null
          ? null
          : Stack(
              children: [
                RaftLightboxArrows(
                  index: g.index,
                  count: g.count,
                  onSelect: g.onSelect,
                ),
                RaftLightboxThumbnails(
                  thumbnails: g.thumbnails,
                  index: g.index,
                  onSelect: g.onSelect,
                ),
              ],
            ),
      child: child,
    );
  }
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
    this.title = '',
  });

  /// File name of the failure card.
  final String title;
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
    if (provider == null) {
      return failed || widget.previewFailed
          ? RaftLightboxFailure(
              title: widget.title,
              message: 'Preview unavailable. Download the original file.',
            )
          : const RaftLightboxLoading();
    }
    // `max-h-full max-w-full object-contain`: natural size, shrunk to fit
    // the stage, never enlarged.
    return InteractiveViewer(
      transformationController: widget.zoom,
      child: Image(
        image: provider,
        key: widget.imageKey,
        fit: BoxFit.scaleDown,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const Center(
          child: Text('Preview unavailable. Download the original file.'),
        ),
      ),
    );
  }
}
