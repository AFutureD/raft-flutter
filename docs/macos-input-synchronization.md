# Programmatic composer updates during native composition

Native TextField edits continue to reach the controller immediately. No input
formatter, dictation limit, engine patch or native input hook is added. An
external draftRevision or failed-send recovery waits while a composing range is
active. The ordinary draft callback receives the projected merged text during
that wait, so leaving the channel preserves pending captions/recovery instead of
saving only the visible native text. The editor flushes after composition commits,
in a post-frame callback, with selection mapped through the programmatic change.

Append/prepend and combined caption/recovery updates rebase onto the text the IME
has continued to edit. Deferred operations retain their arrival order and failed-send
prepend intent, including identical sent/live text. Selection maps through each
operation so combined captions and recovery keep the caret within live text.
Disjoint replacements preserve live changes; conflicting
replacements conservatively keep both texts separated by a newline rather than
silently losing live input. No extra native editing states are sent for ordinary
IME updates or ordinary rebuilds. A pending post-frame update cannot write into a
disposed composer or another channel's keyed editor. An explicit Send after IME
commit incorporates the pending draft before submitting.

Only app-supplied text is normalized for unpaired UTF-16 units. Programmatic
mention, newline and draft-selection offsets preserve surrogate boundaries.
Flutter selection offsets remain UTF-16 units; valid native values, including
Chinese and multi-code-point emoji, are not rewritten while composing.

The Mac 11:19 abort occurred in Flutter's native setMarkedText/Utf16ToUtf8 path,
before the edit reached Dart. These changes address independently demonstrated
App synchronization risks and cannot certify that the native crash is eliminated.
Kevin's long system-dictation test remains necessary. Fixture editing values do
not exercise macOS dictation or prove 120fps.

Tests cover native composition preservation, ongoing text after failed send,
multiple deferred captions, projected draft persistence when changing channels,
long Chinese/emoji text, synthetic mid-surrogate selections and ordinary keyboard
sending/suggestions. Early test runs and setup failures are preserved in the
Mac input-sync artifact directory; the final package-scoped tests load their own
font assets correctly.
