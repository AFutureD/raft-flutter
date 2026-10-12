import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:image_picker/image_picker.dart';

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
    uniformTypeIdentifiers: ['public.image', 'public.movie'],
  ),
];

/// iOS Photos uses PHPicker without library access or full asset metadata.
/// Other hosts retain their document picker; the file button always uses it.
Future<List<XFile>> selectUploads({
  bool mediaOnly = false,
  TargetPlatform? platform,
  ImagePicker? picker,
}) {
  if (mediaOnly && _usesPhotos(platform)) {
    return (picker ?? ImagePicker()).pickMultipleMedia(
      requestFullMetadata: false,
      limit: 9,
    );
  }
  return openFiles(
    acceptedTypeGroups: mediaOnly ? mediaPickerTypeGroups : const [],
  );
}

bool _usesPhotos(TargetPlatform? platform) =>
    !kIsWeb && (platform ?? defaultTargetPlatform) == TargetPlatform.iOS;

Future<XFile?> selectImage({
  required XTypeGroup typeGroup,
  TargetPlatform? platform,
  ImagePicker? picker,
}) => _usesPhotos(platform)
    ? (picker ?? ImagePicker()).pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      )
    : openFile(acceptedTypeGroups: [typeGroup]);

Future<List<XFile>> selectImages({
  required XTypeGroup typeGroup,
  TargetPlatform? platform,
  ImagePicker? picker,
}) => _usesPhotos(platform)
    ? (picker ?? ImagePicker()).pickMultiImage(
        requestFullMetadata: false,
        limit: 9,
      )
    : openFiles(acceptedTypeGroups: [typeGroup]);
