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

## SDK lifecycle analysis and mitigation

The pinned SDK's `widgets/stretch_effect.dart` disposes its previous shader
during build, including when the stretch effect is disabled at zero strength.
`ImageFiltered` compares a newly supplied filter against its old filter.
`_FragmentShaderImageFilter.operator ==` lazily converts both filters to native
filters; the old shader can already have lost its native wrapper. The native
`initShader` dereferences that wrapper. This lifecycle matches the symbolicated
device fault; release AOT Dart frames were not available for full symbolication.

The app now supplies `RaftScrollBehavior`: Android uses Flutter's built-in
`GlowingOverscrollIndicator` instead of the shader-based stretch decoration.
All other platforms delegate to `MaterialScrollBehavior`. Platform scrolling
physics, scrollbars, Impeller and page transitions stay in use. The workaround
belongs to the application platform layer, does not patch the FVM SDK, and can
be removed after the pinned SDK's lifecycle is corrected and verified.

The actual RaftApp regression asserts that the unsafe stretch indicator is not
mounted. This eliminates the identified call path, but does not certify a
crash-free native build: installation and repeated physical Back verification
remain outstanding.

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
