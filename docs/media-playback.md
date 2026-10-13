# Attachment media playback

Inline video cards, the media viewer and audio attachments play through one interface,
`AttachmentPlayer` (`apps/raft_flutter/lib/platform/attachment_player.dart`). The engine depends on the platform;
`createAttachmentPlayer` (`attachment_player_factory.dart`) chooses it.

| Platform | Engine | Why |
| -------- | ------ | --- |
| Android  | `video_player` -> ExoPlayer (Media3), `VideoPlayerAttachmentPlayer` | System codecs, hardware decoding and colour handling; no libmpv in the APK |
| iOS      | `video_player` -> AVPlayer | Same; HDR/EDR handled by the system |
| macOS    | `video_player` -> AVPlayer | Same |
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

* Source: always the private local copy (`InlineMediaFiles`, `AttachmentPreviewFiles`); no URL, header or credential
  reaches the player (`proxy_hook_guard_test` keeps the media_kit side file-only).
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
* Android surface: the default texture view (`VideoViewType.textureView`). A platform view (SurfaceView) can show HDR
  without tone mapping but breaks clipping, overlays and list scrolling for inline cards; ExoPlayer/MediaCodec
  tone-map HDR to SDR for the texture, which is the expected look on SDR screens.
* Formats are the system's: AVPlayer does not play WebM/MKV/Ogg, so those show the failure state on iOS and macOS with
  "Download to view" (media_kit played them).

## Verification record

* Android emulator (API 36, x86_64, isolated `app.raft.raft_flutter.linkperf`), 2026-10-13, with
  `integration_test/video_parity_main.dart` (`VP_LOC=/s/lab`, then open the channel; samples served by
  `tool/video-parity-range-server`): H.264 720p landscape and portrait, 1080p HEVC Main and Kevin's 4K HEVC Main 8-bit
  bt709 30 fps clip show the first frame, play, advance and pause; the WAV plays; an undecodable file shows the
  failure state. The Dolby Vision 8.4 / HLG 4K clip fails on the emulator only:
  `MediaCodecVideoRenderer error ... video/dolby-vision dvhe.08.07 3840x2160 BT2020 HLG 10bit
  format_supported=NO_EXCEEDS_CAPABILITIES` (the emulator's goldfish HEVC decoder has no 4K 10-bit profile); that needs a
  phone.
* Linux: `native_player_test` (media_kit) passes under Xvfb on the new dependency set.
* iOS and macOS cannot be built on the Linux development host; see the hand-off checklist in the change description.
