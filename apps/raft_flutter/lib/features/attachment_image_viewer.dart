import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/attachment_image_repository.dart';
import '../data/workspace_controller.dart';
import '../platform/attachment_files.dart';
import '../platform/native_sharing.dart';
import 'attachment_image_lightbox.dart';
import 'attachment_image_loader.dart';
import 'attachment_transfers.dart';

/// The image viewer of a message's images (Web `ImageLightbox`): every
/// previewable image of the message, arrows / ArrowLeft / ArrowRight / swipe
/// between them (no wrap), the counter chip and thumbnail strip, zoom that
/// resets when the image changes.
///
/// Header actions follow the layout. Wide layouts carry Download (Web).
/// Phones carry none: a long press on the image opens the menu with
/// "Save to Photos / Gallery" and "Share" instead.
///
/// Each page loads its original on demand through the shared repository
/// (signed when it is not stored). Once the current page is ready, its two
/// neighbours are fetched once at display size (one image each side); nothing
/// further is signed ahead.
class AttachmentImageViewer extends StatefulWidget {
  const AttachmentImageViewer({
    super.key,
    required this.controller,
    required this.files,
    required this.sharing,
    required this.items,
    required this.initialIndex,
    required this.messageId,
    required this.authorized,
    required this.onClose,
    this.page = false,
    this.openerPlaceholder,
    this.openerPreviewFailed = false,
    this.progressRoute,
  });
  final WorkspaceController controller;
  final AttachmentFiles files;
  final NativeSharing sharing;

  /// Metadata of every previewable image of the message, in order.
  final List<Map<String, dynamic>> items;
  final int initialIndex;
  final String? messageId;
  final bool Function() authorized;
  final VoidCallback onClose;

  /// Phone page route (not the wide dialog).
  final bool page;

  /// The list preview of `items[initialIndex]`, standing in until its
  /// original is ready.
  final ImageProvider? openerPlaceholder;
  final bool openerPreviewFailed;

  /// The dialog that shows a picker download's progress.
  final AttachmentProgressRouteBuilder? progressRoute;

  @override
  State<AttachmentImageViewer> createState() => AttachmentImageViewerState();
}

class AttachmentImageViewerState extends State<AttachmentImageViewer> {
  late int index = widget.initialIndex.clamp(0, widget.items.length - 1);
  late final PageController pages = PageController(initialPage: index);
  final zooms = <int, TransformationController>{};
  final pageKeys = <int, GlobalKey<AttachmentLightboxImageState>>{};
  final _transfers = <int, AttachmentTransfers>{};
  final _thumbLeases = <int, WorkspaceAttachmentImageLease>{};
  final _thumbs = <int, ImageProvider>{};
  final _preloads = <int, WorkspaceAttachmentImageLease>{};
  bool zoomed = false;
  bool _disposed = false;

  WorkspaceController get w => widget.controller;
  Map<String, dynamic> item(int i) => widget.items[i];
  String ownerChannel(int i) =>
      attachmentOwnerChannel(w, item(i), widget.messageId);

  /// Phones: the long-press menu replaces the header actions.
  bool get phoneMenu =>
      widget.page &&
      (widget.files.gallerySupported || widget.sharing.supported);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadThumbnails());
  }

  /// One zoom / pan state per page; every one is disposed with the viewer.
  TransformationController zoomFor(int i) => zooms.putIfAbsent(
    i,
    () => TransformationController()..addListener(_zoomChanged),
  );

  void _zoomChanged() {
    final now = (zooms[index]?.value.getMaxScaleOnAxis() ?? 1) > 1.001;
    if (now != zoomed && mounted) setState(() => zoomed = now);
  }

  AttachmentTransfers transfersFor(int i) => _transfers.putIfAbsent(
    i,
    () => AttachmentTransfers(
      controller: w,
      files: widget.files,
      sharing: widget.sharing,
      metadata: item(i),
      ownerChannel: ownerChannel(i),
      isImage: true,
      context: () => mounted ? context : null,
      scope: () => (
        alive: () => mounted && !_disposed,
        current: () => mounted && !_disposed && widget.authorized(),
      ),
      onChanged: () {
        if (mounted) setState(() {});
      },
      settleOriginal: () =>
          pageKeys[i]?.currentState?.settled ?? Future.value(),
      progressRoute: widget.progressRoute,
    ),
  );

  AttachmentImageKey _originalKey(int i) =>
      attachmentOriginalKey(w, item(i), ownerChannel(i));

  AttachmentLightboxImageState? get _currentPage =>
      pageKeys[index]?.currentState;

  /// Server thumbnails (their signature came with the message) stand in for
  /// pages and fill the thumbnail strip. An image without one shows its
  /// number; nothing is signed for the strip.
  void _loadThumbnails() {
    if (_disposed) return;
    for (var i = 0; i < widget.items.length; i++) {
      final meta = item(i);
      if (attachmentThumbnailUrl(meta) == null || _thumbLeases.containsKey(i)) {
        continue;
      }
      try {
        final key = AttachmentImageKey.fromMetadata(
          scope: w.attachmentImageScope,
          channelId: ownerChannel(i),
          metadata: meta,
          rendition: 'thumbnail',
        );
        final lease = w.acquireAttachmentImage(
          key,
          authorized: widget.authorized,
          load: attachmentImageLoader(
            controller: w,
            files: widget.files,
            metadata: meta,
            key: key,
          ),
        );
        _thumbLeases[i] = lease;
        final ready = lease.lease.value;
        if (ready != null) {
          _thumbs[i] = ready;
        } else {
          unawaited(
            lease.lease.ready.then<void>((provider) {
              if (mounted && !_disposed) setState(() => _thumbs[i] = provider);
            }, onError: (Object _) {}),
          );
        }
      } catch (_) {
        // No thumbnail for this image: the strip shows its number.
      }
    }
    if (mounted) setState(() {});
  }

  ImageProvider? _placeholder(int i) => i == widget.initialIndex
      ? (widget.openerPlaceholder ?? _thumbs[i])
      : _thumbs[i];

  /// Once the current page shows its original, fetch each neighbour once at
  /// display size; release what is no longer adjacent.
  void _preloadNeighbours() {
    if (!mounted || _disposed || !widget.authorized()) return;
    final wanted = {
      for (final n in [index - 1, index + 1])
        if (n >= 0 && n < widget.items.length) n,
    };
    for (final stale
        in _preloads.keys.where((k) => !wanted.contains(k)).toList()) {
      _preloads.remove(stale)?.release();
    }
    final stage = MediaQuery.sizeOf(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    for (final n in wanted) {
      if (_preloads.containsKey(n)) continue;
      final meta = item(n);
      try {
        final full = _originalKey(n);
        final key = AttachmentImageKey(
          scope: full.scope,
          channelId: full.channelId,
          attachmentId: full.attachmentId,
          revision: full.revision,
          rendition: full.rendition,
          target: AttachmentDecodeTarget.box(
            stage.width,
            stage.height,
            devicePixelRatio: dpr,
          ),
        );
        final lease = w.acquireAttachmentImage(
          key,
          authorized: widget.authorized,
          load: attachmentImageLoader(
            controller: w,
            files: widget.files,
            metadata: meta,
            key: key,
          ),
        );
        _preloads[n] = lease;
        unawaited(lease.lease.ready.then<void>((_) {}, onError: (Object _) {}));
      } catch (_) {
        // A neighbour that cannot be preloaded loads when it is shown.
      }
    }
  }

  void _pageReady(int i) {
    if (i == index) _preloadNeighbours();
  }

  void _onPageChanged(int next) {
    // Web: zoom and pan reset on prev / next.
    zooms[index]?.value = Matrix4.identity();
    setState(() {
      index = next;
      zoomed = false;
    });
    final page = _currentPage;
    if (page != null && (page.full != null || page.failed)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _preloadNeighbours());
    }
  }

  /// Arrows, thumbnails and keys: no wrap.
  void goTo(int target) {
    if (target < 0 || target >= widget.items.length || target == index) return;
    if (!pages.hasClients) return;
    // Web swaps the image at once (no transition); a swipe animates natively.
    pages.jumpToPage(target);
  }

  /// Web handleKeyDown: while zoomed the arrows do not navigate.
  void _key(int delta) {
    if (zoomed) return;
    goTo(index + delta);
  }

  Future<void> _menu(Offset at) async {
    if (!phoneMenu || !widget.authorized()) return;
    final meta = item(index);
    final canSave = widget.files.gallerySupported && !attachmentIsSvg(meta);
    final canShare = widget.sharing.supported;
    if (!canSave && !canShare) return;
    final transfers = transfersFor(index);
    String? choice;
    await showRaftMessageContextMenu<void>(
      context: context,
      anchor: at,
      builder: (menuContext) {
        void pick(String value) {
          choice = value;
          Navigator.of(menuContext).pop();
        }

        final ios = AttachmentFiles.galleryLabel == 'Save to Photos';
        return RaftMessageContextMenu(
          onDismiss: () => Navigator.of(menuContext).pop(),
          sections: [
            [
              if (canSave)
                RaftMessageContextMenuItem(
                  key: const ValueKey('viewer-menu-save'),
                  label: ios
                      ? raftText(menuContext, 'Save to Photos')
                      : raftText(menuContext, 'Save to Gallery'),
                  icon: raftMessageMenuIcon(RaftGlyph.download),
                  onPressed: () => pick('save'),
                ),
              if (canShare)
                RaftMessageContextMenuItem(
                  key: const ValueKey('viewer-menu-share'),
                  label: raftText(menuContext, 'Share'),
                  icon: raftMessageMenuIcon(RaftGlyph.share2),
                  onPressed: () => pick('share'),
                ),
            ],
          ],
        );
      },
    );
    if (!mounted) return;
    switch (choice) {
      case 'save':
        await transfers.saveToGallery();
      case 'share':
        await transfers.share();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final lease in _thumbLeases.values) {
      lease.release();
    }
    for (final lease in _preloads.values) {
      lease.release();
    }
    _thumbLeases.clear();
    _preloads.clear();
    for (final transfers in _transfers.values) {
      transfers.abort();
    }
    for (final zoom in zooms.values) {
      zoom.removeListener(_zoomChanged);
      zoom.dispose();
    }
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.items.length;
    final meta = item(index);
    final transfers = transfersFor(index);
    final actions = phoneMenu
        ? const <Widget>[]
        : [
            RaftLightboxIconAction(
              key: const ValueKey('attachment-download'),
              glyph: RaftGlyph.download,
              label: 'Download',
              onPressed: widget.authorized()
                  ? () => unawaited(transfers.download())
                  : null,
            ),
          ];
    return AttachmentImageLightbox(
      page: widget.page,
      title: '${meta['filename'] ?? 'Attachment'}',
      zoom: zoomFor(index),
      onClose: widget.onClose,
      actions: actions,
      shortcuts: count > 1
          ? {
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _key(-1),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _key(1),
            }
          : const {},
      gallery: count > 1
          ? AttachmentLightboxGallery(
              index: index,
              thumbnails: [for (var i = 0; i < count; i++) _placeholder(i)],
              onSelect: goTo,
            )
          : null,
      child: GestureDetector(
        key: const ValueKey('viewer-stage'),
        behavior: HitTestBehavior.translucent,
        onLongPressStart: phoneMenu
            ? (d) => unawaited(_menu(d.globalPosition))
            : null,
        child: PageView.builder(
          key: const ValueKey('viewer-pages'),
          controller: pages,
          itemCount: count,
          // Zoomed in, a horizontal drag pans the image instead.
          physics: zoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          onPageChanged: _onPageChanged,
          itemBuilder: (context, i) {
            final pageMeta = item(i);
            final key = pageKeys.putIfAbsent(
              i,
              () => GlobalKey<AttachmentLightboxImageState>(),
            );
            final original = _originalKey(i);
            return AttachmentLightboxImage(
              key: key,
              imageKey: ValueKey('attachment-image-${pageMeta['id']}'),
              zoom: zoomFor(i),
              acquire: () => w.acquireAttachmentImage(
                original,
                authorized: widget.authorized,
                load: attachmentImageLoader(
                  controller: w,
                  files: widget.files,
                  metadata: pageMeta,
                  key: original,
                ),
                foreground: true,
              ),
              placeholder: _placeholder(i),
              previewFailed:
                  i == widget.initialIndex && widget.openerPreviewFailed,
              title: '${pageMeta['filename'] ?? 'Attachment'}',
              transferTotalHint: (pageMeta['sizeBytes'] as num?)?.toInt(),
              imageSize: _size(pageMeta),
              onReady: () => _pageReady(i),
            );
          },
        ),
      ),
    );
  }

  static Size? _size(Map<String, dynamic> metadata) {
    final width = (metadata['width'] as num?)?.toDouble();
    final height = (metadata['height'] as num?)?.toDouble();
    return width != null &&
            height != null &&
            width > 0 &&
            height > 0 &&
            width.isFinite &&
            height.isFinite
        ? Size(width, height)
        : null;
  }
}
