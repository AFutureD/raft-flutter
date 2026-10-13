import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/attachment_image_store.dart';
import '../data/workspace_controller.dart';
import '../platform/attachment_player.dart';
import '../platform/attachment_player_factory.dart';
import '../platform/attachment_preview_files.dart';
import '../platform/native_sharing.dart';
import '../data/attachment_transfer.dart';
import 'attachment_comments_view.dart';
import 'attachment_transfer_view.dart';

String? attachmentPreviewKind(Map<String, dynamic> metadata) {
  final name = '${metadata['filename'] ?? ''}'.toLowerCase();
  final mime = '${metadata['mimeType'] ?? ''}'
      .toLowerCase()
      .split(';')
      .first
      .trim();
  bool ext(List<String> values) => values.any(name.endsWith);
  if (ext(['.pdf']) || mime == 'application/pdf') return 'pdf';
  if (ext(['.mp4', '.webm', '.mov']) ||
      ['video/mp4', 'video/webm', 'video/quicktime'].contains(mime)) {
    return 'video';
  }
  if (ext([
        '.mp3',
        '.wav',
        '.m4a',
        '.aac',
        '.ogg',
        '.oga',
        '.opus',
        '.weba',
        '.flac',
      ]) ||
      [
        'audio/mpeg',
        'audio/mp3',
        'audio/wav',
        'audio/x-wav',
        'audio/wave',
        'audio/aac',
        'audio/mp4',
        'audio/x-m4a',
        'audio/ogg',
        'audio/opus',
        'audio/webm',
        'audio/flac',
        'audio/x-flac',
      ].contains(mime)) {
    return 'audio';
  }
  if (ext(['.diff', '.patch']) ||
      ['text/x-diff', 'text/x-patch', 'application/x-patch'].contains(mime)) {
    return null;
  }
  if (ext(['.html', '.htm']) || mime == 'text/html') return null;
  final size = metadata['sizeBytes'];
  if (!ext(['.xls', '.xlt', '.xla', '.xlm', '.xlc', '.xlw']) &&
      (ext(['.csv']) ||
          [
            'text/csv',
            'application/csv',
            'application/vnd.ms-excel',
          ].contains(mime)) &&
      (size is! num || size <= 5 * 1024 * 1024)) {
    return 'document';
  }
  if ((ext(['.xlsx']) ||
          mime ==
              'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet') &&
      (size is! num || size <= 10 * 1024 * 1024)) {
    return 'document';
  }
  if (ext(['.md', '.markdown']) ||
      ['text/markdown', 'text/x-markdown'].contains(mime)) {
    return 'document';
  }
  if (mime.startsWith('text/') && !['text/csv', 'text/html'].contains(mime) ||
      [
        'application/json',
        'application/xml',
        'application/yaml',
        'application/x-yaml',
        'application/toml',
        'application/x-sh',
      ].contains(mime) ||
      ext([
        '.txt',
        '.text',
        '.log',
        '.ini',
        '.conf',
        '.cfg',
        '.properties',
        '.toml',
        '.yaml',
        '.yml',
        '.json',
        '.xml',
        '.sql',
        '.gradle',
        '.sh',
        '.bash',
        '.zsh',
        '.kt',
        '.kts',
        '.java',
        '.swift',
        '.ets',
        '.ts',
        '.tsx',
        '.js',
        '.jsx',
        '.mjs',
        '.py',
        '.rb',
        '.go',
        '.rs',
        '.c',
        '.h',
        '.cpp',
        '.hpp',
      ])) {
    return 'document';
  }
  return null;
}

class AttachmentPreviewDialog extends StatefulWidget {
  const AttachmentPreviewDialog({
    super.key,
    required this.controller,
    required this.metadata,
    this.channelId,
    required this.authorized,
    required this.onClose,
    required this.onDownload,
    this.files,
    this.pdf,
    this.playerFactory,
    this.page = false,
  });
  final WorkspaceController controller;
  final Map<String, dynamic> metadata;
  final String? channelId;
  final bool Function() authorized;
  final VoidCallback onClose;
  final Future<void> Function() onDownload;
  final AttachmentPreviewFiles? files;
  final NativePdfRenderer? pdf;
  final AttachmentPlayer Function()? playerFactory;
  final bool page;
  @override
  State<AttachmentPreviewDialog> createState() =>
      _AttachmentPreviewDialogState();
}

class _AttachmentPreviewDialogState extends State<AttachmentPreviewDialog>
    with WidgetsBindingObserver {
  final cancel = CancelToken();
  SharedFileLease? lease;
  AttachmentPlayer? player;
  StreamSubscription<AttachmentPlayback>? playbackEvents;
  AttachmentPlayback playback = const AttachmentPlayback();
  Map<String, dynamic>? document;
  Uint8List? pageBytes;
  int page = 0, pageCount = 0, request = 0;
  bool loading = true, truncated = false, invalidated = false;

  /// The file itself could not be fetched (as opposed to decoded or played):
  /// the download panel offers a retry.
  bool fetchFailed = false;
  String? error;

  /// Bytes of the preview download, throttled; the panel's bar listens.
  final transfer = AttachmentTransfer();
  late final transferView = AttachmentTransferView(transfer);
  Future<void>? cleanup;
  String get kind => attachmentPreviewKind(widget.metadata) ?? 'unsupported';
  bool get current =>
      mounted && !invalidated && !cancel.isCancelled && widget.authorized();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(scopeChanged);
    load();
  }

  void scopeChanged() {
    if (!widget.authorized()) {
      invalidated = true;
      if (pageBytes != null) unawaited(raftEvictMemoryImage(pageBytes!));
      setState(() {
        document = null;
        pageBytes = null;
      });
      cancel.cancel();
      if (player != null) unawaited(player!.pause().catchError((_) {}));
      unawaited(releaseInputs());
      widget.onClose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && player != null) {
      unawaited(action((p) => p.pause()));
    }
  }

  /// Fetch again after a failure; the same panel returns to progress.
  void retry() {
    if (!current) return;
    transfer.value = null;
    setState(() {
      loading = true;
      error = null;
      fetchFailed = false;
    });
    load();
  }

  Future<void> load() async {
    final ticket = ++request;
    try {
      if (!current) return;
      if (kind == 'document') {
        // A document opened before on this device shows from the cache: no
        // preview request (it counts against the attachment rate limit).
        final stored = await readStoredDocument();
        if (!current || ticket != request) return;
        if (stored != null) {
          setState(() {
            document = stored.$1;
            truncated = stored.$2;
          });
          return;
        }
        final value = await widget.controller.query(
          '/attachments/${widget.metadata['id']}/preview',
        );
        if (!current || ticket != request) return;
        if (value is! Map ||
            value['status'] != 'ok' ||
            value['data'] is! Map ||
            ![
              'text',
              'markdown',
              'csv',
              'xlsx',
            ].contains(value['data']['kind'])) {
          throw const FormatException('The file cannot be previewed.');
        }
        setState(() {
          document = Map<String, dynamic>.from(value['data']);
          truncated = value['truncated'] == true;
        });
        unawaited(storeDocument(document!, truncated));
      } else if (['pdf', 'audio', 'video'].contains(kind)) {
        final owner =
            widget.channelId ?? widget.metadata['channelId'] as String?;
        Future<String> resolveUrl() => widget.controller.attachmentUrl(
          '${widget.metadata['id']}',
          channelId: owner,
        );
        final files = widget.files ?? AttachmentPreviewFiles();
        final filename = '${widget.metadata['filename'] ?? 'attachment'}';
        // PDF and audio come from the persistent cache when it holds them
        // (no request, not even for the signed URL) and are kept after the
        // first download. Video keeps its own path.
        final SharedFileLease? prepared;
        if (kind == 'video') {
          final url = await resolveUrl();
          if (!current || ticket != request) return;
          prepared = await files.load(
            url,
            filename,
            cancel: cancel,
            authorized: () => current,
            onProgress: transfer.report,
          );
        } else {
          prepared = await files.loadCached(
            cache: widget.controller.attachmentDiskCache,
            key: widget.controller.attachmentCacheKey(
              widget.metadata,
              'file',
              channelId: owner ?? '',
            ),
            resolveUrl: resolveUrl,
            filename: filename,
            expectedBytes: (widget.metadata['sizeBytes'] as num?)?.toInt(),
            cancel: cancel,
            authorized: () => current,
            onProgress: transfer.report,
          );
        }
        if (!current || ticket != request || prepared == null) {
          await prepared?.dispose();
          return;
        }
        lease = prepared;
        if (kind == 'pdf') {
          await loadPage(0);
        } else {
          player =
              (widget.playerFactory ??
              () => createAttachmentPlayer(
                video: kind == 'video',
                hdr: kind == 'video',
              ))();
          playbackEvents = player!.changes.listen((value) {
            if (!current) return;
            setState(() {
              playback = value;
              if (value.error) {
                error =
                    'The media could not be played. Download the original file.';
                unawaited(player!.pause().catchError((_) {}));
              }
            });
          });
          await player!.open(lease!.file);
        }
      } else {
        throw const FormatException('The file cannot be previewed.');
      }
    } catch (_) {
      if (current && ticket == request) {
        setState(() {
          error = 'Preview unavailable. Download the original file.';
          // Nothing was prepared: the bytes never arrived (or the preview
          // service failed), so a retry can still help.
          fetchFailed = lease == null && document == null;
        });
      }
    } finally {
      if (current && ticket == request) setState(() => loading = false);
    }
  }

  /// The document preview stored by an earlier open of this attachment.
  Future<(Map<String, dynamic>, bool)?> readStoredDocument() async {
    final cache = widget.controller.attachmentDiskCache;
    if (cache == null) return null;
    try {
      final bytes = await cache.read(documentKey);
      if (bytes == null) return null;
      final value = jsonDecode(utf8.decode(bytes));
      if (value is Map &&
          value['data'] is Map &&
          ['text', 'markdown', 'csv', 'xlsx'].contains(value['data']['kind'])) {
        return (
          Map<String, dynamic>.from(value['data'] as Map),
          value['truncated'] == true,
        );
      }
      await cache.remove(documentKey); // Unreadable: fetched again.
    } catch (_) {
      // A damaged entry is a miss.
    }
    return null;
  }

  Future<void> storeDocument(Map<String, dynamic> data, bool truncated) async {
    final cache = widget.controller.attachmentDiskCache;
    if (cache == null) return;
    try {
      await cache.write(
        documentKey,
        Uint8List.fromList(
          utf8.encode(jsonEncode({'data': data, 'truncated': truncated})),
        ),
      );
    } catch (_) {
      // Caching is best effort.
    }
  }

  AttachmentImageStoreKey get documentKey =>
      widget.controller.attachmentCacheKey(
        widget.metadata,
        'preview',
        channelId:
            widget.channelId ?? widget.metadata['channelId'] as String? ?? '',
      );

  Future<void> loadPage(int next) async {
    if (!current || lease == null) return;
    setState(() => loading = true);
    try {
      final value = await (widget.pdf ?? NativePdfRenderer()).render(
        lease!.file,
        next,
        cancel: cancel,
        authorized: () => current,
      );
      if (!current) return;
      if (pageBytes != null) unawaited(raftEvictMemoryImage(pageBytes!));
      setState(() {
        page = next;
        pageBytes = value.bytes;
        pageCount = value.pageCount;
      });
    } catch (_) {
      if (current) {
        setState(
          () => error =
              'The PDF could not be opened. Download the original file.',
        );
      }
    } finally {
      if (current) setState(() => loading = false);
    }
  }

  Future<void> action(Future<void> Function(AttachmentPlayer) run) async {
    if (!current || player == null) return;
    try {
      await run(player!);
    } catch (_) {
      if (current) {
        setState(
          () => error =
              'The media could not be played. Download the original file.',
        );
      }
    }
  }

  @override
  void dispose() {
    invalidated = true;
    request++;
    cancel.cancel();
    transfer.dispose();
    widget.controller.removeListener(scopeChanged);
    WidgetsBinding.instance.removeObserver(this);
    if (pageBytes != null) unawaited(raftEvictMemoryImage(pageBytes!));
    pageBytes = null;
    unawaited(releaseInputs());
    super.dispose();
  }

  Future<void> releaseInputs() => cleanup ??= () async {
    final heldPlayer = player, heldLease = lease;
    try {
      await playbackEvents?.cancel();
      await heldPlayer?.dispose();
    } catch (_) {
      // A failing native decoder must not retain its private file.
    } finally {
      await heldLease?.dispose();
    }
  }();

  /// The text the pane shows when it is copyable (Web `copyText`).
  String? get copyText {
    final data = document;
    if (data == null) return null;
    return switch (data['kind']) {
      'text' => '${data['text'] ?? ''}',
      'markdown' => '${data['markdown'] ?? ''}',
      _ => null,
    };
  }

  /// Initial fetch of the file or its preview data (not a PDF page turn).
  bool get fetching => loading && lease == null && document == null;

  /// File head, bar and `1.7 / 2.8 MB · 62%` with Cancel (leaving the
  /// preview cancels the download), or the failed state with Retry.
  Widget transferPanel(BuildContext context) {
    final name = '${widget.metadata['filename'] ?? ''}';
    final size = (widget.metadata['sizeBytes'] as num?)?.toInt();
    final extension = name.contains('.')
        ? name.split('.').last.toUpperCase()
        : '${widget.metadata['mimeType'] ?? ''}';
    return RaftFileTransferPanel(
      filename: name,
      meta: size == null || size <= 0
          ? extension
          : '$extension · ${RaftAttachmentCard.formatSize(size)}',
      progress: transferView,
      fallbackTotal: size,
      failed: fetchFailed,
      onCancel: widget.onClose,
      onRetry: retry,
    );
  }

  Widget pager() => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      RaftIconButton(
        glyph: RaftGlyph.chevronLeft,
        tooltip: 'Previous page',
        visualSize: 28,
        minimumTargetSize: 48,
        variant: RaftControlVariant.ghost,
        onPressed: !loading && page > 0 ? () => loadPage(page - 1) : null,
      ),
      Text('${page + 1} / $pageCount'),
      RaftIconButton(
        glyph: RaftGlyph.chevronRight,
        tooltip: 'Next page',
        visualSize: 28,
        minimumTargetSize: 48,
        variant: RaftControlVariant.ghost,
        onPressed: !loading && page + 1 < pageCount
            ? () => loadPage(page + 1)
            : null,
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => RaftAttachmentPreviewShell(
    filename: '${widget.metadata['filename'] ?? ''}',
    page: widget.page,
    onClose: widget.onClose,
    onDownload: current ? widget.onDownload : null,
    copyText: copyText,
    // Web lays text, csv, xlsx and markdown out on the canvas surface.
    canvas: document != null || kind == 'audio',
    // Web VideoPreviewBody: a solid black stage.
    dark: kind == 'video',
    // Web suppresses attachment comments for PDF and image surfaces.
    commentsBuilder: current && kind != 'pdf' && widget.metadata['id'] is String
        ? (_, sheet) => AttachmentCommentsView(
            controller: widget.controller,
            attachmentId: widget.metadata['id'] as String,
            filename: '${widget.metadata['filename'] ?? ''}',
            authorized: () => current,
            sheet: sheet,
          )
        : null,
    child: Column(
      children: [
        Expanded(
          child: !current
              ? const SizedBox.shrink()
              : fetching || fetchFailed
              ? Center(child: transferPanel(context))
              : loading
              ? const Center(child: RaftSpinner())
              : error != null
              ? RaftLoadError(error!)
              : document != null
              ? RaftDocumentPreview(data: document!, truncated: truncated)
              : kind == 'pdf' && pageBytes != null
              ? InteractiveViewer(
                  child: RaftSizedImage.memory(
                    pageBytes!,
                    fit: BoxFit.contain,
                    // The page stays sharp at the viewer's maximum zoom.
                    zoom: raftZoomableImageScale,
                    evictOnDispose: true,
                  ),
                )
              : kind == 'video' && player != null
              ? RaftVideoViewer(
                  filename: '${widget.metadata['filename'] ?? ''}',
                  video: player!.video(),
                  videoSize: playback.videoSize,
                  playing: playback.playing,
                  position: playback.position,
                  duration: playback.duration,
                  volume: playback.volume,
                  onTogglePlay: () => action((p) => p.toggle()),
                  onSeek: (v) => action((p) => p.seek(v)),
                  onVolume: (v) => action((p) => p.volume(v)),
                  onDownload: current ? widget.onDownload : null,
                )
              : kind == 'audio' && player != null
              ? RaftAudioPreview(
                  filename: '${widget.metadata['filename'] ?? ''}',
                  playing: playback.playing,
                  position: playback.position,
                  duration: playback.duration,
                  volume: (playback.volume / 100).clamp(0.0, 1.0),
                  onTogglePlay: () => action((p) => p.toggle()),
                  onSeek: (v) => action((p) => p.seek(v)),
                  onVolume: (v) => action((p) => p.volume(v * 100)),
                )
              : const SizedBox.shrink(),
        ),
        if (current && kind == 'pdf' && pageCount > 0) pager(),
      ],
    ),
  );
}
