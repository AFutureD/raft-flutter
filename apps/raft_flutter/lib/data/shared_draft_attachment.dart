/// A private local file staged by a platform service. The controller owns its
/// draft lifecycle; the service validates ownership and supplies a fresh stream.
class SharedDraftAttachment {
  const SharedDraftAttachment({
    required this.reference,
    required this.filename,
    required this.mimeType,
    required this.sizeBytes,
    required this.openRead,
    required this.release,
    this.previewPath,
  });
  final Map<String, dynamic> reference;
  final String filename, mimeType;
  final int sizeBytes;
  final String? previewPath;
  final Stream<List<int>> Function() openRead;
  final Future<void> Function() release;
}

typedef RestoreSharedDraftAttachment = Future<SharedDraftAttachment?> Function(
  Map<String, dynamic> reference,
  String origin,
  String principal,
);
