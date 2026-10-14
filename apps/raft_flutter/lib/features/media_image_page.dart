import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import 'attachment_image_zoom.dart';
import 'attachment_transfer_view.dart';
import 'media_items.dart';

/// Gallery state of the lightbox: the message's media (Web `images` /
/// `currentIndex`, plus videos behind the media-browser flag).
class AttachmentLightboxGallery {
  const AttachmentLightboxGallery({
    required this.index,
    required this.thumbnails,
    required this.onSelect,
    this.items,
  });
  final int index;
  final List<ImageProvider?> thumbnails;
  final ValueChanged<int> onSelect;

  /// Kinds and durations of the pages (video thumbnails carry a badge);
  /// without them every page is an image.
  final List<MediaItem>? items;
  int get count => thumbnails.length;
}

/// The media browser frame around the stage. Wide layouts keep Web's
/// `ImageLightbox` frame: title bar (kind glyph, bold filename, sub-line,
/// gallery counter, [actions]), stage and the strip in a reserved band; no
/// previous / next arrows (owner decision 2026-10-13). Phone layouts are the
/// black immersive stage: [mediaActions] (Share, More) in the top bar, tap
/// toggles the chrome, a drag down dismisses.
class AttachmentImageLightbox extends StatelessWidget {
  const AttachmentImageLightbox({
    super.key,
    required this.title,
    required this.zoom,
    required this.onClose,
    required this.child,
    this.subtitle,
    this.kind,
    this.actions = const [],
    this.mediaActions = const [],
    this.shortcuts = const {},
    this.gallery,
    this.page = false,
    this.chrome,
    this.caption,
    this.dismissEnabled = true,
    this.onDismissDrag,
  });
  final String title;
  final String? subtitle;

  /// Kind of the current page: the wide header's glyph (Web's image lightbox
  /// header has none, so a null kind draws none).
  final MediaKind? kind;
  final TransformationController zoom;
  final VoidCallback onClose;
  final Widget child;

  /// Wide header actions (Download).
  final List<Widget> actions;

  /// Phone top-bar actions (Share, More, Download without a share sheet).
  final List<RaftMediaAction> mediaActions;
  final Map<ShortcutActivator, VoidCallback> shortcuts;
  final AttachmentLightboxGallery? gallery;
  final bool page;

  /// Phone chrome visibility (tap toggles it); wide layouts ignore it.
  final ValueListenable<bool>? chrome;
  final String? caption;
  final bool dismissEnabled;

  /// A phone drag-to-dismiss began or ended.
  final ValueChanged<bool>? onDismissDrag;

  @override
  Widget build(BuildContext context) {
    final g = gallery != null && gallery!.count > 1 ? gallery : null;
    final strip = g == null
        ? null
        : RaftMediaStrip(
            compact: page,
            index: g.index,
            onSelect: g.onSelect,
            items: [
              for (var i = 0; i < g.count; i++)
                RaftMediaStripItem(
                  thumbnail: g.thumbnails[i],
                  video: g.items?[i].isVideo ?? false,
                  duration: g.items?[i].duration,
                  label: raftFormat(
                    context,
                    (g.items?[i].isVideo ?? false)
                        ? 'Video {index} of {count}'
                        : 'Image {index} of {count}',
                    {'index': i + 1, 'count': g.count},
                  ),
                ),
            ],
          );
    final counter = g == null
        ? null
        : RaftLightboxCounter(index: g.index, count: g.count);
    if (page) {
      return RaftMediaImmersiveShell(
        title: title,
        subtitle: subtitle,
        chrome: chrome ?? const _Always(),
        onClose: onClose,
        counter: counter,
        actions: mediaActions,
        strip: strip,
        caption: caption,
        shortcuts: shortcuts,
        dismissEnabled: dismissEnabled,
        onDismissDrag: onDismissDrag,
        child: child,
      );
    }
    return RaftAttachmentLightbox(
      title: title,
      subtitle: subtitle,
      leading: kind == null
          ? null
          : RaftIcon(
              kind == MediaKind.video ? RaftGlyph.video : RaftGlyph.image,
              size: 16,
            ),
      titleBold: true,
      shortcuts: shortcuts,
      onResetZoom: () => zoom.value = Matrix4.identity(),
      onClose: onClose,
      meta: counter,
      actions: actions,
      overlayInset: strip == null ? 0 : raftMediaDesktopStripBand,
      overlay: strip,
      child: child,
    );
  }
}

class _Always extends ValueListenable<bool> {
  const _Always();
  @override
  bool get value => true;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
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
    this.settledBefore = false,
    this.heroTag,
    this.onTap,
    this.onZoomGesture,
    this.closeOnTapOutside = true,
  });

  /// Tag of the picture's Hero (card to stage); null leaves it out.
  final Object? heroTag;

  /// A single tap on the stage (phone: toggles the chrome).
  final VoidCallback? onTap;

  /// A zoom gesture began (phone: hides the chrome).
  final VoidCallback? onZoomGesture;

  /// Web: a tap outside the painted image closes (desktop). A phone's tap
  /// toggles the chrome instead.
  final bool closeOnTapOutside;

  /// The viewer showed this page's original already: paging back to it does
  /// not bring the progress chip back.
  final bool settledBefore;

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

  /// The progress chip waits [progressDelay] after the load starts: a load
  /// that ends sooner (cache, neighbour, paging back) never flashes it.
  static const progressDelay = Duration(milliseconds: 300);
  bool progressShown = false;
  Timer? _progressTimer;

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
    if (ready == null && !widget.settledBefore) _startProgressDelay();
    if (ready != null) {
      full = ready;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onReady?.call();
      });
      return;
    }
    try {
      final provider = await next.lease.ready;
      _stopProgressDelay();
      if (mounted && identical(lease, next)) setState(() => full = provider);
    } catch (_) {
      _stopProgressDelay();
      if (mounted && identical(lease, next)) setState(() => failed = true);
    }
    if (mounted && identical(lease, next)) widget.onReady?.call();
  }

  void _startProgressDelay() {
    _progressTimer?.cancel();
    progressShown = false;
    _progressTimer = Timer(progressDelay, () {
      _progressTimer = null;
      if (mounted) setState(() => progressShown = true);
    });
  }

  void _stopProgressDelay() {
    _progressTimer?.cancel();
    _progressTimer = null;
    progressShown = false;
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
    _progressTimer?.cancel();
    lease?.release(discard: true);
    lease = null;
    super.dispose();
  }

  final surfaceKey = GlobalKey<ImageZoomSurfaceState>();

  /// Wraps the picture in the card-to-stage Hero.
  Widget hero(Widget picture, ImageProvider? shuttle) => widget.heroTag == null
      ? picture
      : RaftMediaHero(tag: widget.heroTag!, image: shuttle, child: picture);

  /// The stand-in stage: the thumbnail (or a neutral box) in the original's
  /// aspect ratio, never larger than the original, with the bottom-edge bar.
  Widget stage(BuildContext context, ImageProvider? thumbnail) {
    final natural = widget.imageSize;
    final aspect = natural == null ? 4 / 3 : natural.width / natural.height;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep clear of the thumbnail strip band, mirrored so the box stays
        // centred (and the size chip never lands under the strip).
        final inset = RaftLightboxStageInset.of(context);
        final max = constraints.biggest;
        var width = max.width.isFinite ? max.width : 320.0;
        var height = max.height.isFinite
            ? math.max(0.0, max.height - 2 * inset)
            : width / aspect;
        if (width / height > aspect) {
          width = height * aspect;
        } else {
          height = width / aspect;
        }
        if (natural != null && natural.width < width) {
          width = natural.width;
          height = natural.height;
        }
        final picture = thumbnail == null
            ? const RaftTransferPlaceholder(onDark: true)
            : hero(
                // ignore: raft_lints/avoid_raw_image_decode -- Lightbox stage images are leases decoded at screen size x zoom cap by the repository; the viewer keeps that bounded path.
                Image(
                  image: thumbnail,
                  key: widget.imageKey,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
                thumbnail,
              );
        // The stand-in is a stage member like the loaded original: the same
        // zoom surface (tap, double tap, pinch) and the same controller, so a
        // zoom made now carries over when the original replaces it. The
        // transfer chip and Retry stay outside the transform.
        return Stack(
          fit: StackFit.expand,
          children: [
            ImageZoomSurface(
              key: surfaceKey,
              controller: widget.zoom,
              natural: widget.imageSize,
              verticalInset: inset,
              onTapOutside: widget.closeOnTapOutside
                  ? () => unawaited(Navigator.maybePop(context))
                  : null,
              onTap: widget.onTap,
              onZoomGesture: widget.onZoomGesture,
              child: Center(
                child: SizedBox(width: width, height: height, child: picture),
              ),
            ),
            Center(
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (failed) ...[
                      RaftImageTransferOverlay.failed(
                        inset: 10,
                        onRetry: retry,
                      ),
                      // The red chip alone is easy to miss: a plain Retry
                      // button.
                      if (widget.acquire != null)
                        Center(
                          child: RaftTextButton(
                            key: const ValueKey('lightbox-retry'),
                            label: raftText(context, 'Retry'),
                            glyph: RaftGlyph.refreshCw,
                            onPressed: retry,
                          ),
                        ),
                    ] else if (transfer != null && progressShown)
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
          ],
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
    return ImageZoomSurface(
      key: surfaceKey,
      controller: widget.zoom,
      natural: decoded ?? widget.imageSize,
      verticalInset: RaftLightboxStageInset.of(context),
      onTapOutside: widget.closeOnTapOutside
          ? () => unawaited(Navigator.maybePop(context))
          : null,
      onTap: widget.onTap,
      onZoomGesture: widget.onZoomGesture,
      child: hero(
        // ignore: raft_lints/avoid_raw_image_decode -- Lightbox stage images are leases decoded at screen size x zoom cap by the repository; the viewer keeps that bounded path.
        Image(
          image: provider,
          key: widget.imageKey,
          fit: (decoded ?? widget.imageSize) == null
              ? BoxFit.scaleDown
              : BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, _, _) => RaftLightboxFailure(
            title: widget.title,
            message: 'Failed to load image',
          ),
        ),
        widget.placeholder ?? provider,
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
    final listener = ImageStreamListener((info, synchronous) {
      final image = info.image;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      // The stream hands every listener its own clone; only the size is kept.
      info.dispose();
      if (decoded == size) return;
      decoded = size;
      // A synchronous call happens while building; the build reads it next.
      if (!synchronous && mounted) setState(() {});
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
}
