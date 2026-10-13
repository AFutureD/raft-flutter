# Attachment media playback

Inline video cards, the media viewer and audio attachments play through one interface,
`AttachmentPlayer` (`apps/raft_flutter/lib/platform/attachment_player.dart`). The engine depends on the platform;
`createAttachmentPlayer` (`attachment_player_factory.dart`) chooses it.

**Video (and inline audio) is streamed, not downloaded.** The player opens the attachment's signed URL itself and reads the byte ranges it
needs; nothing is written to disk by the player, and a file is saved only when the user taps Download
(`AttachmentFiles.save`, system save dialog). The audio *viewer* plays the cached file like PDF and documents (Settings >
Storage). An inline card and the full-screen viewer of the same attachment share
one player (one stream, one buffer, one position); see [Streaming and sessions](#streaming-and-sessions).

| Platform | Engine | Why |
| -------- | ------ | --- |
| Android  | `video_player` -> ExoPlayer (Media3), `VideoPlayerAttachmentPlayer` | System codecs, hardware decoding and colour handling; no libmpv in the APK; viewer HDR through a `SurfaceView` |
| iOS      | `video_player` -> AVPlayer | Same; viewer HDR/EDR through `AVPlayerLayer` (cards are SDR) |
| macOS    | `video_player` -> AVPlayer | Same; viewer HDR through `AVPlayerLayer` |
| Windows  | media_kit (libmpv + bundled FFmpeg), `NativeAttachmentPlayer` | Media Foundation needs the optional HEVC extension |
| Linux    | media_kit (libmpv + bundled FFmpeg), `NativeAttachmentPlayer` | Stock GStreamer (Fedora) has no H.264/HEVC; `tool/prepare-media-linux` still supplies the runtime ([Linux runtime](linux-media-runtime.md)) |

## Dependencies

`pubspec.yaml` depends on `media_kit`, `media_kit_video`, `media_kit_libs_linux`, `media_kit_libs_windows_video` and
`video_player`. It does **not** depend on `media_kit_libs_video` (the umbrella pulls `media_kit_libs_android_video`,
`media_kit_libs_ios_video` and `media_kit_libs_macos_video`, i.e. libmpv/FFmpeg on every platform). `media_kit_video`
still registers a native plugin on Android, iOS and macOS; without a libs package its Apple podspecs build the stub
sources and its Android plugin is a small Java class, and nothing initialises media_kit there:
`MediaKit.ensureInitialized()` runs only inside `NativeAttachmentPlayer`, which only Windows and Linux construct.

## Behaviour of `VideoPlayerAttachmentPlayer`

* Source: `AttachmentSource.network(url, refresh:, start:)`, the signed `disposition=inline` URL
  (`VideoPlayerController.networkUrl`; media_kit `loadfile`). No header is sent: the signature in the URL is the only
  credential. A local `AttachmentSource.file` is still accepted (tests). On the first failure of a streamed source the
  player signs the URL again once (`refresh`) and carries on from where it was; `video_player` reports a rejected
  request as a bare "Source error", so any first failure triggers the one re-sign (mpv: the first reported failure).
* Opens paused at the first frame; `hasFrame` becomes true once the picture widget was built with a known size
  (the poster beneath goes then); until then the backdrop is transparent when `transparentVideo` is set.
* Errors: a failed open publishes `error` and rethrows (the card shows "Download to view"); a runtime player error
  (`VideoPlayerValue.hasError`) is a failure and stays one. Buffering is not. The reason is written with
  `debugPrint` as a redacted `raft.media: [error] video_player: ...` line (logcat on Android).
* Volume is 0-100 like media_kit (video_player takes 0-1). Toggling a finished clip restarts from 0.
* Leaving the app pauses (`AppLifecycleState.paused`); returning does not resume. `video_player`'s own observer, which
  resumes, is disabled with `allowBackgroundPlayback`.
* No timers of its own (`idle_work_guard_test`); video_player polls the position every 100 ms only while playing.
* The picture is `VideoPlayer` in an `AspectRatio`, centred (contain) inside the box the card gives it.
* Colour and HDR. Two surfaces, chosen by the caller (`createAttachmentPlayer(hdr: ...)`; see "Streaming and sessions"
  for which player the viewer uses):
  * Inline cards (and any list) use the plugin's texture (`VideoViewType.textureView`). The texture is SDR on every
    platform: Android's ExoPlayer/MediaCodec tone-map HDR to SDR for the texture, and `video_player_avfoundation`
    (2.12.1) declares BT.709 8-bit BGRA output settings, which makes AVFoundation tone-map on iOS and macOS. HDR clips
    therefore look SDR (tone-mapped) in the message list, which is the expected look there. A platform view in a
    scrolling list would break clipping, overlays and scroll sync and cost battery.
  * The full-screen media viewer (`AttachmentPreviewDialog`, opened from the eye button; its fullscreen toggle is the
    same widget tree) shares the card's texture player (SDR, seamless). Only an HDR video, detected from the file's
    colour boxes, gets a player of its own with the native view (`VideoViewType.platformView`): a `SurfaceView` on Android and an
    `AVPlayerLayer` on iOS and macOS. They hand the picture to the system compositor untouched, so HDR (HDR10, HLG,
    Dolby Vision) is shown as HDR on an HDR-capable display. Pending device verification on a real HDR phone, iPhone
    and Mac. The overlay controls (`RaftVideoOverlay`) are Flutter
    widgets drawn above the platform view, which is only on screen while the route rests (a black stage during the
    transitions); the audio-only viewer builds no picture and keeps the texture setting.
  * Android needs no window colour mode (`COLOR_MODE_HDR`) and the runner is unchanged: Android's HDR playback guide
    (developer.android.com/media/grow/hdr-playback) says standard `MediaCodec` playback into a `SurfaceView` displays
    HDR without special handling, and that `TextureView` transcodes HDR to SDR (the reason cards stay SDR). The colour
    mode is for HDR content the app draws itself (UI, bitmaps, GL).
  * Apple: the plugin's native view is a plain `AVPlayerLayer` (a layer-backed `NSView` on macOS) and sets no
    `wantsExtendedDynamicRangeContent`; AVPlayerLayer presents HDR on EDR-capable displays by itself. If a Mac shows
    the viewer as SDR, that flag on the layer is the thing to try (needs a plugin override, not applied). macOS uses the
    shared Dart code, which embeds the view with `UiKitView` (supported since video_player_avfoundation 2.8.0 per its
    changelog); not exercised on a Mac from the Linux host.
  * Windows and Linux (media_kit) are unchanged and ignore the flag.
* Formats are the system's: AVPlayer does not play WebM or MKV, so those show the failure state on iOS and macOS with
  "Download to view" (media_kit played them). Ogg/Vorbis audio did play on macOS (CodexMac, 2026-10-13), so Ogg is not
  assumed unsupported; check per file.

## Streaming and sessions

Why: 8074 downloaded the whole attachment (up to 50 MB) before the first frame, again for the viewer, again on every
reopen. Now:

| | Inline card | Viewer |
| --- | --- | --- |
| Source | signed URL streamed by the player; prepared once the card has been near the viewport for 250 ms (unchanged: cards flung past start nothing; videos over 24 MB wait for the first tap) | the card's player when one exists, else the same URL |
| First frame | when the player has the first range (`moov` + first samples) | immediately when handed over |
| Download | the card's Download action | the viewer's Download action; both still save to disk through the system picker |

* **Sessions** (`platform/attachment_player_sessions.dart`, `WorkspaceController.playerSessions`): one player per
  attachment version, keyed `id|version`. Holders (a card, a viewer) `acquire` and `release`; the player is disposed the
  moment the last holder is gone, never by a widget's `dispose` alone, and nothing lingers (a viewer closed with no card
  frees its decoder at once). A viewer outlives a card that scrolled away; a card outlives the viewer it opened. At most
  2 players are live: a third evicts the least recently used one that no viewer holds and that is not playing. An
  identity change (`attachmentImageScope`) or a revoked channel drops everything. The sessions also remember, per
  attachment, which cards prepared it (`prepared`), where it stopped (`resumeAt`) and a small still picture (`stills`, 24
  at most, a card's size each).
* **Handoff.** Tapping the eye neither pauses nor re-creates anything. The viewer acquires the card's session (same
  controller / `Player`): position, buffer, volume and audio continue and no request is made. The card does not pause
  while a viewer holds the player (the covered-route and scrolled-away pauses are skipped); on close it continues, playing
  or paused, from the position the viewer reached.
* **HDR exception (Android, iOS, macOS).** The native video view (`SurfaceView`, `AVPlayerLayer`) is the only way to get
  HDR output and a `VideoPlayerController`'s `viewType` is fixed at creation, so an HDR video cannot share the card's
  texture player. The viewer starts on the shared texture player (seamless), reads the file's colour boxes with one to
  three ranged GETs (`mp4_hdr_probe.dart`: `colr`/`nclx` transfer 16 = PQ or 18 = HLG, `dvcC`/`dvvC` = Dolby Vision;
  never the codec or extension: HEVC is mostly SDR) and, if HDR, opens a second player with `viewType: platformView`
  at the card's position (streaming reads only the rest), pauses the shared one and shows the native view; on the first
  moment of any pop it releases the native view, seeks the shared player to the native position and the card carries on
  from there. A server that ignores ranges, a non-MP4/MOV file or an unreadable header give no verdict: SDR, shared
  texture. Verdicts are cached per attachment in the sessions. SDR clips never create a second player.
  Measured on the Android emulator (API 36) with the local range server, an HLG-tagged 5.4 MB / 19 s clip and a 16 MB
  / 287 s clip handed over at 116 s (suite runs of 2026-10-13, `PS-REPORT hdr-handoff-*` in `suite.log`): the eye tap
  to the native view on screen takes 479-533 ms; from the HDR verdict to the native player playing 102-154 ms. Requests:
  the colour probe (one ranged GET of 64 KB; the long clip's `moov` sits behind `mdat` and needed a second, 250 KB),
  then the native player's own, which do **not** start at the card's position: ExoPlayer opens one open-ended GET from
  byte 0 (the head and `moov`), and for the long clip a second one at the position (`bytes=6417379-`, 40 % of the
  file). `video_player` has no start-position option, so the seek happens after prepare. Bytes the server sent since the
  eye tap (unthrottled loopback, the first GET is only cancelled when the second arrives): 5.48 MB for the short clip, 26.7
  MB for the long one. The exit of the HDR path still shows about 230 ms of a stale frame from the native view before the
  fade (visible in `hdr-close-*.mp4`; the SDR exit is clean, see the close recordings); the native view is removed from
  the tree and its player disposed at the first moment of the pop, the remaining lag is the platform view's teardown.
  A fully seamless HDR handoff needs the native ExoPlayer/AVPlayer kept and only its output `Surface` / `AVPlayerLayer`
  swapped; `video_player` has no such API, so it would need a plugin extension (out of scope).
* **Memory.** A decoder holds tens of megabytes of frame buffers (a 2160x3840 clip: ~31.6 MB each, 9 of them were seen
  left behind). A card therefore releases its player (`InlineMediaLoader.releasePlayer`) and keeps a downscaled still
  (`RepaintBoundary.toImage`, 1.5x of the card) when playback **ends**; when it is **scrolled out** of view, its page is
  **hidden** (`TickerMode` off) or the app **backgrounded**, after a 3 s grace (coming back inside it cancels); and when
  the soft cap of **2 live players** is exceeded (it shows its still and waits for a tap; playing players and the one a viewer holds are never evicted, so the count can go above 2 when all of them are). A card does **not** prepare a
  released player again by itself, and a card built again for an attachment already prepared this session (a list drops
  rows far from the viewport) shows the session's still and prepares on a tap, at the position it stopped at
  (`resumeAt`): a new stream every time a clip scrolled back into view would spend the server's attachment limit (the
  `rate_limit_scroll_budget_test` counts 18 stream opens for 17 clips over 30 s of fast scrolling; with re-preparing on
  every return it was 101, and 28 requests were refused with 429 on server-streamed storage). Never while the viewer
  holds the player. Measured on the emulator (4K HEVC clip, `memory` scenario, `dumpsys meminfo` and `ps`): the media
  codec processes' RSS 89.8 MB (idle card) -> 202.7 MB (playing) -> 89.3 MB (after the end) and 89.2 MB (after the page
  was hidden); the app's Java heap in use 4.5 -> 43.4 -> 4.6 MB. The app's PSS stays about where playback left it
  (322.6 -> 351.0 -> 351.8 MB: the allocator does not hand pages back at once) and `Graphics` reads 0 on the emulator, so
  the frame-buffer saving Kevin measured on a phone (9 x 31.6 MB) shows here as the codec processes' RSS.
* **Buffering.** `AttachmentPlayback.buffering` (ExoPlayer/AVPlayer buffering, mpv `buffering`) draws a spinner over
  the picture. The viewer no longer shows a download panel for video: while the player opens, the black stage
  shows a centred spinner (Web's `<video>` has no custom loading UI), a failure shows `RaftLoadError(onDark: true)` in
  light text, and the close control stays in the header. The panel remains for PDF and for the audio viewer, which play the
  cached file (`AttachmentPreviewFiles.loadCached`, Settings > Storage) on the light stage.
* **Taps are never dropped.** A tap on a card whose player is not ready (idle, loading, released) is queued and plays as
  soon as the player is ready (`playRequested`); the picture is interactive in every state but failed.
* **Re-opening.** `video_player_android` (ExoPlayer, Media3 1.9) has no disk cache option and `video_player` exposes no
  cache at all; AVPlayer buffers in memory. A viewer opened from its card needs no request (it takes the card's player).
  A viewer opened with no card, or a card prepared again by a tap after its player was released, streams again and
  reads only what is played: ExoPlayer's read-ahead is about 50 s of media, so on a long clip that is a fraction of the
  file (the suite's 16 MB / 287 s clip: about 2.5 MB), a clip shorter than the read-ahead is fetched whole but streamed.
  That is the accepted behaviour; there is no app-level file cache for video (the attachment disk cache of Settings >
  Storage serves images, documents, PDF and the audio viewer, not video).
* **Rate limit** (`packages/raft_client/lib/src/server_rate_limits.dart`: every request under `/api/attachments`
  counts, 120 per minute per user). The player's own requests do not pass through `AttachmentHttp.governor`. A
  presigned storage URL on another host is not counted at all. When the Raft server streams the bytes itself (a URL path
  under `/api/attachments`), `attachmentStreamSource` admits the first request through the governor (paced, or refused
  after the 30 s `maxWait`, which the card shows as "Download to view") and the usual one to three requests of a
  progressive MP4 stay inside the governor's 25 % headroom. ExoPlayer opens one open-ended `GET` (plus one for a `moov`
  at the end of the file); AVPlayer makes more, short range requests. Seeks add one request each. A column of auto-loading
  cards is bounded by the 250 ms settle rule, the 24 MB auto-load size and the soft cap of 2 live players (playing or viewer-held players are exempt).
* **Proxy.** mpv (Windows/Linux) gets `http-proxy` from the app's decision at run time; ExoPlayer and AVPlayer follow the
  OS proxy only, so Settings > Network *Manual*/*No proxy* do not apply to streamed media on Android/iOS/macOS (see
  [system proxy](system-proxy.md)).

## Verification record

* Viewer surface tests (`viewer_video_surface_test`, `video_player_attachment_player_test`, `player_sessions_test`,
  `mp4_hdr_probe_test`): on Android, iOS and macOS a card and its viewer share one `textureView` player on a streamed
  network source; an HDR video gets a second `platformView` player; closing the viewer frees the players.
* Android emulator (API 36, x86_64, isolated `app.raft.raft_flutter.linkperf`), 2026-10-13, with
  `integration_test/video_parity_main.dart` (`VP_LOC=/s/lab`, then open the channel; samples served by
  `tool/video-parity-range-server`): H.264 720p landscape and portrait, 1080p HEVC Main and Kevin's 4K HEVC Main 8-bit
  bt709 30 fps clip show the first frame, play, advance and pause; the WAV plays; an undecodable file shows the
  failure state. The Dolby Vision 8.4 / HLG 4K clip fails on the emulator only:
  `MediaCodecVideoRenderer error ... video/dolby-vision dvhe.08.07 3840x2160 BT2020 HLG 10bit
  format_supported=NO_EXCEEDS_CAPABILITIES` (the emulator's goldfish HEVC decoder has no 4K 10-bit profile); that needs a
  phone.
* Linux: `tool/flutter build linux --debug` builds; `native_player_test` passes under Xvfb (`xvfb-run -a tool/flutter
  test integration_test/native_player_test.dart -d linux --dart-define=RAFT_TEST_REPORT=<dir>`), including a new streaming
  test: mpv reads a loopback `http` URL with ranges, and signs again after a 403 (the first failure of a streamed source).
* Android emulator suite (2026-10-13, API 36 x86_64, `.linkperf`): all 18 scenarios of the interaction suite pass on
  this branch; on the previous build the centre-play scenario fails (the suite is the reproduction).
* iOS and macOS cannot be built on the Linux development host; see the hand-off checklist in the change description.

## What 8074 got wrong (root causes)

* **Dead centre play button.** `RaftVideoControlBar` is 112 px tall and anchored to the bottom of the picture; its
  hover `MouseRegion` was hit-opaque. A phone card is 16:9 at `screen width - 112` (about 300 x 170), so the bar's box
  reached past the middle and swallowed the tap (no recognizer in it; hit-testing stops at the first opaque child, so
  the picture's `GestureDetector` beneath never saw it). Cards of the maximum 448 px (252 px tall), the viewer and every
  desktop card were not affected, and the fake-player widget tests tapped such a card. Fixed with a translucent region
  (`video_centre_tap_test`; the interaction suite reproduces it on the unfixed build). A tap while the player is still
  being prepared used to be dropped as well; it is queued now.
* **Close judder.** The viewer always used the platform view (`SurfaceView`), which does not move or fade with Flutter
  content, so during the page's exit it lagged, showed a stale frame and then vanished before the fade. SDR videos now
  share the card's texture player (no platform view at all); an HDR video's native view is only on screen while the
  route rests and is removed at the first moment of any pop (route animation `reverse`, back gesture in progress).
  Recordings of the exit (system animations on, button / back key / back swipe) on the 8074 build and on this change are
  kept with the hand-off (`viewer-close-*.mp4`); frame sheets: before = video lag, stale frame, then black; after = the
  page and its picture fade together.
* **Download on every open.** Cards downloaded a private copy, the viewer downloaded its own, deleting it on close.
  Now neither downloads: see above.

## Interaction suite (Android emulator)

`apps/raft_flutter/integration_test/player_interactions_test.dart` drives the production app (fixture workspace, no
login) on a real emulator with the real `video_player`/ExoPlayer, real taps through the gesture arena, real route
transitions and a real HTTP server that counts what it sends. The existing widget tests use a fake player and cannot
see any of this: 8074's dead centre play button passed every widget test (the fake never sat under a hit-opaque control
bar) and only the emulator reproduced it.

```sh
# one-off: the media (faststart copies; moov-at-end originals also work), see tool/player-interactions --help
tool/player-interactions --serial emulator-5600 --media /tmp/player-streaming/media --out /tmp/player-streaming/run --build
```

The runner starts `tool/video-parity-range-server` (S3-like ranges, `?rate=` throttle, `/__stats`, `/__fail`), `adb
reverse`s it, builds the profile APK of the isolated app `app.raft.raft_flutter.linkperf` (never the real app), drives
it with `flutter drive` and answers the test's host commands: Android back key, a back swipe from the left edge,
screenshots, `screenrecord` of the close animation, `dumpsys meminfo`, the system save dialog. Output in `--out`:
`suite.log` (test output and logcat), `server.log`, `host.log`, recordings and screenshots. `--only <part of a
scenario name>` builds a subset in; `--no-host` skips the host-driven steps. Start your own emulator on a free port
(`-read-only` when the AVD is shared) and never point it at a phone with the real app.

Scenarios (`PS-REPORT` lines in `suite.log` carry the measured numbers):

| Scenario | What it asserts |
| --- | --- |
| centre play | tap the big button on a ready phone-sized card: playing, position advances; tap the seek rail: lands past 60 %; the bar button pauses |
| tap while preparing | two taps on an idle 41 MB card (the second during loading): plays, not toggled off |
| streamed, not downloaded | 41 MB clip served at 2 MB/s: the position advances with fewer than 60 % of the bytes sent; no request from the Dart client (`User-Agent: Dart/`), the native player reads the URL |
| handoff | card playing, eye: viewer position continuous (no jump back), still playing, no platform view, one native player, **no new request**; close: the card carries on from the viewer's position |
| close button / back key / back swipe | each closes the viewer, no native view left, the card still there; recordings of the exit |
| cancelled open | eye and an immediate back: the card keeps playing, one player |
| reopen | open and close the viewer twice on a 16 MB / 287 s clip: zero new requests, under 35 % of the file read |
| HDR | an HLG-tagged clip: native view at the card's position, exit without a native view on the first frames of the pop, card resumes; handoff time and requested ranges reported |
| Download | system save dialog, whole file written to Downloads, size matches |
| expired URL | the host answers 403 once: signed again once, plays |
| undecodable | "Download to view" |
| audio | tap plays; streamed |
| viewer stage | connecting, buffering and failed on the black stage in brutal-light, elegant-light and elegant-dark, screenshots |
| memory | the 4K clip played to its end frees the player, and so does hiding its page; `dumpsys meminfo` before and after |

### Checklist for player changes

Run before merging anything under `platform/*player*`, `platform/attachment_stream.dart`,
`features/inline_attachment_media.dart`, `features/attachment_preview_dialog.dart` or `raft_ui` video controls:

1. Unit and widget tests: `inline_attachment_media_test`, `attachment_preview_test`, `video_player_attachment_player_test`,
   `viewer_video_surface_test`, `player_sessions_test`, `mp4_hdr_probe_test`, `attachment_stream_test`,
   `attachment_player_fit_test`, `media_controls_guard_test`, `idle_work_guard_test`, `proxy_hook_guard_test`, raft_ui
   `video_viewer_test`, `video_idle_hide_test`, `video_centre_tap_test`, and the `rate_limit_*` tests.
2. `tool/flutter analyze` and `python3 tool/ds-audit --check`.
3. **The interaction suite above on an Android emulator** (real taps, route transitions, server byte counts). A change
   that only passes with a fake player is not verified. Keep the recordings of the viewer close (button, back key, back
   swipe) and the suite log with the change.
4. `tool/flutter build linux` (media_kit streaming compiles) and, with Xvfb, `integration_test/native_player_test.dart`.
5. **The attachment open smoke** (`tool/attachment-open-smoke/run`, below): every attachment kind from every entry point on
   an Android emulator and on Linux. Run it before merging anything under `features/attachment_*`,
   `features/inline_attachment_media.dart`, `platform/attachment_*`, `data/attachment_*` or the workspace controller's
   attachment URL code, and fix every FAIL it reports.
6. iOS/macOS cannot be built on the Linux host: say so in the hand-off and list what a Mac must check (handoff, native
   view HDR switch, back swipe, memory).

### Attachment open smoke

`tool/attachment-open-smoke/run --platform android --serial <your emulator> --out <dir> --build` (or `--platform linux`)
runs `integration_test/attachment_open_smoke_test.dart` against the production app and a fixture server that behaves like
Raft's storage and API: presigned storage URLs, the server streaming the bytes itself (token in the query), a 302 to
storage, thumbnails (ok, missing, expired), a first signature that is already expired, and range reads. Cases: jpg, png,
webp, gif, heic, SVG (rasterised thumbnail and without), PDF (also 30 MB), text, Markdown (also Chinese and two real
report.md files), CSV, XLSX, code, JSON, HTML (WebView on Android, close and reopen), m4a, mp3, wav, ogg, H.264, HEVC,
WebM, a 30 MB clip, zip, unknown binary, a 30 MB zip, DOCX. Entry points (`--entries`): `list`, `search`, `thread`,
`forward`, `joint`, `files`, `viewer` (Download pressed inside the viewer), `hidden` (a row released while a viewer covers it).
Each case reports whether it opened, the time to the first content, a reopen time and the requests the server saw;
failures come with a screenshot. `--only id,id` filters; `--tree <checkout>` runs the same suite on an older build.
The Android save picker (Kotlin) is replaced by a mock that writes to a temp directory; everything else is real.
