import 'dart:async';
import 'dart:convert';

import '../../apps/raft_flutter/lib/data/workspace_cache_codec.dart';

// Synthetic fixture; baseline sanitizer copied from 4e87659 production code.
Future<void> main() async {
  final data = {
    'channelId': 'fixture',
    'messages': [
      for (var i = 0; i < 600; i++)
        {
          'id': '$i',
          'content': '中文 body ' * 700,
          'attachment': {'url': 'https://example.invalid/file?token=fixture'},
        },
    ],
  };
  final baseline = jsonEncode(_cacheSafe(data));
  if (await encodeWorkspaceCache(data) != baseline)
    throw StateError('Mismatch');
  for (final worker in [false, true]) {
    final gaps = <int>[];
    final durations = <int>[];
    for (var iteration = 0; iteration < 23; iteration++) {
      final clock = Stopwatch()..start();
      var previous = 0;
      var largest = 0;
      final heartbeat = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final now = clock.elapsedMicroseconds;
        final gap = now - previous;
        if (gap > largest) largest = gap;
        previous = now;
      });
      await Future<void>.delayed(const Duration(milliseconds: 3));
      final job = Stopwatch()..start();
      final encoded = worker
          ? await encodeWorkspaceCache(data)
          : jsonEncode(_cacheSafe(data));
      final decoded = worker
          ? await decodeWorkspaceCache(encoded)
          : jsonDecode(encoded);
      if ((decoded['messages'] as List).length != 600)
        throw StateError('Count');
      job.stop();
      await Future<void>.delayed(const Duration(milliseconds: 3));
      heartbeat.cancel();
      if (iteration >= 3) {
        gaps.add(largest);
        durations.add(job.elapsedMicroseconds);
      }
    }
    gaps.sort();
    durations.sort();
    print(
      jsonEncode({
        'mode': worker ? 'worker' : 'baseline-inline',
        'rows': 600,
        'payloadCharacters': baseline.length,
        'samples': gaps.length,
        'heartbeatGapMedianMs': gaps[gaps.length ~/ 2] / 1000,
        'heartbeatGapP95Ms': gaps[(gaps.length * .95).ceil() - 1] / 1000,
        'jobMedianMs': durations[durations.length ~/ 2] / 1000,
        'heartbeatGapsUsSorted': gaps,
        'jobDurationsUsSorted': durations,
      }),
    );
  }
}

dynamic _cacheSafe(dynamic value) {
  if (value is Map) {
    return {
      for (final e in value.entries)
        if (!{
          'accessToken',
          'refreshToken',
          'apiKey',
          'bootstrapToken',
          'previewToken',
          'providerSecret',
          'clientSecret',
          'authorization',
          'signedUrl',
          'downloadUrl',
          'uploadUrl',
        }.contains(e.key))
          e.key.toString(): _cacheSafe(e.value),
    };
  }
  if (value is List) return value.map(_cacheSafe).toList();
  if (value is String &&
      (value.contains('X-Amz-') ||
          value.contains('Signature=') ||
          value.contains('access_token=') ||
          RegExp(
            r'(?:[?&])(?:token|previewToken|bootstrapToken|refresh_token|api_key)=',
            caseSensitive: false,
          ).hasMatch(value))) {
    return null;
  }
  return value;
}
