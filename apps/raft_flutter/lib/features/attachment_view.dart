import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'layout_hold.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/workspace_controller.dart';
import '../data/attachment_image_repository.dart';
import '../data/attachment_url_cache.dart';
import '../platform/attachment_files.dart';
import '../platform/native_sharing.dart';
import '../platform/system_bars.dart';
import 'attachment_preview_dialog.dart';
import 'attachment_transfer_view.dart';
import 'attachment_html_preview.dart';
import 'attachment_image_lightbox.dart';
import 'attachment_preview_gate.dart';
import 'inline_attachment_media.dart';
import 'private_route_guard.dart';

bool _isSvgMime(String mime) =>
    mime.toLowerCase().split(';').first.trim() == 'image/svg+xml';

/// Web isPreviewableImageAttachment (urlImageFallback.ts): any `image/*`, but
/// an SVG only when the server rasterized it (`thumbnailUrl`, a 320px WebP).
/// Native never feeds authored SVG bytes to the raster decoder.
bool attachmentIsInlineImage(Map<String, dynamic> metadata) {
  final mime = '${metadata['mimeType'] ?? 'application/octet-stream'}';
  final type = mime.toLowerCase().split(';').first.trim();
  if (!type.startsWith('image/')) return false;
  if (!_isSvgMime(type)) return true;
  final thumbnail = metadata['thumbnailUrl'];
  return thumbnail is String &&
      (thumbnail.startsWith('https://') || thumbnail.startsWith('http://'));
}

class AttachmentView extends StatefulWidget {
  const AttachmentView({
    super.key,
    required this.controller,
    required this.metadata,
    this.files,
    this.messageId,
    this.exportMode = false,
    this.onExportReady,
    this.imageExtent,
    this.imageFit = BoxFit.contain,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final AttachmentFiles? files;
  final String? messageId;
  final bool exportMode;
  final VoidCallback? onExportReady;
  final Size? imageExtent;
  final BoxFit imageFit;
  @override
  State<AttachmentView> createState() => _AttachmentViewState();
}

class _AttachmentViewState extends State<AttachmentView> {
  late AttachmentFiles files;
  int bindingRevision = 0;
  late String metadataFingerprint;
  final sharing = NativeSharing();
  SharedFileLease? sharedLease;
  CancelToken imageCancel = CancelToken(), downloadCancel = CancelToken();

  /// The list preview: thumbnail or original decoded at the reserved box.
  ImageProvider? imageProvider;
  final imagePresentation = ValueNotifier<int>(0);
  WorkspaceAttachmentImageLease? imageLease;

  /// Bytes of the list preview's network fetch; the card's bar listens to it.
  AttachmentTransferView? imageTransfer;
  String? error;
  bool loading = false, saving = false, invalidated = false;

  /// The last explicit download failed; the file card offers a retry.
  bool downloadFailed = false;

  /// A cold network load fades in once; cached images appear directly.
  bool fadeIn = false;
  bool begun = false;
  double devicePixelRatio = 1;
  bool exportReadyReported = false, opening = false;
  ModalRoute<void>? previewRoute;
  DialogRoute<void>? progressRoute;
  late int generation;
  Map<String, dynamic>? channelAuthority;
  late String? principal, server, sourceChannel, projectedServer, role;
  WorkspaceController get w => widget.controller;
  String get name => '${widget.metadata['filename'] ?? 'Attachment'}';
  String get mime =>
      '${widget.metadata['mimeType'] ?? 'application/octet-stream'}';
  bool get isImage => attachmentIsInlineImage(widget.metadata);
  bool get isSvg => _isSvgMime(mime);

  bool get visibleExportDescendant =>
      widget.exportMode &&
      w.messages.any((parent) {
        final thread = parent.threadId;
        return thread != null &&
            w.ledger.messages(thread).any((m) => m['id'] == widget.messageId);
      });
  bool get authorized =>
      mounted &&
      !invalidated &&
      generation == w.client.generation &&
      principal == w.client.user?.id &&
      server == w.client.serverId &&
      sourceChannel == w.channel?.id &&
      !channelAuthorityReduced(channelAuthority, w.channel?.json) &&
      projectedServer == w.server?.id &&
      role == w.server?.string('role') &&
      (widget.messageId == null ||
          w.presentsMessage(widget.messageId) ||
          w.presentsReply(widget.messageId) ||
          w.threadParent?.id == widget.messageId ||
          visibleExportDescendant);

  @override
  void initState() {
    super.initState();
    files = widget.files ?? AttachmentFiles();
    metadataFingerprint = fingerprint();
    captureAuthority();
    w.addListener(scopeChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    devicePixelRatio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    if (begun) return;
    begun = true;
    beginImage();
  }

  String fingerprint({bool withMessage = true}) => jsonEncode([
    withMessage ? widget.messageId : null,
    widget.exportMode,
    for (final key in [
      'id',
      'channelId',
      'mimeType',
      'sizeBytes',
      'width',
      'height',
      'contentVersion',
      'contentHash',
      'updatedAt',
    ])
      widget.metadata[key],
  ]);

  void captureAuthority() {
    generation = w.client.generation;
    principal = w.client.user?.id;
    server = w.client.serverId;
    sourceChannel = w.channel?.id;
    channelAuthority = w.channel == null
        ? null
        : {
            ...w.channel!.json,
            if (w.channel!.json['channelCapabilities'] is Map)
              'channelCapabilities': {
                ...(w.channel!.json['channelCapabilities'] as Map),
              },
          };
    projectedServer = w.server?.id;
    role = w.server?.string('role');
  }

  /// Server-generated 320px WebP (Web's inline `thumbnailUrl` source).
  String? get thumbnailUrl {
    final value = widget.metadata['thumbnailUrl'];
    return value is String &&
            (value.startsWith('https://') || value.startsWith('http://'))
        ? value
        : null;
  }

  /// Logical box the list preview is displayed in: the gallery's extent, or
  /// the single-image reservation (Web reserveSingleImage) at its largest.
  Size get previewBox {
    final extent = widget.imageExtent;
    if (extent != null && extent.width > 0 && extent.height > 0) return extent;
    final width = (widget.metadata['width'] as num?)?.toDouble();
    final height = (widget.metadata['height'] as num?)?.toDouble();
    const maxWidth = AttachmentPrimitive.singleImageMaxWidth,
        maxHeight = AttachmentPrimitive.singleImageMaxHeight;
    if (width == null ||
        height == null ||
        !(width > 0 && height > 0 && width.isFinite && height.isFinite)) {
      return const Size(maxWidth, maxHeight);
    }
    final scale = math.min(1.0, math.min(maxWidth / width, maxHeight / height));
    return Size(width * scale, height * scale);
  }

  String get ownerChannel =>
      '${widget.metadata['channelId'] ?? (w.presentsReply(widget.messageId) ? w.threadChannelId : w.channel?.id) ?? ''}';

  AttachmentImageKey keyFor({required bool preview}) {
    final box = previewBox;
    return AttachmentImageKey.fromMetadata(
      scope: w.attachmentImageScope,
      channelId: ownerChannel,
      metadata: widget.metadata,
      // An SVG's bytes are never decoded: its raster thumbnail serves the
      // list preview and the lightbox alike.
      rendition: (preview || isSvg) && thumbnailUrl != null
          ? 'thumbnail'
          : 'original',
      target: preview
          ? AttachmentDecodeTarget.box(
              box.width,
              box.height,
              devicePixelRatio: devicePixelRatio,
              cover: widget.imageFit == BoxFit.cover,
            )
          : null,
    );
  }

  /// List rows never decode the full original; only the lightbox does.
  AttachmentImageKey get imageKey => keyFor(preview: true);
  AttachmentImageKey get fullImageKey => keyFor(preview: false);

  /// Fetches the key's source bytes. Capability URLs live only in this call.
  AttachmentImageLoader loaderFor(AttachmentImageKey key) {
    final controller = w, transfer = files;
    final id = widget.metadata['id'];
    final thumbnail = key.rendition == 'thumbnail' ? thumbnailUrl : null;
    return (cancel) async {
      final channelId = key.channelId;
      if (thumbnail != null) {
        try {
          return await transfer.image(
            thumbnail,
            cancel: cancel,
            onProgress: cancel.progressSink,
          );
        } on DioException catch (error) {
          // The thumbnail's signature came with the message and has lapsed:
          // sign the original once (batched with the other tiles) rather than
          // showing a broken card.
          final status = error.response?.statusCode;
          if (cancel.isCancelled || (status != 401 && status != 403)) rethrow;
        }
      }
      final url = await controller.attachmentUrl(
        '$id',
        channelId: channelId,
        coalesce: true,
      );
      if (cancel.isCancelled) throw const StaleAttachmentImage();
      try {
        return await transfer.image(
          url,
          cancel: cancel,
          onProgress: cancel.progressSink,
        );
      } on DioException catch (error) {
        // A reused URL can outlive the server's view of it (clock skew,
        // early expiry): drop it and sign once more.
        final status = _httpStatus(error);
        if (cancel.isCancelled || (status != 401 && status != 403)) rethrow;
        controller.invalidateAttachmentUrl('$id');
        final fresh = await controller.attachmentUrl(
          '$id',
          channelId: channelId,
        );
        if (cancel.isCancelled) throw const StaleAttachmentImage();
        return transfer.image(
          fresh,
          cancel: cancel,
          onProgress: cancel.progressSink,
        );
      }
    };
  }

  /// A decoded image the controller still retains (channel revisit, row
  /// recycling) is adopted in the first frame; no loading state, no bytes GET.
  bool adoptReadyImage() {
    if (!authorized) return false;
    final WorkspaceAttachmentImageLease? lease;
    try {
      lease = w.peekAttachmentImage(imageKey, authorized: () => authorized);
    } catch (_) {
      return false;
    }
    final provider = lease?.lease.value;
    if (lease == null) return false;
    if (provider == null) {
      lease.release();
      return false;
    }
    imageLease?.release();
    imageLease = lease;
    imageProvider = provider;
    error = null;
    return true;
  }

  void beginImage() {
    prefetchOriginalUrl();
    if (isImage &&
        (widget.metadata['sizeBytes'] as num? ?? 0) <= 50 * 1024 * 1024) {
      if (adoptReadyImage()) {
        imagePresentation.value++;
        exportReady();
        return;
      }
      loadImage();
    } else {
      exportReady();
    }
  }

  @override
  void didUpdateWidget(AttachmentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextFingerprint = fingerprint();
    if (oldWidget.controller == w &&
        oldWidget.files == widget.files &&
        nextFingerprint == metadataFingerprint) {
      return;
    }
    // An optimistic row's attachment (no message yet) adopting the accepted
    // message keeps the loaded preview; authority is still read per use.
    if (oldWidget.controller == w &&
        oldWidget.files == widget.files &&
        oldWidget.messageId == null &&
        widget.messageId != null &&
        oldWidget.exportMode == widget.exportMode &&
        fingerprint(withMessage: false) == metadataFingerprint) {
      metadataFingerprint = nextFingerprint;
      return;
    }
    oldWidget.controller.removeListener(scopeChanged);
    ++bindingRevision;
    imageCancel.cancel();
    downloadCancel.cancel();
    imageLease?.release();
    imageLease = null;
    if (sharedLease != null) unawaited(sharedLease!.dispose());
    sharedLease = null;
    for (final route in [previewRoute, progressRoute]) {
      if (route?.isActive == true) route!.navigator?.removeRoute(route);
    }
    previewRoute = progressRoute = null;
    imageCancel = CancelToken();
    downloadCancel = CancelToken();
    files = widget.files ?? files;
    metadataFingerprint = nextFingerprint;
    imageProvider = null;
    imageTransfer = null;
    error = null;
    downloadFailed = false;
    loading = saving = opening = invalidated = exportReadyReported = false;
    fadeIn = false;
    captureAuthority();
    w.addListener(scopeChanged);
    beginImage();
  }

  void exportReady() {
    if (!widget.exportMode || exportReadyReported) return;
    final revision = bindingRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (revision != bindingRevision || !authorized || exportReadyReported) {
        return;
      }
      exportReadyReported = true;
      widget.onExportReady?.call();
    });
  }

  void scopeChanged() {
    if (!authorized) {
      invalidated = true;
      urlPrefetch?.cancel();
      urlPrefetch = null;
      if (sharedLease != null) unawaited(sharedLease!.dispose());
      sharedLease = null;
      imageCancel.cancel();
      downloadCancel.cancel();
      for (final route in [previewRoute, progressRoute]) {
        if (route?.isActive == true) route!.navigator?.removeRoute(route);
      }
      imageLease?.release();
      imageLease = null;
      if (imageProvider != null && mounted) {
        setState(() => imageProvider = null);
      }
    }
  }

  @override
  void dispose() {
    ++bindingRevision;
    w.removeListener(scopeChanged);
    if (sharedLease != null) unawaited(sharedLease!.dispose());
    sharedLease = null;
    imageCancel.cancel();
    downloadCancel.cancel();
    urlPrefetch?.cancel();
    urlPrefetch = null;
    hoverPrefetch?.cancel();
    hoverPrefetch = null;
    imageLease?.release();
    imageLease = null;
    for (final route in [previewRoute, progressRoute]) {
      if (route?.isActive == true) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (route!.isActive) route.navigator?.removeRoute(route);
        });
      }
    }
    imageProvider = null;
    imagePresentation.dispose();
    super.dispose();
  }

  Future<String> resolve(String disposition) async {
    return w.attachmentUrl(
      '${widget.metadata['id']}',
      disposition: disposition,
      channelId: ownerChannel,
    );
  }

  Future<void> loadImage() async {
    if (!authorized || loading) return;
    final revision = bindingRevision;
    bool current() => revision == bindingRevision && authorized;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      imageLease?.release();
      final key = imageKey;
      final lease = w.acquireAttachmentImage(
        key,
        authorized: current,
        load: loaderFor(key),
      );
      imageLease = lease;
      imageTransfer = AttachmentTransferView(lease.lease.progress);
      final provider = await lease.lease.ready;
      if (current() && identical(imageLease, lease)) {
        setState(() {
          imageProvider = provider;
          fadeIn = !widget.exportMode && !lease.lease.fromStore;
        });
      }
    } catch (_) {
      if (current() && !imageCancel.isCancelled) {
        setState(() => error = 'The image could not be loaded.');
      }
    } finally {
      if (mounted && revision == bindingRevision) {
        setState(() => loading = false);
        imagePresentation.value++;
      }
      if (revision == bindingRevision &&
          (imageProvider != null || error != null)) {
        exportReady();
      }
    }
  }

  Future<void> shareAttachment() async {
    final revision = bindingRevision;
    bool current() => revision == bindingRevision && authorized;
    if (!current() || saving || !sharing.supported) return;
    setState(() => saving = true);
    final operationCancel = CancelToken();
    downloadCancel = operationCancel;
    try {
      final url = await resolve('attachment');
      if (!current()) return;
      if (sharedLease != null) await sharedLease!.dispose();
      final prepared = await sharing.prepareAttachment(
        url: url,
        filename: name,
        cancel: operationCancel,
        authorized: current,
        onProgress: (_, _) {
          if (!current()) operationCancel.cancel();
        },
      );
      if (prepared == null) return;
      if (!current()) {
        await prepared.dispose();
        return;
      }
      sharedLease = prepared;
      await sharing.shareFile(prepared, mime);
    } catch (_) {
      if (mounted && current() && !operationCancel.isCancelled) {
        showRaftToast(context, 'The attachment could not be shared.');
      }
    } finally {
      if (mounted && revision == bindingRevision) {
        setState(() => saving = false);
      }
    }
  }

  Future<void> download() async {
    final revision = bindingRevision;
    bool current() => revision == bindingRevision && authorized;
    if (!current() || saving) return;
    setState(() {
      saving = true;
      downloadFailed = false;
    });
    final operationCancel = CancelToken();
    downloadCancel = operationCancel;
    final progress = ValueNotifier<double?>(null);
    var dialogVisible = true;
    var progressOpened = false;
    DialogRoute<void>? operationRoute;
    // Use the platform save picker first; show progress only after it closes.
    try {
      final url = await resolve('attachment');
      if (!current()) return;
      final saved = await files.save(
        url: url,
        filename: name,
        mimeType: mime,
        cancel: operationCancel,
        authorized: current,
        onProgress: (received, total) {
          if (!current()) {
            operationCancel.cancel();
            return;
          }
          if (!progressOpened) {
            progressOpened = true;
            operationRoute = DialogRoute<void>(
              context: context,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                title: Text('Downloading $name'),
                content: ValueListenableBuilder<double?>(
                  valueListenable: progress,
                  builder: (_, value, _) =>
                      LinearProgressIndicator(value: value),
                ),
                actions: [
                  TextButton(
                    onPressed: operationCancel.cancel,
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            );
            progressRoute = operationRoute;
            Navigator.of(
              context,
              rootNavigator: true,
            ).push(operationRoute!).whenComplete(() => dialogVisible = false);
          }
          progress.value = total > 0 ? received / total : null;
        },
      );
      if (progressOpened && mounted && dialogVisible) {
        operationRoute?.navigator?.removeRoute(operationRoute!);
        dialogVisible = false;
      }
      if (saved != null && mounted && current()) {
        showRaftToast(
          context,
          raftFormat(context, 'Saved {name}', {'name': name}),
          tone: RaftToastRecipeTone.success,
          actionLabel: 'Open',
          onAction: () async {
            try {
              await files.open(saved, mime);
            } catch (_) {
              if (mounted) {
                showRaftToast(context, 'No application can open this file.');
              }
            }
          },
        );
      }
    } catch (_) {
      if (mounted && current() && !operationCancel.isCancelled) {
        setState(() => downloadFailed = true);
        showRaftToast(context, 'Download failed. Try again.');
      }
    } finally {
      if (revision == bindingRevision) saving = false;
      if (progressOpened && operationRoute?.isActive == true) {
        operationRoute!.navigator?.removeRoute(operationRoute!);
      }
      if (identical(progressRoute, operationRoute)) progressRoute = null;
      // The dialog builder may still be mounted for its closing animation.
      Future<void>.delayed(const Duration(seconds: 1), progress.dispose);
    }
  }

  Future<void> open() async {
    if (!authorized || opening || previewRoute?.isActive == true) return;
    final revision = bindingRevision;
    opening = true;
    try {
      await openCurrent();
    } finally {
      if (revision == bindingRevision) opening = false;
    }
  }

  ModalRoute<void> createPreviewRoute(bool page, WidgetBuilder builder) =>
      _heldRoute(_previewRoute(page, builder));

  ModalRoute<void> _heldRoute(ModalRoute<void> route) {
    LayoutHold.hold(route);
    return route;
  }

  ModalRoute<void> _previewRoute(bool page, WidgetBuilder builder) => page
      ? MaterialPageRoute<void>(
          settings: const RouteSettings(name: '/attachment-preview'),
          builder: (context) {
            final surface = RaftTokens.of(context).panel;
            // ds-allow: Native route owns keyboard insets and system bars; raft_ui owns preview content.
            return Scaffold(
              backgroundColor: surface,
              body: RaftSystemBarSurface(
                statusBarFallback: surface,
                child: builder(context),
              ),
            );
          },
        )
      : RaftFullBleedDialogRoute<void>(context: context, builder: builder);

  Future<void> openCurrent() async {
    final revision = bindingRevision;
    bool current() => revision == bindingRevision && authorized;
    final page = RaftAdaptiveWorkspace.compactOf(context);
    final html =
        '${widget.metadata['mimeType'] ?? ''}'
                .toLowerCase()
                .split(';')
                .first
                .trim() ==
            'text/html' ||
        RegExp(r'\.html?$', caseSensitive: false).hasMatch(name);
    if (!isImage && (attachmentPreviewKind(widget.metadata) != null || html)) {
      // The gate is a server setting: a value this device has seen opens the
      // preview at once (re-read behind it); only a gate never seen is read
      // while the preview is already on screen.
      final known = knownAttachmentPreviewGate(w);
      final gate = readAttachmentPreviewGate(w);
      if (known == false) {
        final decided = await gate;
        if (!current() || decided == AttachmentPreviewGate.unauthorized) {
          return;
        }
        if (decided == AttachmentPreviewGate.disabled) {
          await download();
          return;
        }
      }
      if (!mounted || !current()) return;
      late final ModalRoute<void> operationRoute;
      operationRoute = createPreviewRoute(
        page,
        (dialogContext) => html
            ? HtmlAttachmentPreviewDialog(
                page: page,
                controller: w,
                metadata: widget.metadata,
                authorized: current,
                onClose: () {
                  if (dialogContext.mounted &&
                      identical(previewRoute, operationRoute) &&
                      operationRoute.isCurrent) {
                    operationRoute.navigator?.pop();
                  }
                },
                onDownload: download,
              )
            : AttachmentPreviewDialog(
                page: page,
                controller: w,
                metadata: widget.metadata,
                channelId: ownerChannel,
                authorized: current,
                onClose: () {
                  if (dialogContext.mounted &&
                      identical(previewRoute, operationRoute) &&
                      operationRoute.isCurrent) {
                    operationRoute.navigator?.pop();
                  }
                },
                onDownload: download,
              ),
      );
      previewRoute = operationRoute;
      if (known == null) {
        unawaited(
          gate.then((decided) {
            if (decided == AttachmentPreviewGate.enabled ||
                !identical(previewRoute, operationRoute) ||
                !operationRoute.isActive) {
              return;
            }
            operationRoute.navigator?.removeRoute(operationRoute);
            if (decided == AttachmentPreviewGate.disabled && current()) {
              unawaited(download());
            }
          }),
        );
      }
      await Navigator.of(context, rootNavigator: true).push(operationRoute);
      if (identical(previewRoute, operationRoute)) previewRoute = null;
      return;
    }
    if (!isImage) {
      await download();
      return;
    }
    if (!mounted || !current()) return;
    // Source opens the image lightbox at intent, independently of thumbnail
    // readiness. A pending thumbnail load must not consume the user's click.
    if (imageProvider == null && !loading) unawaited(loadImage());
    final fullKey = fullImageKey;
    late final ModalRoute<void> operationRoute;
    final zoom = TransformationController();
    operationRoute = createPreviewRoute(
      page,
      (dialogContext) => AttachmentImageLightbox(
        page: page,
        title: name,
        zoom: zoom,
        onClose: () {
          if (identical(previewRoute, operationRoute) &&
              operationRoute.isCurrent) {
            if (page) {
              operationRoute.navigator?.pop();
            } else {
              operationRoute.navigator?.removeRoute(operationRoute);
            }
          }
        },
        onDownload: current() ? download : null,
        child: ValueListenableBuilder<int>(
          valueListenable: imagePresentation,
          builder: (_, _, _) {
            if (!current()) return const SizedBox.shrink();
            return AttachmentLightboxImage(
              imageKey: ValueKey('attachment-image-${widget.metadata['id']}'),
              zoom: zoom,
              acquire: () => w.acquireAttachmentImage(
                fullKey,
                authorized: current,
                load: loaderFor(fullKey),
                foreground: true,
              ),
              placeholder: imageProvider,
              previewFailed: error != null,
              title: name,
              transferTotalHint: (widget.metadata['sizeBytes'] as num?)
                  ?.toInt(),
              imageSize: imageSize,
            );
          },
        ),
      ),
    );
    previewRoute = operationRoute;
    await Navigator.of(context, rootNavigator: true).push(operationRoute);
    // The image remains interactive while its page animates out.
    await operationRoute.completed;
    zoom.dispose();
    if (identical(previewRoute, operationRoute)) previewRoute = null;
  }

  /// The original's pixel size from the attachment metadata, when valid.
  Size? get imageSize {
    final width = (widget.metadata['width'] as num?)?.toDouble();
    final height = (widget.metadata['height'] as num?)?.toDouble();
    return width != null &&
            height != null &&
            width > 0 &&
            height > 0 &&
            width.isFinite &&
            height.isFinite
        ? Size(width, height)
        : null;
  }

  /// Web MessageItem AttachmentChip branches: document previews (summary
  /// "Document preview", mime meta), HTML / video / audio previews, else a
  /// download card with the mime type.
  ({String? summary, String meta, bool preview}) get webChip {
    final kind = attachmentPreviewKind(widget.metadata);
    final type = mime.toLowerCase().split(';').first.trim();
    final html =
        type == 'text/html' ||
        RegExp(r'\.html?$', caseSensitive: false).hasMatch(name);
    final rawMime = widget.metadata['mimeType'] as String?;
    final mimeLabel = rawMime == null || rawMime.isEmpty ? null : rawMime;
    if (kind == 'video') {
      return (
        summary: null,
        meta: raftText(context, 'Video preview'),
        preview: true,
      );
    }
    if (kind == 'audio') {
      return (
        summary: null,
        meta: raftText(context, 'Audio preview'),
        preview: true,
      );
    }
    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.diff') ||
        lowerName.endsWith('.patch') ||
        const [
          'text/x-diff',
          'text/x-patch',
          'application/x-patch',
        ].contains(type)) {
      // DiffPatchStatsLine: the stats need the fetched preview; until then
      // (and in this client) the summary line reads "Diff preview".
      return (
        summary: raftText(context, 'Diff preview'),
        meta: mimeLabel ?? raftText(context, 'patch'),
        preview: false,
      );
    }
    if (kind != null) {
      return (
        summary: raftText(context, 'Document preview'),
        meta: mimeLabel ?? raftText(context, 'document'),
        preview: true,
      );
    }
    if (html) {
      return (
        summary: null,
        meta: raftText(context, 'HTML preview'),
        preview: true,
      );
    }
    return (
      summary: null,
      meta: mimeLabel ?? raftText(context, 'file'),
      preview: false,
    );
  }

  /// Web MessageItem renders audio and video attachments as inline players.
  /// Pointer intent (hover, press) resolves the signed URL ahead of the click
  /// so the open starts at the storage request. A press fires on touch before
  /// the tap completes; hover gives desktop a head start. Plain files are
  /// saved with a one-shot `attachment` URL and are not prefetched.
  void warmUrl({bool press = false}) {
    if (widget.exportMode || widget.messageId == null || !authorized) return;
    final kind = attachmentPreviewKind(widget.metadata);
    if (!isImage && kind == null && !isHtml) return;
    if (kind == 'video' || kind == 'audio') return; // Inline loaders do it.
    if (kind == 'document' || isHtml) return; // Previewed by text, not URL.
    final id = '${widget.metadata['id']}';
    if (!press) {
      final now = DateTime.now();
      final last = lastUrlWarm;
      if (last != null && now.difference(last) < const Duration(seconds: 20)) {
        return;
      }
      lastUrlWarm = now;
      // Hover is only a hint: a mouse sweeping over a list of messages must
      // not send one request per card. It joins the bounded, batched
      // background prefetch (a no-op when the URL is held or on its way); the
      // press that follows asks for it at once.
      hoverPrefetch?.cancel();
      hoverPrefetch = w.prefetchAttachmentUrl(id, channelId: ownerChannel);
      return;
    }
    unawaited(
      w
          .attachmentUrl(id, channelId: ownerChannel, coalesce: true)
          .then((url) {
            if (mounted && authorized) w.attachmentHostWarmer?.call(url);
          }, onError: (Object _) {}),
    );
  }

  PrefetchHandle? hoverPrefetch;

  DateTime? lastUrlWarm;

  /// The list shows a server thumbnail, so the original's URL is not resolved
  /// by the preview itself; ask for it in the background (one batched request
  /// per screenful) while the card is on screen.
  void prefetchOriginalUrl() {
    urlPrefetch?.cancel();
    urlPrefetch = null;
    if (widget.exportMode ||
        widget.messageId == null ||
        !authorized ||
        !isImage ||
        thumbnailUrl == null) {
      return;
    }
    urlPrefetch = w.prefetchAttachmentUrl(
      '${widget.metadata['id']}',
      channelId: ownerChannel,
    );
  }

  PrefetchHandle? urlPrefetch;

  bool get isHtml =>
      '${widget.metadata['mimeType'] ?? ''}'
              .toLowerCase()
              .split(';')
              .first
              .trim() ==
          'text/html' ||
      RegExp(r'\.html?$', caseSensitive: false).hasMatch(name);

  @override
  Widget build(BuildContext context) {
    final child = buildAttachment(context);
    if (widget.exportMode) return child;
    return MouseRegion(
      onEnter: (_) => warmUrl(),
      child: Listener(
        onPointerDown: (_) => warmUrl(press: true),
        child: child,
      ),
    );
  }

  Widget buildAttachment(BuildContext context) {
    final kind = attachmentPreviewKind(widget.metadata);
    if (!widget.exportMode && !isImage && kind == 'video') {
      return InlineVideoAttachment(
        key: ValueKey('inline-video-${widget.metadata['id']}'),
        controller: w,
        metadata: widget.metadata,
        channelId: ownerChannel,
        authorized: () => authorized,
        pending: widget.messageId == null,
        onOpenPreview: open,
        onDownload: download,
      );
    }
    if (!widget.exportMode && !isImage && kind == 'audio') {
      return InlineAudioAttachment(
        key: ValueKey('inline-audio-${widget.metadata['id']}'),
        controller: w,
        metadata: widget.metadata,
        channelId: ownerChannel,
        authorized: () => authorized,
        pending: widget.messageId == null,
        onDownload: download,
      );
    }
    return card(context);
  }

  Widget card(BuildContext context) => RaftAttachmentCard(
    summary: webChip.summary,
    metaLabel: webChip.meta,
    previewAffordance: webChip.preview,
    exportMode: widget.exportMode,
    filename: name,
    mimeType: mime,
    imageExtent: widget.imageExtent,
    imageWidth: (widget.metadata['width'] as num?)?.toDouble(),
    imageHeight: (widget.metadata['height'] as num?)?.toDouble(),
    sizeBytes: (widget.metadata['sizeBytes'] as num?)?.toInt(),
    // Image previews load behind a neutral reserved box, not a spinner.
    busy: saving,
    previewPending: loading,
    error: error,
    onRetry: loadImage,
    transfer: imageTransfer,
    // A thumbnail's length is not the original's `sizeBytes`.
    transferFallbackTotal: thumbnailUrl == null
        ? (widget.metadata['sizeBytes'] as num?)?.toInt()
        : null,
    downloadFailed: downloadFailed,
    onOpen: open,
    onDownload: download,
    onShare: sharing.supported ? shareAttachment : null,
    onCancel: saving ? downloadCancel.cancel : null,
    preview: imageProvider == null ? null : previewImage(imageProvider!),
  );

  Widget previewImage(ImageProvider provider) {
    Widget image({Animation<double>? opacity}) => Image(
      image: provider,
      opacity: opacity,
      fit: widget.imageFit,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => const RaftLoadError(
        'Preview unavailable. Download the original file.',
        expand: false,
      ),
    );
    if (!fadeIn) return image();
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AttachmentPrimitive.previewFade,
      // Image.opacity blends pixels directly and avoids an offscreen layer.
      builder: (_, opacity, _) =>
          image(opacity: AlwaysStoppedAnimation(opacity)),
    );
  }
}

int? _httpStatus(DioException failure) => failure.response?.statusCode;
