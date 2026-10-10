import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

class PickedUpload {
  const PickedUpload(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}

Future<PickedUpload?> selectUpload() async {
  final file = await openFile();
  if (file == null) return null;
  return PickedUpload(file.name, await file.readAsBytes());
}

/// Web MessageInput `MEDIA_PICKER_ACCEPT = "image/*,video/*"`: the media
/// button opens images and videos, the file button anything.
const mediaPickerTypeGroups = [
  XTypeGroup(
    label: 'Media',
    extensions: [
      'jpg',
      'jpeg',
      'png',
      'gif',
      'webp',
      'bmp',
      'avif',
      'heic',
      'heif',
      'mp4',
      'm4v',
      'mov',
      'webm',
      'mkv',
      'avi',
    ],
    mimeTypes: ['image/*', 'video/*'],
  ),
];

/// Uses the host document picker, including Android's Storage Access Framework.
/// Read one selected file at a time so large batches do not duplicate buffers.
Future<List<XFile>> selectUploads({bool mediaOnly = false}) => openFiles(
  acceptedTypeGroups: mediaOnly ? mediaPickerTypeGroups : const [],
);
