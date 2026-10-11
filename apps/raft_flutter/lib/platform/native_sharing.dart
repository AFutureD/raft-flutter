import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_intent/receive_intent.dart' as intents;
import 'package:uri_content/uri_content.dart';

import 'attachment_files.dart';
import 'incoming_share_inbox.dart';

class IncomingSharedFile {
  const IncomingSharedFile(
    this.uri,
    this.filename,
    this.mimeType,
    this.sizeBytes,
  );
  final String uri, filename, mimeType;
  final int? sizeBytes;
}

class IncomingShare {
  const IncomingShare({this.text, this.files = const [], this.token});
  final String? token;
  final String? text;
  final List<IncomingSharedFile> files;
  static IncomingShare? parse(dynamic value) {
    if (value is! Map) return null;
    final files = <IncomingSharedFile>[];
    for (final entry
        in (value['files'] is List ? value['files'] as List : const [])) {
      if (entry is! Map ||
          entry['uri'] is! String ||
          entry['filename'] is! String) {
        return null;
      }
      final uri = Uri.tryParse(entry['uri']);
      if (uri == null || uri.scheme != 'content' || uri.host.isEmpty) {
        return null;
      }
      files.add(
        IncomingSharedFile(
          entry['uri'],
          AttachmentFiles.safeFilename(entry['filename']),
          entry['mimeType'] is String
              ? entry['mimeType']
              : 'application/octet-stream',
          entry['sizeBytes'] is num
              ? (entry['sizeBytes'] as num).toInt()
              : null,
        ),
      );
    }
    if (files.length > 10) return null;
    final text = value['text'] is String ? value['text'] as String : null;
    if (text != null && text.length > 65536 ||
        files.isEmpty && (text == null || text.isEmpty)) {
      return null;
    }
    return IncomingShare(text: text, files: files);
  }
}

/// A user-authorized export lives only in private temporary storage. It never
/// contains a signed URL. Recipients get a read grant to this one file.
class SharedFileLease {
  SharedFileLease(
    this.file, {
    Duration lifetime = const Duration(minutes: 15),
  }) {
    _timer = Timer(lifetime, () => unawaited(dispose()));
  }
  final File file;
  Timer? _timer;
  Future<void>? _disposal;
  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    _timer?.cancel();
    _timer = null;
    if (await file.parent.exists()) await file.parent.delete(recursive: true);
  }
}

class NativeSharing {
  NativeSharing({
    MethodChannel? channel,
    Dio? dio,
    Future<Directory> Function()? temporaryDirectory,
    bool? supported,
    Stream<Uint8List> Function(Uri)? readContent,
    Future<Directory> Function()? incomingDirectory,
  }) : channel = channel ?? const MethodChannel('app.raft/sharing'),
       _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               receiveTimeout: const Duration(seconds: 30),
             ),
           ),
       _readContent =
           readContent ??
           ((uri) =>
               UriContent().getContentStream(uri, bufferSize: 256 * 1024)),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       supported = supported ?? Platform.isAndroid {
    inbox = IncomingShareInbox(
      incomingDirectory ?? _incomingDirectory,
      _readContent,
      copyContent: readContent == null && Platform.isAndroid && this.supported
          ? (uri, file, limit) async =>
                (await this.channel.invokeMethod<int>('copyIncoming', {
                  'uri': uri.toString(),
                  'path': file.path,
                  'limit': limit,
                })) ??
                (throw const FormatException('Shared file unavailable'))
          : null,
    );
  }
  late final IncomingShareInbox inbox;
  Future<Directory> _incomingDirectory() async {
    if (supported) {
      final path = await channel.invokeMethod<String>('incomingDirectory');
      if (path != null) return Directory(path);
    }
    return Directory(
      p.join((await _temporaryDirectory()).path, 'raft-incoming'),
    );
  }

  final MethodChannel channel;
  final Dio _dio;
  final Future<Directory> Function() _temporaryDirectory;
  final bool supported;
  final Stream<Uint8List> Function(Uri) _readContent;
  final _readers = <StreamIterator<Uint8List>>{};
  StreamSubscription<intents.Intent?>? _intentSubscription;
  Future<void> _incomingWork = Future.value();
  Future<void>? _initialization;
  static const maxIncomingBytes = 50 * 1024 * 1024;
  void Function(IncomingShare)? _receiver;
  final _pending = Queue<IncomingShare>();
  set onIncoming(void Function(IncomingShare)? receiver) {
    _receiver = receiver;
    while (receiver != null &&
        identical(_receiver, receiver) &&
        _pending.isNotEmpty &&
        !_closed) {
      receiver(_pending.removeFirst());
    }
  }

  void receive(IncomingShare incoming) {
    if (_closed) return;
    if (_receiver == null) {
      _pending.addLast(incoming);
    } else {
      _receiver!(incoming);
    }
  }

  void Function() registerReceiver(void Function(IncomingShare) receiver) {
    onIncoming = receiver;
    return () {
      if (identical(_receiver, receiver)) _receiver = null;
    };
  }

  bool _closed = false;

  Future<void> init() => _initialization ??= _init();

  Future<void> _init() async {
    if (!supported || _closed) return;
    _intentSubscription = intents.ReceiveIntent.receivedIntentStream.listen(
      (intent) => unawaited(_queueIntent(intent)),
      onError: (Object _) {},
    );
    try {
      // The launching intent is admitted first: recovering shares left by an
      // earlier process scans the inbox folder and must not delay the share the
      // user just sent. Recovered shares arrive (as pending ones) alongside it.
      final recovery = () async {
        try {
          for (final share in await inbox.pending()) {
            receive(share);
          }
        } catch (_) {
          // A failed recovery must not prevent admission of a new intent.
        }
      }();
      await _queueIntent(await intents.ReceiveIntent.getInitialIntent());
      await recovery;
      if (!_closed) await channel.invokeMethod<void>('sharingReady');
    } on PlatformException {
      // A platform without a receiving Activity still supports outgoing shares.
    } on MissingPluginException {
      // Optional outside Android.
    }
  }

  Future<void> _queueIntent(intents.Intent? intent) {
    // Serialize provider metadata lookups so rapid shares retain arrival order.
    return _incomingWork = _incomingWork.then((_) async {
      if (_closed ||
          intent == null ||
          !const [
            'android.intent.action.SEND',
            'android.intent.action.SEND_MULTIPLE',
          ].contains(intent.action)) {
        return;
      }
      final extras = intent.extra ?? const <String, dynamic>{};
      final raw =
          extras['app.raft.sharedUris'] ??
          extras['android.intent.extra.STREAM'];
      final uris = (raw is List ? raw : [?raw]);
      final text = extras['android.intent.extra.TEXT'];
      // Validate before asking a content provider for metadata.
      if (uris.length > 10 ||
          uris.any((raw) {
            final uri = raw is String ? Uri.tryParse(raw) : null;
            return uri == null || uri.scheme != 'content' || uri.host.isEmpty;
          }) ||
          (text != null && (text is! String || text.length > 65536))) {
        return;
      }
      var files = <dynamic>[
        for (final uri in uris) {'uri': uri, 'filename': 'attachment'},
      ];
      if (uris.isNotEmpty) {
        try {
          files =
              await channel.invokeListMethod<dynamic>('sharedFileInfo', {
                'uris': uris,
              }) ??
              files;
        } on PlatformException {
          // Missing metadata must not discard an otherwise readable grant.
        } on MissingPluginException {
          // Optional in tests and other platform hosts.
        }
      }
      final share = IncomingShare.parse({'text': text, 'files': files});
      if (share != null) receive(share);
    });
  }

  Future<void> shareText(String text, {String? title}) async {
    if (!supported) {
      throw PlatformException(
        code: 'unsupported',
        message: 'System sharing is unavailable on this platform.',
      );
    }
    await channel.invokeMethod<void>('share', {
      'text': text,
      'title': title,
      'mimeType': 'text/plain',
    });
  }

  Future<void> shareFile(SharedFileLease lease, String mimeType) async {
    if (!supported) {
      throw PlatformException(
        code: 'unsupported',
        message: 'System sharing is unavailable on this platform.',
      );
    }
    await channel.invokeMethod<void>('share', {
      'path': lease.file.path,
      'mimeType': mimeType,
    });
  }

  Future<Uint8List> readIncoming(
    IncomingSharedFile file, {
    required bool Function() authorized,
  }) async {
    if (!supported || _closed || !authorized()) {
      throw PlatformException(
        code: 'stale',
        message: 'The conversation changed.',
      );
    }
    final uri = Uri.tryParse(file.uri);
    if (uri == null || uri.scheme != 'content' || uri.host.isEmpty) {
      throw PlatformException(code: 'invalid', message: 'Invalid shared file.');
    }
    if ((file.sizeBytes ?? 0) > maxIncomingBytes) {
      throw PlatformException(
        code: 'too_large',
        message: 'The shared file exceeds 50 MB.',
      );
    }
    final reader = StreamIterator(_readContent(uri));
    _readers.add(reader);
    final bytes = BytesBuilder(copy: false);
    try {
      while (await reader.moveNext()) {
        if (_closed || !authorized()) {
          throw PlatformException(
            code: 'stale',
            message: 'The conversation changed.',
          );
        }
        if (bytes.length + reader.current.length > maxIncomingBytes) {
          throw PlatformException(
            code: 'too_large',
            message: 'The shared file exceeds 50 MB.',
          );
        }
        bytes.add(reader.current);
      }
      if (_closed || !authorized()) {
        throw PlatformException(
          code: 'stale',
          message: 'The conversation changed.',
        );
      }
      return bytes.takeBytes();
    } finally {
      _readers.remove(reader);
      await reader.cancel();
    }
  }

  Future<SharedFileLease?> prepareBytes(
    Uint8List bytes, {
    required String filename,
    required bool Function() authorized,
  }) async {
    if (!supported || !authorized()) return null;
    final root = await _temporaryDirectory();
    final folder = await Directory(
      p.join(
        root.path,
        'raft-share',
        'share-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    final file = File(
      p.join(folder.path, AttachmentFiles.safeFilename(filename)),
    );
    try {
      await file.writeAsBytes(bytes, flush: true);
      if (!authorized()) {
        await folder.delete(recursive: true);
        return null;
      }
      return SharedFileLease(file);
    } catch (_) {
      if (await folder.exists()) await folder.delete(recursive: true);
      rethrow;
    }
  }

  Future<SharedFileLease?> prepareAttachment({
    required String url,
    required String filename,
    required CancelToken cancel,
    required bool Function() authorized,
    required void Function(int, int) onProgress,
  }) async {
    if (!supported || !authorized() || cancel.isCancelled) return null;
    final root = await _temporaryDirectory();
    final folder = await Directory(
      p.join(
        root.path,
        'raft-share',
        'share-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    final file = File(
      p.join(folder.path, AttachmentFiles.safeFilename(filename)),
    );
    try {
      await _dio.download(
        AttachmentFiles.attachmentUri(url).toString(),
        file.path,
        cancelToken: cancel,
        onReceiveProgress: onProgress,
      );
      if (!authorized() || cancel.isCancelled) {
        await folder.delete(recursive: true);
        return null;
      }
      return SharedFileLease(file);
    } catch (_) {
      if (await folder.exists()) await folder.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> dispose() async {
    _closed = true;
    _receiver = null;
    _pending.clear();
    await _intentSubscription?.cancel();
    await Future.wait(_readers.toList().map((reader) => reader.cancel()));
    _readers.clear();
  }
}
