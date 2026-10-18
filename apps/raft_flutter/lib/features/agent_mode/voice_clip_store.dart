import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// Where the sound of the canned lines of a relay voice (see
/// `OpenAiRealtimeSession.prewarm`) is kept between runs of the app, so that
/// the acknowledgment is instant from the first turn.
abstract interface class VoiceClipStore {
  /// The sound kept under [key], or null.
  Future<List<Uint8List>?> read(String key);

  /// Keeps [chunks] (PCM16, 24 kHz, mono) under [key].
  Future<void> write(String key, List<Uint8List> chunks);
}

/// [VoiceClipStore] in a folder of the app's cache directory: one file of raw
/// PCM per clip. A cache: the system may clear it, and the clips are made
/// again.
class FileVoiceClipStore implements VoiceClipStore {
  FileVoiceClipStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationCacheDirectory;

  final Future<Directory> Function() _root;
  Directory? _dir;

  /// The sound is handed on in pieces of this size (100 ms).
  static const chunkBytes = 4800;

  Future<File> _file(String key) async {
    final dir = _dir ??= await Directory('${(await _root()).path}/voice_clips')
        .create(recursive: true);
    return File('${dir.path}/${_name(key)}.pcm');
  }

  /// FNV-1a over the key's bytes: the same name in every run.
  static String _name(String key) {
    var h = 0xcbf29ce484222325;
    for (final b in utf8.encode(key)) {
      h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return h.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  @override
  Future<List<Uint8List>?> read(String key) async {
    try {
      final file = await _file(key);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      return [
        for (var i = 0; i < bytes.length; i += chunkBytes)
          Uint8List.sublistView(
            bytes,
            i,
            i + chunkBytes > bytes.length ? bytes.length : i + chunkBytes,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, List<Uint8List> chunks) async {
    try {
      final file = await _file(key);
      final all = BytesBuilder(copy: false);
      for (final c in chunks) {
        all.add(c);
      }
      await file.writeAsBytes(all.takeBytes(), flush: true);
    } catch (_) {
      /* a cache: made again next time */
    }
  }
}
