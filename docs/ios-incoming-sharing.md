# iOS receiving shares

Runner packages two native extensions: ShareExtension in the app row and
ActionExtension (Share to Raft / 分享到 Raft) in the Action list. Both use the same
plain UIKit controller to copy content into the App Group and open the main app.
They do not display Apple's social compose editor or choose a server/conversation,
and do not query the account, upload files or send messages.

## Main-app handoff

The extension reads Safari page URL/title through the documented JavaScript
preprocessor and other content through NSItemProvider. It copies provider files
before their temporary callback lifetime ends, then atomically publishes an
`envelope.json` and opaque `item-N` files in `raft-incoming/<token>`.
Unfinished `.staging-<token>` folders cannot enter the app's pending queue.

Only after publication and the extension's first appearance does it request
`raft://share/<32-character-token>`. The modern URL open API is called on a
UIApplication obtained from the responder chain, a compatibility technique used
by receive_sharing_intent. Extension API checking remains enabled; there is no
sharedApplication call, private framework or runtime selector. Apple does not
guarantee this invocation from Share/Action extensions. Finding a responder is
not treated as successful opening: completion must report success. Missing or
rejected opening, including an eight-second unanswered request, leaves the share
saved and displays an inline Open Raft / Close surface. Close after publication
retains the accepted content for a later normal app launch; cancelling copying
removes unfinished staging. Large provider copies may still show the system
extension container with a small preparation indicator.

The URI is only a wake-up signal, never a content or file-path authority. The main
app recognizes only the exact opaque-token form without query, fragment, user
info or port, consumes it outside content navigation, and reads its validated
shared inbox. Initialization, lifecycle resume and URL wake-up all use the same
serialized recovery and token deduplication. A cold share URI is consumed before
building the normal app route. Shares wait for account restoration when needed.

The main app displays the same IncomingSharePicker and ordinary editable draft
handoff as Android: cached servers/conversations first, then an explicit Continue
adds text and queued attachments to the chosen conversation. The extension has
already published the files, so Continue awaits no copy and, since 2026-10-12, no
request: the composer opens from device data and membership, the destination row,
a join or a new DM are checked behind it (docs/sharing-evidence.md, "Instant
hand-off"). A refusal keeps the draft and files and puts a notice on the composer;
Send stays off until the check passes. Uploading and sending remain the composer's explicit action.
Account binding, role/membership checks, conversion fences, draft persistence and
refresh credentials remain in the main app's existing services.

## Files and compatibility

The App Group is `group.app.raft.raftFlutter` (personal deployment IDs may use an
existing provisioned group). Copies are bounded to 9 files, 25 MiB per file,
100 MiB total and 65,536 UTF-16 text units. Credential/OAuth/signed-resource URLs
follow the existing unsafe-text policy. Orphan staging older than 24 hours is
reaped without disturbing live copies or committed inbox records.

The legacy envelope format remains compatible. The previous access-only shared
Keychain export and native compose transport remain available to their historical
fixtures, but the handoff extension does not read or use them. Android continues
using receive_intent. Outgoing iOS sharing still uses UIActivityViewController.
No incoming pub plugin is added: only the opening technique is reused, preserving
Raft's bounded, independent per-share inbox instead of shared-defaults payloads.

Sources: [receive_sharing_intent implementation](https://github.com/KasemJaffer/receive_sharing_intent/blob/master/ios/receive_sharing_intent/Sources/receive_sharing_intent/RSIShareViewController.swift),
[Apple extension lifecycle](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html),
[Apple's compatibility limitation](https://developer.apple.com/forums/thread/764570).

## UIScene and system bars

The app already follows [Flutter's UIScene migration](https://docs.flutter.dev/release/breaking-changes/uiscenedelegate):
AppDelegate registers the implicit engine/plugins; SceneDelegate inherits
FlutterSceneDelegate and calls super before attaching a temporary splash UIView.
It does not replace the root FlutterViewController, create an extra UIWindow,
request fullscreen or override Home indicator preferences. UIScene must remain
adopted for builds with the iOS 27 SDK.

RaftSystemBars now explicitly requests edgeToEdge on iOS as well as Android. The
Flutter iOS implementation issues a show-home-indicator notification for that
mode. Miraa's local source likewise initializes edgeToEdge on iOS. A regression
checks this platform request, but it does not establish physical indicator
visibility. Kevin reported the indicator becomes visible when swiping; iOS 26
system behavior is a possible factor ([Unity's verified issue](https://issuetracker.unity.com/issues/4265/hide-home-button-setting-is-ignored-on-ios-26-devices-home-button-is-always-hidden)).
Neither that source nor the static comparison establishes the cause on this phone.

## Verification boundaries

Targeted tests cover Swift producer-to-Dart exact file bytes, atomic publication,
copy limits/cancellation, cold and warm root-app admission, repeated wake-up
identity, strict URI admission, account-bound draft handoff and no automatic
upload/send. Native compilation verifies the controller with extension API
checking enabled. Historical native compose transport fixtures do not establish
the current extension UI or automatic opening behavior.

Physical builds use real profiles and preserve existing personal bundle IDs.
Build/install checks and widget fixtures do not prove a Share/Action extension can
open the containing app from every system provider on iOS 27. That transition,
system presentation, real authenticated sending and cancellation while a provider
is copying require physical-device acceptance through background Computer Use or
Kevin. No real message is sent by the fixtures. When background targeting is
unavailable, dependent UI actions stop under AGENTS.md.
