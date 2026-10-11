# Android return crash and Home bell — 2026-10-11

## Device evidence

The connected phone reports an `APP CRASH(NATIVE)`, SIGSEGV, on the UI thread at
18:52:39 after Android completed a system Back gesture. The fault address is
`0x28`, with a null pointer dereference. Earlier 16:39 and 17:39 crashes have the
same PC (`0x8a0504`) and engine Build ID.

Engine symbols for the FVM-pinned Flutter 3.47.6 revision
`692136cb6582dbfc5af3fb33c2515a069f2f66d0` were downloaded following Flutter's
[official symbolication procedure](https://github.com/flutter/flutter/blob/master/docs/engine/Crashes.md).
Their Build ID matches the device: `3042c18dd243797671f94adc831f8ada24daec26`.
The fault resolves to `ReusableFragmentShader::as_image_filter`, called by
`ImageFilter::initShader`.

Raw logs, exit history, symbols and the original failed bell regression are
retained in git-ignored `.local/android-return-debug/`. The earlier 06:12 Vulkan
driver SIGABRT has a different signature and is not treated as fixed here.

## Reproduction and corrected diagnosis

The initial `3c7fd61` mitigation globally replaced Android stretch with glow.
It removed a trigger but changed the scrolling experience. The original
explanation attributed the trigger to filter equality; that was incomplete:
comparison of filters using different shader instances short-circuits before
the native comparison. Release AOT Dart frames were not available, so the
device trace alone did not identify the Dart caller.

The follow-up uses the FVM-pinned 3.47.6 FlutterTester with
`--enable-impeller`; shader-filter support is confirmed. Hiding a stretch
subtree, rebuilding it twice, and capturing its retained layer reproduces
SIGSEGV at `0x28`, with the same `as_image_filter` / `initShader` stack as the
phone. A fixture using the actual `MobileWorkspacePages` also crashes on its
first early return. Native failures and controls are retained in ignored
`.local/stretch-research/` and `.local/stretch-fix/`.

`MobileWorkspacePages` replaces an entering page with an image and keeps its
live subtree mounted at zero opacity. The SDK replaces and disposes stretch
shaders during build. An invisible subtree can rebuild without repainting;
its retained layer can still hold a lazily converted filter for a shader that
has since been disposed. Previously, `freeze()` re-rasterized this hidden
layer when returning during the transition.

The application's capture helper directly uses `OffsetLayer.toImageSync`.
It bypasses the completed-paint precondition documented on
[RenderRepaintBoundary.toImageSync](https://api.flutter.dev/flutter/rendering/RenderRepaintBoundary/toImageSync.html).
The standalone normal-stretch, completed-paint capture, and completed-image
reuse controls each pass 30 cycles. Disabling the fade snapshot optimization
also passes 20 early-return cycles, but would discard that optimization.

## Fix while preserving stretch

When an entering snapshot is on screen, `freeze()` now retains that image
using `ui.Image.clone()` rather than capturing the hidden live subtree.
The clone is a separate disposable handle sharing the same underlying pixels;
it does not allocate another full-sized image or re-rasterize the page. Existing
route cleanup disposes both handles. The normal visible-page capture path and
the snapshot optimization remain in place.

The global glow override is removed, restoring Flutter's default overscroll
decoration, including Android's Material 3 stretch. No SDK, rendering engine,
scroll physics, or page transition configuration is changed.

`mobile_workspace_stretch_snapshot_test.dart` covers 20 early returns after
hidden shader rebuilds, verifies shared image memory and disposal of both
handles, and exercises 10 predictive-Back cancellations followed by live
content updates and commits. The same targeted suite also covers existing
route identities, retained scroll state and the Home bell in three themes.
The native run passes 13 tests; an additional native late-content/early-return
probe passes 20 cycles. These are host-engine/fixture results. Physical Android
gesture acceptance and profile frame-time comparison are not claimed.

## Home bell input

`RaftSectionPager` reserved Android's system Back edge even when
`swipeEnabled:false`. The outer workspace retention pager includes Home's
header. The configured Moto edge width covered the bell's center, so its
rendered button and attention dot were visible but its pointer input was
discarded before reaching the control.

Only swipe-enabled pagers now reserve that edge. A three-theme actual RaftApp
regression reproduces a 40dp side reservation, taps the bell, opens the center,
closes it with Back without leaving Home, and opens it again. Existing
swipe-enabled system-edge tests still verify that Back does not also select a
section. No notification store or data lifecycle was changed.
