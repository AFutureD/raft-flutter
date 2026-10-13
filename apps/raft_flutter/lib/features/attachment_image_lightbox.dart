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
/// with the gallery counter and the header [actions], stage and thumbnails;
/// no previous / next arrows, owner decision 2026-10-13). Wide layouts carry Download in the header; phone layouts
/// carry none (the stage's long-press menu saves and shares).
class AttachmentImageLightbox extends StatelessWidget {
  const AttachmentImageLightbox({
    super.key,
    required this.title,
    required this.zoom,
    required this.onClose,
    required this.child,
    this.actions = const [],
    this.shortcuts = const {},
    this.gallery,
    this.page = false,
  });
  final String title;
  final TransformationController zoom;
  final VoidCallback onClose;
  final Widget child;
  final List<Widget> actions;
  final Map<ShortcutActivator, VoidCallback> shortcuts;
  final AttachmentLightboxGallery? gallery;
  final bool page;

  @override
  Widget build(BuildContext context) {
    final g = gallery != null && gallery!.count > 1 ? gallery : null;
    return RaftAttachmentLightbox(
      page: page,
      title: title,
      titleBold: true,
      shortcuts: shortcuts,
      onResetZoom: () => zoom.value = Matrix4.identity(),
      onClose: onClose,
      meta: g == null
          ? null
          : RaftLightboxCounter(index: g.index, count: g.count),
      actions: actions,
      overlay: g == null
          ? null
          : RaftLightboxThumbnails(
              thumbnails: g.thumbnails,
              index: g.index,
              onSelect: g.onSelect,
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
    this.onReady,
  });

  /// Called once the full-resolution original is on screen (or failed): the
  /// viewer then preloads this page's neighbours.
  final VoidCallback? onReady;

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
  State<AttachmentLightboxImage> createState() =>
      AttachmentLightboxImageState();
}

class AttachmentLightboxImageState extends State<AttachmentLightboxImage> {
  WorkspaceAttachmentImageLease? lease;
  AttachmentTransferView? transfer;
  ImageProvider? full;
  bool failed = false;

  /// Completes when the load under way ends (never errors); a save of this
  /// page's original waits for it instead of fetching the bytes again.
  Future<void> settled = Future<void>.value();

  @override
  void initState() {
    super.initState();
    full = widget.image;
    if (widget.acquire != null) {
      settled = load();
      unawaited(settled);
    } else {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => widget.onReady?.call(),
      );
    }
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
      return;
    }
    try {
      final provider = await next.lease.ready;
      if (mounted && identical(lease, next)) setState(() => full = provider);
    } catch (_) {
      if (mounted && identical(lease, next)) setState(() => failed = true);
    }
    if (mounted && identical(lease, next)) widget.onReady?.call();
  }

  /// Tap on the failed chip: fetch the original again.
  void retry() {
    lease?.release(discard: true);
    lease = null;
    transfer = null;
    setState(() => failed = false);
    settled = load();
    unawaited(settled);
  }

  @override
  void dispose() {
    _unwatchDecodedSize();
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
        return Center(
          child: SizedBox(
            width: width,
            height: height,
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
                  RaftImageTransferOverlay.failed(inset: 10, onRetry: retry)
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
                // Web ImageLightbox: `common.lightbox.failedToLoad`.
                message: 'Failed to load image',
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
    _watchDecodedSize();
    // `max-h-full max-w-full object-contain`: natural size, shrunk to fit
    // the stage, never enlarged.
    //
    // Source ImageLightbox: "Empty-stage clicks close the lightbox. After
    // zoom/pan ... also guard against stage-target clicks that land inside the
    // transformed image." A tap (not a pan / pinch) outside the painted image
    // closes the route; the tap recognizer loses the arena to a drag.
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        key: const ValueKey('lightbox-stage'),
        behavior: HitTestBehavior.translucent,
        onTapUp: (details) {
          if (!imageContains(details.localPosition, constraints.biggest)) {
            unawaited(Navigator.maybePop(context));
          }
        },
        // Pan only while zoomed in: at fit scale a horizontal drag belongs to
        // the viewer's PageView (swipe to the next image).
        child: ListenableBuilder(
          listenable: widget.zoom,
          builder: (context, child) => InteractiveViewer(
            transformationController: widget.zoom,
            panEnabled: widget.zoom.value.getMaxScaleOnAxis() > 1.001,
            child: child!,
          ),
          child: Image(
            image: provider,
            key: widget.imageKey,
            fit: BoxFit.scaleDown,
            gaplessPlayback: true,
            errorBuilder: (context, _, _) => RaftLightboxFailure(
              title: widget.title,
              message: 'Failed to load image',
            ),
          ),
        ),
      ),
    );
  }

  ImageStream? _sizeStream;
  ImageStreamListener? _sizeListener;
  Size? decoded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchDecodedSize();
  }

  @override
  void didUpdateWidget(AttachmentLightboxImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _watchDecodedSize();
  }

  void _watchDecodedSize() {
    final provider = full;
    if (provider == null) return;
    final stream = provider.resolve(createLocalImageConfiguration(context));
    if (_sizeStream?.key == stream.key) return;
    _unwatchDecodedSize();
    final listener = ImageStreamListener((info, _) {
      final image = info.image;
      decoded = Size(image.width.toDouble(), image.height.toDouble());
    });
    stream.addListener(listener);
    _sizeStream = stream;
    _sizeListener = listener;
  }

  void _unwatchDecodedSize() {
    final listener = _sizeListener;
    if (listener != null) _sizeStream?.removeListener(listener);
    _sizeStream = null;
    _sizeListener = null;
  }

  /// Whether [point] (stage coordinates) lands on the painted image: its
  /// `scaleDown` box centred in [stage], mapped through the zoom / pan
  /// transform. Without a known pixel size every point counts as the image
  /// (never closes by accident).
  @visibleForTesting
  bool imageContains(Offset point, Size stage) {
    final natural = decoded ?? widget.imageSize;
    if (natural == null || natural.isEmpty) return true;
    final scale = [
      1.0,
      stage.width / natural.width,
      stage.height / natural.height,
    ].reduce((a, b) => a < b ? a : b);
    final size = natural * scale;
    final box = Rect.fromCenter(
      center: stage.center(Offset.zero),
      width: size.width,
      height: size.height,
    );
    final inverse = Matrix4.tryInvert(widget.zoom.value);
    if (inverse == null) return true;
    final local = MatrixUtils.transformPoint(inverse, point);
    return box.contains(local);
  }
}
