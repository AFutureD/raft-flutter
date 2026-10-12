import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner decision 2026-10-12: every image decodes at its display size by
/// default. Raw providers and `Image` widgets keep the whole source bitmap in
/// the shared `ImageCache`, so they may only be constructed by the sized-image
/// helper (`RaftSizedImage` in raft_ui) or by a file listed below with the
/// reason its decode is already bounded. A new site must use `RaftSizedImage`;
/// adding an allowlist entry needs a reason a reviewer can check.
const _patterns = <String, String>{
  'NetworkImage': r'\bNetworkImage\(',
  'Image.network': r'\bImage\.network\(',
  'MemoryImage': r'\bMemoryImage\(',
  'Image.memory': r'\bImage\.memory\(',
  'FileImage': r'\bFileImage\(',
  'Image.file': r'\bImage\.file\(',
  'Image.asset': r'\bImage\.asset\(',
  'AssetImage': r'\b(?:Exact)?AssetImage\(',
  'DecorationImage': r'\bDecorationImage\(',
  'backgroundImage': r'\bbackgroundImage\s*:',
  'CachedNetworkImage': r'\bCachedNetworkImage\(',
  'Image(': r'\bImage\(',
  'RawImage': r'\bRawImage\(',
  'ImageDescriptor': r'\bImageDescriptor\.|instantiateImageCodec',
};

const _helper =
    'The sized-image helper itself: the only place raw providers are built '
    'and wrapped so the decode size is the display size.';
const _repository =
    'Attachment images decode through decodeAttachmentImage at the target '
    'display size (bucketed), and the repository owns their lifetime.';
const _lease =
    'The provider comes from an AttachmentImageRepository lease: already '
    'decoded at the target size and shared with the message bubble.';

/// file -> pattern name -> reason
const _allow = <String, Map<String, String>>{
  'packages/raft_ui/lib/src/sized_image.dart': {
    'NetworkImage': _helper,
    'MemoryImage': _helper,
    'Image(': _helper,
  },
  'apps/raft_flutter/lib/data/attachment_image_repository.dart': {
    'ImageDescriptor': _repository,
  },
  'apps/raft_flutter/lib/features/attachment_view.dart': {'Image(': _lease},
  'apps/raft_flutter/lib/features/attachment_image_lightbox.dart': {
    'Image(':
        'Lightbox stage images are leases decoded at screen size x zoom cap '
        'by the repository; the viewer keeps that bounded path.',
  },
  'apps/raft_flutter/lib/features/source_channel_files_actions.dart': {
    'Image(': _lease,
  },
  'apps/raft_flutter/lib/features/source_channel_files_view.dart': {
    'Image(': _lease,
  },
  'packages/raft_ui/lib/src/attachment_lightbox.dart': {
    'Image(':
        'Thumbnail strip reuses the already-decoded bitmaps of the message '
        'attachments (OneFrame bitmap providers, nothing left to resize).',
  },
  'packages/flutter_chat_ui/lib/src/avatar.dart': {
    'CachedNetworkImage':
        'Vendored upstream Avatar (cross_cache provider); not referenced by '
        'the app, whose rows use RaftAvatarContent.',
    'DecorationImage': 'Same unused vendored Avatar.',
  },
};

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages/raft_ui').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) fail('repository root not found');
    dir = parent;
  }
  return dir;
}

String _stripComments(String line) {
  final i = line.indexOf('//');
  return i < 0 ? line : line.substring(0, i);
}

void main() {
  test('raw image providers only appear in the sized-image helper', () {
    final root = _repoRoot();
    final found = <String, Set<String>>{};
    final regexps = {for (final e in _patterns.entries) e.key: RegExp(e.value)};
    for (final base in const [
      'apps/raft_flutter/lib',
      'packages/raft_ui/lib',
      'packages/flutter_chat_ui/lib',
    ]) {
      for (final f
          in Directory('${root.path}/$base')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final rel = f.path.substring(root.path.length + 1);
        final lines = f.readAsLinesSync();
        for (var n = 0; n < lines.length; n++) {
          final code = _stripComments(lines[n]);
          for (final e in regexps.entries) {
            if (e.value.hasMatch(code)) {
              found.putIfAbsent(rel, () => {}).add(e.key);
            }
          }
        }
      }
    }
    final violations = <String>[
      for (final f in found.entries)
        for (final p in f.value)
          if (!(_allow[f.key]?.containsKey(p) ?? false))
            '${f.key}: $p (use RaftSizedImage from raft_ui)',
    ]..sort();
    expect(
      violations,
      isEmpty,
      reason:
          'Images must decode at display size. Use RaftSizedImage / '
          'raftSizedImage, or add an allowlist entry with a reason.',
    );
    final stale = <String>[
      for (final f in _allow.entries)
        for (final p in f.value.keys)
          if (!(found[f.key]?.contains(p) ?? false)) '${f.key}: $p',
    ]..sort();
    expect(
      stale,
      isEmpty,
      reason: 'Remove allowlist entries that no longer match.',
    );
    for (final f in _allow.values) {
      for (final reason in f.values) {
        expect(reason.trim().length, greaterThan(20));
      }
    }
  });
}
