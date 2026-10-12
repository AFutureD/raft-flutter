import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'attachment_transfer_view.dart';

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
    this.page = false,
  });
  final String title;
  final TransformationController zoom;
  final VoidCallback onClose;
  final Future<void> Function()? onDownload;
  final Widget child;
  final AttachmentLightboxGallery? gallery;
  final bool page;

  @override
  Widget build(BuildContext context) {
    final g = gallery != null && gallery!.count > 1 ? gallery : null;
    return RaftAttachmentLightbox(
      page: page,
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
/// The list preview (thumbnail) stands in until it is ready (Web shows the
/// thumbnail); a thin bar along its bottom edge and a size chip show the
/// original's download. Without a thumbnail a placeholder with the image's
/// aspect ratio takes its place. Leaving the viewer cancels the download.
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
    this.transferTotalHint,
    this.imageSize,
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

  /// The original's size in bytes; stands in for a missing Content-Length.
  final int? transferTotalHint;

  /// The original's pixel size (attachment `width` / `height`); the stand-in
  /// takes this aspect ratio so the stage does not jump when the image lands.
  final Size? imageSize;
  @override
  State<AttachmentLightboxImage> createState() => AttachmentLightboxImageState();
}

class AttachmentLightboxImageState extends State<AttachmentLightboxImage> {
  WorkspaceAttachmentImageLease? lease;
  AttachmentTransferView? transfer;
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
      // A retry reaches here after the frame; initState must not setState.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
      return;
    }
    lease = next;
    transfer = AttachmentTransferView(next.lease.progress);
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

  /// Tap on a failed stage: fetch the original again.
  void retry() {
    lease?.release(discard: true);
    lease = null;
    transfer = null;
    setState(() => failed = false);
    unawaited(load());
  }

  @override
  void dispose() {
    // The full-resolution bitmap is not kept once the lightbox closes; its
    // bytes stay in the persistent store for the next open. Releasing the
    // last consumer of an in-flight download cancels it.
    lease?.release(discard: true);
    lease = null;
    super.dispose();
  }

  /// The stand-in stage: the thumbnail (or a neutral box) in the original's
  /// aspect ratio, never larger than the original, with the bottom-edge bar.
  Widget stage(BuildContext context, ImageProvider? thumbnail) {
    final natural = widget.imageSize;
    final aspect = natural == null ? 4 / 3 : natural.width / natural.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        final max = constraints.biggest;
        var width = max.width.isFinite ? max.width : 320.0;
        var height = max.height.isFinite ? max.height : width / aspect;
        if (width / height > aspect) {
          width = height * aspect;
        } else {
          height = width / aspect;
        }
        if (natural != null && natural.width < width) {
          width = natural.width;
          height = natural.height;
        }
        final retryable = failed;
        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: retryable ? retry : null,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  thumbnail == null
                      ? const RaftTransferPlaceholder()
                      : Image(
                          image: thumbnail,
                          key: widget.imageKey,
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                        ),
                  if (failed)
                    const RaftImageTransferOverlay.failed(inset: 10)
                  else if (transfer != null)
                    RaftImageTransferOverlay(
                      progress: transfer!,
                      fallbackTotal: widget.transferTotalHint,
                      labelPrefix: thumbnail == null
                          ? null
                          : raftText(context, 'Original image'),
                      inset: 10,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = full;
    if (provider == null) {
      final thumbnail = widget.placeholder;
      if (failed && thumbnail == null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RaftLightboxFailure(
                title: widget.title,
                message: 'Preview unavailable. Download the original file.',
              ),
              if (widget.acquire != null)
                RaftTextButton(
                  label: raftText(context, 'Retry'),
                  glyph: RaftGlyph.refreshCw,
                  onPressed: retry,
                ),
            ],
          ),
        );
      }
      return stage(context, thumbnail);
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
