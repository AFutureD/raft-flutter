// Browser `File.type` for a picked file name. Web MessageInput shows it as
// the file card's meta line and decides image previews from it
// (`isPreviewableImageFile`): the browser derives it from the extension, and
// leaves it empty for unknown ones.
const _mimeByExtension = <String, String>{
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'jfif': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'bmp': 'image/bmp',
  'avif': 'image/avif',
  'ico': 'image/x-icon',
  'svg': 'image/svg+xml',
  'heic': 'image/heic',
  'heif': 'image/heif',
  'tif': 'image/tiff',
  'tiff': 'image/tiff',
  'pdf': 'application/pdf',
  'zip': 'application/zip',
  'gz': 'application/gzip',
  'tar': 'application/x-tar',
  '7z': 'application/x-7z-compressed',
  'json': 'application/json',
  'xml': 'application/xml',
  'js': 'text/javascript',
  'mjs': 'text/javascript',
  'css': 'text/css',
  'html': 'text/html',
  'htm': 'text/html',
  'txt': 'text/plain',
  'log': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'ogg': 'audio/ogg',
  'm4a': 'audio/mp4',
  'flac': 'audio/flac',
  'mp4': 'video/mp4',
  'm4v': 'video/mp4',
  'mov': 'video/quicktime',
  'webm': 'video/webm',
  'mkv': 'video/x-matroska',
  'avi': 'video/x-msvideo',
  'apk': 'application/vnd.android.package-archive',
};

/// The MIME type a browser reports for [filename], or `''` when unknown.
String composerMimeType(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0 || dot == filename.length - 1) return '';
  return _mimeByExtension[filename.substring(dot + 1).toLowerCase()] ?? '';
}

/// Web `isPreviewableImageFile`: any `image/*` except SVG gets a thumbnail.
bool isPreviewableImageMime(String mime) {
  final type = mime.split(';').first.trim().toLowerCase();
  return type.startsWith('image/') && type != 'image/svg+xml';
}
