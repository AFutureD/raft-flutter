import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:raft_ui/raft_ui.dart';

/// The kind of device whose memory the budgets are sized for.
enum RaftMemoryClass {
  /// Android and iOS: a few GB shared with every other app, killed rather than
  /// swapped when the foreground app is too large.
  phone,

  /// Linux, macOS and Windows: gigabytes to spare, a window that may be
  /// resized to 4K.
  desktop,
}

/// Every rebuildable in-memory tier of the app and its limit, in one place
/// (the table in docs/architecture.md, "Cache", mirrors [describe]). Disk
/// tiers are not here: `AttachmentDiskCache` owns the 1 GiB budget.
///
/// Nothing in these tiers is the only copy of anything: a bitmap, a still or a
/// remembered verdict that is let go of is decoded or measured again on demand.
/// `RaftMemoryRelease` empties them while the app is hidden and under memory
/// pressure; this table only bounds how large they grow while the app is in
/// use.
///
/// | tier | owner | phone | desktop |
/// |---|---|---|---|
/// | framework `ImageCache` (decoded `Image` providers: sized images, avatars on remount, markdown / link previews, emoji) | `PaintingBinding` | 200 images / 64 MiB | 500 images / 128 MiB |
/// | attachment images, decoded | `AttachmentImageRepository` | 64 images / 64 MiB | 64 images / 96 MiB |
/// | attachment images, encoded (decode source) | `AttachmentImageRepository` | 32 MiB | 64 MiB |
/// | avatar bitmaps, decoded | `RaftHotImages` | 384 / 24 MiB | 384 / 24 MiB |
/// | avatar bytes, encoded | `RaftImageBytes` | 8 MiB | 8 MiB |
/// | video stills | `PlayerSessions` | 24 / 16 MiB | 24 / 16 MiB |
/// | video / audio players | `PlayerSessions` | 2 live (native demuxer 32 or 64 MiB + 8 MiB back each) | same |
/// | HDR verdicts, prepared set, resume positions | `PlayerSessions` | 256 each | 256 each |
/// | signed attachment URLs | `AttachmentUrlCache` | 256 entries, 4 min | same |
@immutable
class RaftMemoryBudgets {
  const RaftMemoryBudgets._({
    required this.memoryClass,
    required this.imageCacheEntries,
    required this.imageCacheBytes,
    required this.attachmentImageEntries,
    required this.attachmentImageDecodedBytes,
    required this.attachmentImageEncodedBytes,
  });

  final RaftMemoryClass memoryClass;

  /// The framework `ImageCache` (`PaintingBinding.instance.imageCache`):
  /// `maximumSize` and `maximumSizeBytes`.
  final int imageCacheEntries, imageCacheBytes;

  /// [AttachmentImageRepository]: entries, decoded and encoded bytes.
  final int attachmentImageEntries,
      attachmentImageDecodedBytes,
      attachmentImageEncodedBytes;

  static const _mib = 1024 * 1024;

  static const phone = RaftMemoryBudgets._(
    memoryClass: RaftMemoryClass.phone,
    imageCacheEntries: 200,
    imageCacheBytes: 64 * _mib,
    attachmentImageEntries: 64,
    attachmentImageDecodedBytes: 64 * _mib,
    attachmentImageEncodedBytes: 32 * _mib,
  );

  static const desktop = RaftMemoryBudgets._(
    memoryClass: RaftMemoryClass.desktop,
    imageCacheEntries: 500,
    imageCacheBytes: 128 * _mib,
    attachmentImageEntries: 64,
    attachmentImageDecodedBytes: 96 * _mib,
    attachmentImageEncodedBytes: 64 * _mib,
  );

  // Tiers that do not differ by device class.

  /// Decoded avatar bitmaps ([RaftHotImages]) and their encoded bytes
  /// ([RaftImageBytes]); owned by raft_ui.
  static const avatarHotEntries = RaftHotImages.defaultMaxEntries;
  static const avatarHotBytes = RaftHotImages.defaultMaxBytes;
  static const avatarEncodedBytes = RaftImageBytes.defaultMemoryBudgetBytes;

  /// Video stills kept per attachment (card-sized pictures).
  static const playerStillEntries = 24;
  static const playerStillBytes = 16 * _mib;

  /// Entries of each of the small remembered maps of `PlayerSessions`.
  static const playerRememberedEntries = 256;

  /// Concurrent native players (see `PlayerSessions.maxLive`).
  static const playerLive = 2;

  /// The budgets of the platform the app runs on.
  static RaftMemoryBudgets get current => forPlatform(defaultTargetPlatform);

  static RaftMemoryBudgets forPlatform(TargetPlatform platform) =>
      switch (platform) {
        TargetPlatform.android || TargetPlatform.iOS => phone,
        _ => desktop,
      };

  /// Sets the framework image cache limits. Returns a callback that restores
  /// the limits the cache had (shrinking evicts the oldest entries at once).
  VoidCallback applyImageCache([ImageCache? cache]) {
    final target = cache ?? PaintingBinding.instance.imageCache;
    final entries = target.maximumSize, bytes = target.maximumSizeBytes;
    target
      ..maximumSize = imageCacheEntries
      ..maximumSizeBytes = imageCacheBytes;
    return () => target
      ..maximumSize = entries
      ..maximumSizeBytes = bytes;
  }

  /// One line per tier, for logs and the tests that pin the table.
  List<String> describe() => [
    'imageCache $imageCacheEntries images / ${imageCacheBytes ~/ _mib} MiB',
    'attachmentImages $attachmentImageEntries images / '
        '${attachmentImageDecodedBytes ~/ _mib} MiB decoded / '
        '${attachmentImageEncodedBytes ~/ _mib} MiB encoded',
    'avatarHot $avatarHotEntries / ${avatarHotBytes ~/ _mib} MiB',
    'avatarBytes ${avatarEncodedBytes ~/ _mib} MiB',
    'playerStills $playerStillEntries / ${playerStillBytes ~/ _mib} MiB',
    'playerLive $playerLive',
    'playerRemembered $playerRememberedEntries',
  ];
}
