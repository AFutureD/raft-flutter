import 'dart:async';

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

import '../data/attachment_disk_cache.dart';
import 'computer_detail_view.dart' show computerFileSize;

/// Settings > Resources > Storage (native only; Web leaves caching to the
/// browser).
///
/// Shows how much attachment content this device keeps so that attachments
/// open again without downloading, and offers "Clear cache". Clearing removes
/// only the cache directory's entries: the sign-in, drafts, settings and files
/// the user saved are stored elsewhere and are never touched.
class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({super.key, this.cache});

  /// The cache to show and clear; the app's installed cache by default.
  final AttachmentDiskCache? cache;

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  late final AttachmentDiskCache? cache =
      widget.cache ?? AttachmentDiskCache.installed;

  /// Null while the size is being measured.
  int? bytes;

  @override
  void initState() {
    super.initState();
    unawaited(measure());
  }

  /// The index is built and read with asynchronous file I/O, so a large cache
  /// never blocks a frame.
  Future<void> measure() async {
    final value = await cache?.sizeBytes() ?? 0;
    if (mounted) setState(() => bytes = value);
  }

  Future<void> confirmClear() async {
    final cleared = await RaftConfirmDialog.show(
      context,
      RaftConfirmDialog(
        surfaceKey: const ValueKey('storage-clear-dialog'),
        confirmKey: const Key('storage-clear-confirm'),
        title: raftText(context, 'Clear cache'),
        message: raftText(
          context,
          'Attachments, profile pictures and icons will be downloaded again the next time you open them. Your sign-in, drafts, settings and files you saved are not affected.',
        ),
        confirmLabel: raftText(context, 'Clear cache'),
        loadingLabel: raftText(context, 'Clearing…'),
        onConfirm: () async => cache?.clear(),
      ),
    );
    if (cleared != true || !mounted) return;
    unawaited(measure());
    showRaftToast(context, 'Cache cleared.', tone: RaftToastRecipeTone.success);
  }

  @override
  Widget build(BuildContext context) {
    final text = RaftSettingsText(RaftTokens.of(context));
    final size = bytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const RaftSettingsSectionHeader(
          label: 'Storage',
          glyph: RaftGlyph.hardDrive,
        ),
        RaftSettingsCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              RaftSettingsPreference(
                title: 'Cache',
                description:
                    'Attachments, previews, profile pictures and icons you open are kept on this device so they open again without downloading. Your sign-in, drafts, settings and files you saved are not part of the cache.',
                child: Semantics(
                  key: const Key('storage-size'),
                  container: true,
                  liveRegion: true,
                  child: Text(
                    size == null
                        ? raftText(context, 'Calculating…')
                        : raftFormat(context, 'Cache size: {size}', {
                            'size': computerFileSize(size),
                          }),
                    style: text.description,
                  ),
                ),
              ),
              const SizedBox(height: RaftSpace.x3),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: RaftSettingsRecipeButton(
                  key: const Key('storage-clear'),
                  label: 'Clear cache',
                  glyph: RaftGlyph.trash2,
                  onPressed: cache == null || size == null
                      ? null
                      : confirmClear,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: RaftSpace.x6),
      ],
    );
  }
}
