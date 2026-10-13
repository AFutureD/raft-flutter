// Player interaction suite for the system player (video_player: ExoPlayer on
// Android, AVPlayer on Apple): real taps through the gesture arena, real route
// transitions, real network from a range server that counts what it sends.
// Nothing here uses a fake player. Run it with `tool/player-interactions`
// (docs/media-playback.md, "Interaction suite"); the host runner adds what a
// test on the device cannot do itself: Android's back key and back swipe, the
// screen recording of the close animation, the system save dialog.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:raft_flutter/platform/video_player_attachment_player.dart';
import 'package:raft_flutter/features/attachment_preview_dialog.dart' show debugLastHdrHandoff;
import 'package:raft_ui/raft_ui.dart';

import 'support/player_lab.dart';
import 'support/video_fixture.dart';

const _base = String.fromEnvironment('VP_BASE', defaultValue: 'http://127.0.0.1:8791');
const _hostDriven = bool.fromEnvironment('VP_HOST');
const _only = String.fromEnvironment('VP_ONLY');

const _portrait = VideoClip('vp-portrait', 'portrait.mp4', 'portrait.mp4', size: 5416578);
const _long = VideoClip('vp-long', 'long.mp4', 'long.mp4', size: 16383818);
const _slow4k = VideoClip('vp-4k', 'hevc4k.mp4', 'hevc4k.mp4', size: 41607413, rate: 2000000);
const _corrupt = VideoClip('vp-corrupt', 'corrupt.mp4', 'broken.mp4', size: 200000);
const _hlg = VideoClip('vp-hlg', 'portrait-hlg.mp4', 'hlg.mp4', size: 5416578);
const _big4k = VideoClip('vp-big4k', 'hevc4k.mp4', 'hevc4k.mp4', size: 41607413);
const _stall = VideoClip('vp-stall', 'portrait.mp4', 'stall.mp4', size: 5416578, rate: 600);
const _choke = VideoClip('vp-choke', 'portrait.mp4', 'choke.mp4', size: 5416578, rate: 90000);
const _longHlg = VideoClip('vp-long-hlg', 'long-hlg.mp4', 'long-hlg.mp4', size: 16385074);
const _tone = VideoClip('vp-tone', 'tone.wav', 'tone.wav', size: 264678, mime: 'audio/wav');

late final PlayerLab lab;

/// A scenario; `--dart-define=VP_ONLY=<part of the name>` runs a subset.
void scenario(String name, Future<void> Function(WidgetTester) body) =>
    testWidgets(name, body, skip: _only.isNotEmpty && !name.contains(_only));

Finder card(String filename) => find.byWidgetPredicate((w) => w is RaftInlineVideo && w.filename == filename);
RaftInlineVideo cardOf(WidgetTester t, String filename) => t.widget<RaftInlineVideo>(card(filename));
Finder get viewer => find.byType(RaftVideoViewer);
RaftVideoViewer viewerOf(WidgetTester t) => t.widget<RaftVideoViewer>(viewer);

Future<VideoFixture> launch(WidgetTester tester, List<VideoClip> clips,
    {String mode = 'light', String theme = 'brutal', Future<void> Function()? prepare}) async {
  await lab.reset();
  await prepare?.call();
  final fixture = await buildVideoFixture(
    base: _base,
    mobile: true,
    clips: clips,
    location: '/s/lab',
    mode: mode,
    theme: theme,
  );
  await tester.pumpWidget(fixture.app);
  // Deep-linking the channel route opens it empty (see video_parity_main.dart):
  // start from the workspace list and open the channel the way a user does.
  await until(tester, () => find.text('lab-vp').evaluate().isNotEmpty, 'the channel list');
  await tester.tap(find.text('lab-vp').first);
  await until(tester, () => card(clips.first.filename).evaluate().isNotEmpty || find.byKey(const Key('audio-play-toggle')).evaluate().isNotEmpty,
      'the channel with ${clips.first.filename}');
  return fixture;
}

Future<void> shutdown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 500));
}

bool ready(WidgetTester t, String filename) =>
    card(filename).evaluate().isNotEmpty && find.descendant(of: card(filename), matching: find.byKey(const Key('inline-video-play'))).evaluate().isNotEmpty;

Future<void> openViewer(WidgetTester tester, String filename) async {
  await tapCentre(tester, find.descendant(of: card(filename), matching: find.byKey(const Key('inline-video-expand'))));
  await until(tester, () => viewer.evaluate().isNotEmpty && viewerOf(tester).duration > Duration.zero, 'the viewer to open $filename');
}

Finder get viewerPlay => find.descendant(of: viewer, matching: find.byKey(const Key('inline-video-play')));

Future<void> playInViewer(WidgetTester tester) async {
  await until(tester, () => viewerPlay.evaluate().isNotEmpty, 'the viewer play button');
  await tapCentre(tester, viewerPlay);
  await until(tester, () => viewerOf(tester).playing && viewerOf(tester).position > const Duration(milliseconds: 800), 'the viewer position to advance');
}

/// Closes the viewer the way [how] says and checks nothing of it is left.
Future<void> closeViewer(WidgetTester tester, String how, String name) async {
  await lab.host(tester, 'record-start:$name');
  await tester.pump(const Duration(milliseconds: 700));
  switch (how) {
    case 'button':
      await tapCentre(tester, find.byTooltip('Close preview'));
    case 'key':
      final host = await lab.host(tester, 'back');
      if (host == null) await tester.binding.handlePopRoute();
    case 'swipe':
      final host = await lab.host(tester, 'swipe-back');
      if (host == null) await tester.binding.handlePopRoute();
  }
  await until(tester, () => viewer.evaluate().isEmpty, 'the viewer to close ($how)');
  await tester.pump(const Duration(milliseconds: 600));
  await lab.host(tester, 'record-stop');
  expect(find.byType(PlatformViewLink), findsNothing, reason: 'a native video view survived the viewer ($how)');
}

void report(String what, Map<String, Object?> data) => debugPrint('PS-REPORT $what ${jsonEncode(data)}');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  lab = PlayerLab(_base, hostDriven: _hostDriven);

  Future<void> playInline(WidgetTester tester, String name, {Duration past = const Duration(seconds: 2)}) async {
    await until(tester, () => ready(tester, name), 'the inline card to be ready');
    final centre = tester.getCenter(find.descendant(of: card(name), matching: find.byKey(const Key('inline-video-play'))));
    await tester.tapAt(centre);
    await tester.pump();
    await until(tester, () => cardOf(tester, name).playing && cardOf(tester, name).position > past, 'the inline position to pass $past');
  }

  // ---- inline card: the centre play button ---------------------------------

  scenario('inline: the centre play button starts playback and seeking works', (tester) async {
    await launch(tester, [_portrait]);
    await until(tester, () => ready(tester, 'portrait.mp4'), 'the inline card to be ready');
    expect(cardOf(tester, 'portrait.mp4').playing, false);
    await playInline(tester, 'portrait.mp4', past: const Duration(milliseconds: 800));
    // A tap on the playing picture shows the bar; tap the seek rail at 70 %.
    await tapCentre(tester, find.descendant(of: card('portrait.mp4'), matching: find.byKey(const Key('inline-video-surface'))));
    await tester.pump(const Duration(milliseconds: 300));
    final rail = find.descendant(of: card('portrait.mp4'), matching: find.byKey(const Key('inline-video-seek')));
    expect(rail, findsOneWidget);
    final box = tester.getRect(rail);
    await tester.tapAt(Offset(box.left + box.width * .7, box.center.dy));
    final total = cardOf(tester, 'portrait.mp4').duration;
    await until(tester, () => cardOf(tester, 'portrait.mp4').position > total * .6, 'the seek to land past 60 %');
    // The bar's pause button pauses.
    await tapCentre(tester, find.descendant(of: card('portrait.mp4'), matching: find.byKey(const Key('inline-video-toggle'))));
    await until(tester, () => !cardOf(tester, 'portrait.mp4').playing, 'the pause button to pause');
    await shutdown(tester);
  });

  scenario('inline: taps while the player is still being prepared play when ready', (tester) async {
    await launch(tester, [_slow4k]);
    // 41 MB, above the auto-load size: the card waits for the first tap. The
    // first tap prepares the player (loading); a second tap during that must
    // be kept, not dropped and not toggle the first one off.
    final surface = find.descendant(of: card('hevc4k.mp4'), matching: find.byKey(const Key('inline-video-surface')));
    await until(tester, () => surface.evaluate().isNotEmpty, 'the idle card');
    await tapCentre(tester, surface);
    await tester.pump(const Duration(milliseconds: 20));
    await tapCentre(tester, surface);
    await until(tester, () => cardOf(tester, 'hevc4k.mp4').playing && cardOf(tester, 'hevc4k.mp4').position > const Duration(milliseconds: 500),
        'queued playback to start', timeout: const Duration(seconds: 25));
    await shutdown(tester);
  });

  scenario('inline: a clip is streamed from its URL, not downloaded first', (tester) async {
    await launch(tester, [_slow4k]);
    final surface = find.descendant(of: card('hevc4k.mp4'), matching: find.byKey(const Key('inline-video-surface')));
    await until(tester, () => surface.evaluate().isNotEmpty, 'the idle card');
    await tapCentre(tester, surface);
    await until(tester, () => cardOf(tester, 'hevc4k.mp4').playing && cardOf(tester, 'hevc4k.mp4').position > const Duration(milliseconds: 500),
        'playback to start while streaming', timeout: const Duration(seconds: 25));
    final stats = await lab.stats();
    report('stream-first-frame', {'bytes': stats.bytes('hevc4k.mp4'), 'size': 41607413, 'requests': stats.requests('hevc4k.mp4'), 'dart': stats.dart('hevc4k.mp4')});
    expect(stats.dart('hevc4k.mp4'), 0, reason: 'a Dart-client GET means the clip was downloaded first');
    expect(stats.player('hevc4k.mp4'), greaterThan(0), reason: 'the native player must read the URL itself');
    expect(stats.bytes('hevc4k.mp4'), lessThan(41607413 * .6), reason: 'playback started only after most of the file arrived');
    await shutdown(tester);
  });

  // ---- viewer: one shared stream -------------------------------------------

  scenario('handoff: the viewer continues the card\'s stream and gives it back', (tester) async {
    await launch(tester, [_portrait]);
    await playInline(tester, 'portrait.mp4');
    final before = await lab.stats();
    final cardAt = cardOf(tester, 'portrait.mp4').position;
    final playerBefore = before.player('portrait.mp4');
    expect(VideoPlayerAttachmentPlayer.debugLive, 1);
    await openViewer(tester, 'portrait.mp4');
    final first = viewerOf(tester);
    expect(first.position, greaterThanOrEqualTo(cardAt - const Duration(milliseconds: 150)), reason: 'the position jumped back at the handoff');
    expect(first.playing, true, reason: 'playback stopped at the handoff');
    expect(find.byType(PlatformViewLink), findsNothing, reason: 'an SDR video must stay on the shared texture');
    expect(VideoPlayerAttachmentPlayer.debugLive, 1, reason: 'the viewer made a second player');
    await until(tester, () => viewerOf(tester).position > first.position + const Duration(seconds: 1), 'the viewer position to advance');
    final during = await lab.stats();
    expect(during.player('portrait.mp4'), playerBefore, reason: 'the handoff made the player read the URL again');
    // The only extra request is the HDR probe: ranged, small, once per attachment.
    final probes = [for (final e in during.log) if ('${e['ua']}'.startsWith('Dart')) e];
    expect(probes.length, lessThanOrEqualTo(3));
    expect(probes.every((e) => e['range'] != null && (e['length'] as int) < 1024 * 1024), isTrue, reason: '$probes');
    final last = viewerOf(tester).position;
    await closeViewer(tester, 'button', 'handoff-close');
    expect(cardOf(tester, 'portrait.mp4').playing, true, reason: 'the card did not carry on after the viewer closed');
    expect(cardOf(tester, 'portrait.mp4').position, greaterThanOrEqualTo(last - const Duration(milliseconds: 150)));
    await until(tester, () => cardOf(tester, 'portrait.mp4').position > last + const Duration(seconds: 1), 'the card to advance after the viewer');
    final after = await lab.stats();
    report('handoff-sdr', {'playerRequestsBefore': playerBefore, 'playerRequestsAfter': after.player('portrait.mp4'), 'probeRequests': probes.length, 'probeBytes': probes.fold<int>(0, (n, e) => n + (e['length'] as int)), 'cardAtOpenMs': cardAt.inMilliseconds, 'viewerFirstMs': first.position.inMilliseconds, 'viewerPlaying': first.playing});
    expect(after.player('portrait.mp4'), playerBefore);
    await shutdown(tester);
  });

  Future<void> viewerRoundTrip(WidgetTester tester, String how) async {
    await launch(tester, [_portrait]);
    await playInline(tester, 'portrait.mp4', past: const Duration(milliseconds: 500));
    await openViewer(tester, 'portrait.mp4');
    expect(viewerOf(tester).playing, true);
    await closeViewer(tester, how, 'viewer-close-$how');
    expect(card('portrait.mp4'), findsOneWidget);
    await shutdown(tester);
  }

  scenario('viewer: the close button returns', (tester) => viewerRoundTrip(tester, 'button'));
  scenario('viewer: Android back key returns', (tester) => viewerRoundTrip(tester, 'key'));
  scenario('viewer: back swipe returns', (tester) => viewerRoundTrip(tester, 'swipe'));

  scenario('viewer: a cancelled open (closed at once) leaves the card playing', (tester) async {
    await launch(tester, [_portrait]);
    await playInline(tester, 'portrait.mp4', past: const Duration(milliseconds: 500));
    await tapCentre(tester, find.descendant(of: card('portrait.mp4'), matching: find.byKey(const Key('inline-video-expand'))));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.binding.handlePopRoute();
    await until(tester, () => viewer.evaluate().isEmpty, 'the viewer to be gone');
    await tester.pump(const Duration(milliseconds: 500));
    expect(cardOf(tester, 'portrait.mp4').playing, true);
    expect(VideoPlayerAttachmentPlayer.debugLive, 1);
    await shutdown(tester);
  });

  scenario('viewer: reopening reads only what is watched (no new request)', (tester) async {
    await launch(tester, [_long]);
    await playInline(tester, 'long.mp4', past: const Duration(milliseconds: 500));
    const size = 16383818;
    // The first open reads the colour boxes once (a small ranged probe).
    await openViewer(tester, 'long.mp4');
    await tester.pump(const Duration(seconds: 1));
    await closeViewer(tester, 'button', 'viewer-reopen-0');
    await lab.reset();
    for (var i = 1; i < 3; i++) {
      await openViewer(tester, 'long.mp4');
      await tester.pump(const Duration(seconds: 2));
      await closeViewer(tester, 'button', 'viewer-reopen-$i');
    }
    final stats = await lab.stats();
    report('reopen', {'bytes': stats.bytes('long.mp4'), 'requests': stats.requests('long.mp4'), 'size': size});
    expect(stats.dart('long.mp4'), 0);
    expect(stats.requests('long.mp4'), 0, reason: 'opening the viewer made a new request');
    expect(stats.bytes('long.mp4'), lessThan(size * .35), reason: 'reopening re-read most of the file');
    await shutdown(tester);
  });

  /// The HDR handoff for [clip]: play the card to [seekTo] (a fraction of the
  /// clip, 0 = none), tap the eye and measure the native view's arrival.
  Future<void> hdrHandoff(WidgetTester tester, VideoClip clip, {double seekTo = 0, required int size}) async {
    final name = clip.filename;
    await launch(tester, [clip]);
    await playInline(tester, name, past: const Duration(seconds: 2));
    if (seekTo > 0) {
      await tapCentre(tester, find.descendant(of: card(name), matching: find.byKey(const Key('inline-video-surface'))));
      await tester.pump(const Duration(milliseconds: 300));
      final rail = tester.getRect(find.descendant(of: card(name), matching: find.byKey(const Key('inline-video-seek'))));
      final total = cardOf(tester, name).duration;
      await tester.tapAt(Offset(rail.left + rail.width * seekTo, rail.center.dy));
      await until(tester, () => cardOf(tester, name).position > total * (seekTo - .02), 'the card to seek');
      await tester.pump(const Duration(seconds: 2));
    }
    await lab.reset();
    final cardAt = cardOf(tester, name).position;
    final opened = Stopwatch()..start();
    await tapCentre(tester, find.descendant(of: card(name), matching: find.byKey(const Key('inline-video-expand'))));
    await until(tester, () => find.byType(PlatformViewLink).evaluate().isNotEmpty && viewer.evaluate().isNotEmpty && viewerOf(tester).position > Duration.zero,
        'the native view', timeout: const Duration(seconds: 20));
    final shown = opened.elapsedMilliseconds;
    await until(tester, () => viewerOf(tester).position > cardAt + const Duration(seconds: 2), 'the native player to play on');
    final stats = await lab.stats();
    final requests = [
      for (final e in stats.log.where((e) => e['file'] == clip.file))
        '${'${e['ua']}'.startsWith('Dart') ? 'probe' : 'player'} ${e['range']} (${e['length']} B)',
    ];
    report('hdr-handoff-${clip.id}', {
      'eyeTapToNativeViewMs': shown,
      'handoffMs': debugLastHdrHandoff?.milliseconds,
      'cardAtOpenMs': cardAt.inMilliseconds,
      'viewerStartMs': debugLastHdrHandoff?.start.inMilliseconds,
      'bytesSince': stats.bytes(clip.file),
      'size': size,
      'requests': requests,
    });
    expect(viewerOf(tester).position, greaterThanOrEqualTo(cardAt - const Duration(milliseconds: 500)));
    expect(stats.dart(clip.file), lessThanOrEqualTo(3), reason: 'only the colour probe');
    expect(viewerOf(tester).playing, true);
    final last = viewerOf(tester).position;
    // The first frames of the pop: the native view is already gone.
    await lab.host(tester, 'record-start:hdr-close-${clip.id}');
    await tester.pump(const Duration(milliseconds: 400));
    if (_hostDriven) {
      await lab.host(tester, 'back');
    } else {
      await tester.binding.handlePopRoute();
    }
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(PlatformViewLink), findsNothing, reason: 'the native view was still there when the exit began');
    await until(tester, () => viewer.evaluate().isEmpty, 'the viewer to close');
    await tester.pump(const Duration(milliseconds: 600));
    await lab.host(tester, 'record-stop');
    expect(cardOf(tester, name).playing, true, reason: 'the card did not resume after the native view');
    expect(cardOf(tester, name).position, greaterThanOrEqualTo(last - const Duration(milliseconds: 500)));
    await shutdown(tester);
  }

  scenario('HDR: the viewer takes a native view at the card\'s position and gives it back', (tester) =>
      hdrHandoff(tester, _hlg, size: 5416578));
  scenario('HDR: a long clip handed over deep into the stream', (tester) =>
      hdrHandoff(tester, _longHlg, seekTo: .4, size: 16385074));

  scenario('viewer: Download saves the whole file (system save dialog)', (tester) async {
    await launch(tester, [_portrait]);
    await until(tester, () => ready(tester, 'portrait.mp4'), 'the inline card to be ready');
    await openViewer(tester, 'portrait.mp4');
    await tester.pump(const Duration(seconds: 1));
    await lab.reset();
    await tapCentre(tester, find.byKey(const ValueKey('attachment-preview-download')));
    final saved = await lab.host(tester, 'save-dialog:portrait.mp4');
    if (saved == null) {
      markTestSkipped('needs the host runner for the system save dialog');
    } else {
      expect(saved, 'saved:5416578');
      final stats = await lab.stats();
      expect(stats.bytes('portrait.mp4'), greaterThanOrEqualTo(5416578));
    }
    await shutdown(tester);
  });

  scenario('streaming: an expired signed URL is signed again once', (tester) async {
    final fixture = await launch(tester, [_portrait], prepare: () => lab.failNext('portrait.mp4', status: 403, count: 1));
    await until(tester, () => ready(tester, 'portrait.mp4'), 'the card to recover from the 403', timeout: const Duration(seconds: 25));
    expect(fixture.urlRequests('vp-portrait'), 2, reason: 'one signature for the 403, one fresh one');
    await shutdown(tester);
  });

  scenario('streaming: a clip the system cannot decode shows the download state', (tester) async {
    await launch(tester, [_corrupt]);
    await until(tester, () => find.byKey(const Key('inline-video-download')).evaluate().isNotEmpty, 'the failure state');
    await shutdown(tester);
  });

  scenario('inline audio: a tap plays and the position advances', (tester) async {
    await launch(tester, [_tone]);
    final toggle = find.byKey(const Key('audio-play-toggle'));
    await until(tester, () => toggle.evaluate().isNotEmpty, 'the audio card');
    await tapCentre(tester, toggle);
    await tester.pump(const Duration(seconds: 2));
    final stats = await lab.stats();
    expect(stats.dart('tone.wav'), 0);
    expect(stats.player('tone.wav'), greaterThan(0));
    await shutdown(tester);
  });

  // ---- the viewer's black stage: every state legible in every theme -----------

  scenario('viewer stage: connecting, buffering and failed are legible in every theme', (tester) async {
    for (final (mode, theme) in const [('light', 'brutal'), ('light', 'elegant'), ('dark', 'elegant')]) {
      final tag = '$theme-$mode';
      // Connecting: the host answers a byte a second, so the player has not
      // opened yet when the viewer is on screen.
      await launch(tester, [_stall], mode: mode, theme: theme);
      await tester.pump(const Duration(seconds: 1));
      await tapCentre(tester, find.descendant(of: card('stall.mp4'), matching: find.byKey(const Key('inline-video-expand'))));
      await tester.pump(const Duration(milliseconds: 1200));
      expect(viewer, findsNothing, reason: 'the viewer shows the spinner on its stage, not the player yet');
      expect(find.byType(RaftSpinner), findsWidgets);
      expect(find.byType(RaftFileTransferPanel), findsNothing, reason: 'no download panel on the video stage');
      await lab.host(tester, 'shot:stage-connecting-$tag');
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 1));
      await shutdown(tester);
      // Buffering: the host is slower than the clip plays.
      await launch(tester, [_choke], mode: mode, theme: theme);
      await until(tester, () => ready(tester, 'choke.mp4'), 'the choked card to open', timeout: const Duration(seconds: 40));
      await openViewer(tester, 'choke.mp4');
      await tapCentre(tester, viewerPlay);
      await until(tester, () => viewerOf(tester).buffering, 'the viewer to show buffering', timeout: const Duration(seconds: 60));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.descendant(of: viewer, matching: find.byKey(const Key('inline-video-buffering'))), findsOneWidget);
      await lab.host(tester, 'shot:stage-buffering-$tag');
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 1));
      await shutdown(tester);
      // Failed: a file the system cannot play.
      await launch(tester, [_corrupt], mode: mode, theme: theme);
      await until(tester, () => find.byKey(const Key('inline-video-download')).evaluate().isNotEmpty, 'the failure state');
      await lab.host(tester, 'shot:stage-card-failed-$tag');
      await tapCentre(tester, find.descendant(of: card('broken.mp4'), matching: find.byKey(const Key('inline-video-expand'))));
      await until(tester, () => find.byType(RaftLoadError).evaluate().isNotEmpty, 'the viewer failure message');
      await tester.pump(const Duration(milliseconds: 400));
      await lab.host(tester, 'shot:stage-failed-$tag');
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(seconds: 1));
      await shutdown(tester);
    }
  });

  // ---- memory --------------------------------------------------------------

  scenario('memory: the player is released when playback ends and when the page is hidden', (tester) async {
    await launch(tester, [_big4k]);
    final name = 'hevc4k.mp4';
    final surface = find.descendant(of: card(name), matching: find.byKey(const Key('inline-video-surface')));
    await until(tester, () => surface.evaluate().isNotEmpty, 'the idle card');
    final idle = await lab.host(tester, 'meminfo:idle');
    await tapCentre(tester, surface);
    await until(tester, () => cardOf(tester, name).playing && cardOf(tester, name).position > const Duration(seconds: 1), 'playback', timeout: const Duration(seconds: 25));
    final playing = await lab.host(tester, 'meminfo:playing');
    expect(VideoPlayerAttachmentPlayer.debugLive, 1);
    // To the end (the clip is 8 s).
    await until(tester, () => VideoPlayerAttachmentPlayer.debugLive == 0, 'the player to be released after the end', timeout: const Duration(seconds: 40));
    await tester.pump(const Duration(seconds: 2));
    final ended = await lab.host(tester, 'meminfo:ended');
    expect(find.byKey(const Key('inline-video-play')), findsNothing);
    await lab.host(tester, 'shot:memory-ended-still');
    report('memory-ended', {'idle': idle, 'playing': playing, 'ended': ended});
    // Play again from the still, then leave the page.
    await tapCentre(tester, surface);
    await until(tester, () => cardOf(tester, name).playing && cardOf(tester, name).position > const Duration(milliseconds: 800), 'replay', timeout: const Duration(seconds: 25));
    expect(VideoPlayerAttachmentPlayer.debugLive, 1);
    await tester.binding.handlePopRoute(); // channel -> list: the card's page is hidden
    await until(tester, () => VideoPlayerAttachmentPlayer.debugLive == 0, 'the player to be released after the page was hidden', timeout: const Duration(seconds: 15));
    await tester.pump(const Duration(seconds: 1));
    final hidden = await lab.host(tester, 'meminfo:hidden');
    report('memory-hidden', {'hidden': hidden});
    await shutdown(tester);
  });
}
