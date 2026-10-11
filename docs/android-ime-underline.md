# Android composing underline

The Android composer keeps Flutter's native TextField, editing value, selection,
caret, keyboard and IME connection. It suppresses only the default composing
TextDecoration and paints a one-logical-pixel composing indicator at a common
bottom for each actual visual line. Other platforms retain native decoration.

## Cause and scope

Flutter 3.47.6 uses framework revision
`5fc346839b5d0eef006ed8404392afb4dfae428d` (verify the exact installed
revision with `tool/flutter --version --machine` when reproducing). Its default
TextEditingController builds an underlined TextSpan for the composing range.
SkParagraph computes decoration position and thickness from the font of each
run; CJK fallback and Latin fonts can therefore produce different underline
positions. Forced line height does not override those font metrics.

Primary implementation reference: [pinned Skia Decorations.cpp](https://github.com/google/skia/blob/8df24be66531469e576a806749a0202ae26b8d08/modules/skparagraph/src/Decorations.cpp).
The extension uses Flutter's public [RenderEditable foregroundPainter](https://api.flutter.dev/flutter/rendering/RenderEditable/foregroundPainter.html)
and existing selection/line geometry, without a second TextPainter, shaping
pass, production font bundle, engine patch or changes to UTF-16 IME offsets.
The indicator is clipped by the editor viewport and repaints when composing
range, focus, enabled state or scroll position changes. A composing range can
change while text and selection remain identical.

The message-link underline adapter remains necessary: this is an editor fix,
not a fix to native TextDecoration. Message links cache RenderParagraph geometry
and table clipping; composing decoration follows a live RenderEditable. Their
separate drawing owners are intentional.

## Evidence

- Original unmodified Noto SC metrics in the licensed 5 KB test fixture reproduce
  the mismatch in Elegant light/dark. Brutal with that font is an aligned control.
  The fixture must be loaded under the first plain fallback family used by the
  product; otherwise Flutter's test font can mask CJK with square glyphs.
- Read-only Android system font inspection found Noto CJK with underline position
  -125/1000 and a vendor HYQiHei font with -324/1000. The app's Hanken uses
  -121/1000; Inter uses -348/2048. System configuration does not prove which font
  was selected at runtime, and some vendor configuration is unreadable.
- A local-only control loading the original device HYQiHei file reproduces the
  visible mixed-font mismatch in all three themes at 1× and 2× text scaling:
  six failures before, six passes after. Proprietary font files are not committed
  or redistributed. RAFT_IME_FONT_PATH enables this optional local control.
- The final Noto fixture also passes all three themes at both scales. Pixel
  tests capture the real composer, verify visible CJK glyphs and compare the
  underline height under CJK and Latin characters.
- Protocol tests cover composing-range-only updates, clearing committed strokes,
  Ctrl+Enter while composing, blur/disable, UTF-16 emoji and combining characters,
  CRLF, wrapping, resize, scroll and the non-Android native path. Existing tests
  cover draft sharing, focus, suggestions, attachments, selection handles and
  retained folded editors. 70 unique related component/app tests passed.
- Focused analysis and design-system audit passed. Full batch checks belong to
  the integration owner. No Android application was installed or launched.

Invalid initial CJK fixtures and the first root-directory test invocation are
preserved as local development failures, not presented as product evidence.
The valid fixture tests run from packages/raft_ui; app tests run from
apps/raft_flutter.

## Acceptance remaining

The actual phone IME, its runtime font selection and voice-input workflow still
need visual acceptance after an authorized update. Host widget pixels cannot
substitute for that acceptance. There is no measured native performance claim;
the painter reads the native editor's existing layout during active composition.
Idle non-Android editors do not receive the render wrapper or painter.
