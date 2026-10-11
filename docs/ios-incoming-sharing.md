# iOS receiving shares

The iOS app now packages a native Share Extension. The extension accepts text,
URLs, images, videos and files through `NSItemProvider`, prepares a private copy,
and asks the user to Save or Cancel. Saving publishes an independent envelope;
it does not send a message or open the containing app. When the user returns to
Raft, cold initialization or foreground resume admits that envelope into the
existing server/target picker and ordinary draft composer. That picker continues
to recheck membership, target permissions and account identity. No credentials or
server session enter the extension.

This preserves Android's target selection, existing-draft append, attachment
ownership, explicit Send and cancellation semantics. It differs at the system
handoff: iOS requires returning to Raft after Save. Direct channel selection and
sending inside the extension are not implemented. System Photos/Files/Safari
and real foreground/cold lifecycle flows remain unaccepted until simulator UI
verification is complete.

## Plugin review

The current [receive_intent](https://pub.dev/packages/receive_intent) is Android
only. [share_plus](https://pub.dev/packages/share_plus) presents outgoing sharing;
it does not add an incoming Share Extension. Both
[receive_sharing_intent 1.9.0](https://pub.dev/packages/receive_sharing_intent) and
[share_handler 0.0.25](https://pub.dev/packages/share_handler) can transport iOS
text/media after extension and App Group setup. We inspected their actual pub
archives, including share_handler_ios 0.0.15. Their redirect implementations walk
the responder chain to invoke UIApplication/openURL, and their extension
payload is stored at one shared defaults key. Reusing that code directly would
not provide this app's durable, ordered inbox contract. receive_sharing_intent
1.9.0 also distributes its iOS implementation through SPM only.

[Apple's extension guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html)
describes shared containers and restricts UIApplication access and requesting a
containing-app launch from Share Extensions. This implementation uses public
extension APIs and shared files; it adds neither incoming pub dependency nor
responder-chain redirect. Compilation cannot establish store acceptance or
behavior on every provider/iOS version.

## Storage and process handoff

Runner and ShareExtension declare `group.app.raft.raftFlutter`. App Group
provisioning must be enabled for both signed physical-device targets. Each share
copies at most 9 files, 25 MiB per file and 100 MiB total with 64 KiB chunks.
Text is limited to 65,536 UTF-16 units. OAuth, credential and signed-resource
links are rejected before durable publication, using the ordinary app's text
policy. Names cannot choose paths. Files are excluded from backups and use
complete-until-first-authentication protection on iOS.

A `.staging-<token>` folder is invisible to the app's reader. The extension opens
the provider file while its callback owns the URL, then copies from that open
descriptor on a background queue. The descriptor survives removal of the
provider's temporary pathname. Save atomically renames the complete folder to a
32-character token, with the existing `envelope.json`/`item-N` format. Cancel
signals the copy between chunks and deletes staging; it does not block the UI
on the copy lock. App recovery retains the existing 24-hour pending expiry,
account binding, destination revocation and draft file lifetime. Native crashes
can leave an unpublished staging folder; the native directory service removes
only staging folders older than 24 hours, preserving current transfers and
committed draft records. Directory setup and cleanup also run off the UI thread.

The app obtains only the entitled shared directory through `app.raft/sharing`.
An iOS resume recovers pending envelopes serially and suppresses repeated token
admission within a bounded process cache. Android remains on receive_intent and
content-provider grants. The iOS bridge also presents outgoing sharing for the
existing private export leases; it admits only files in the app's raft-share
cache and requires an active app scene.

## Build and verification

`RAFT_FLUTTER_BIN=<pinned Flutter> python3 tool/ios-simulator-build --build-number N`
builds but never installs or launches. Flutter's default simulator artifact has
empty signing entitlements; this helper re-signs the local Runner and extension
ad hoc with their explicit App Group and verifies both signatures. It is for
simulators only, not physical-device signing. About receives the existing local
dev version; the native marketing version remains the pubspec version.

The Foundation producer tests cover publication/cancellation, preserved bytes,
provider callback lifetime, multiple shares, unsafe text, filenames, counts and
sizes. A Dart test compiles that producer on macOS, reads its real envelope,
binds it to an account, opens exact attachment bytes and completes it through
the production inbox. That does not exercise NSItemProvider or a system share
sheet. Focused recovery tests cover cold initialization, repeated/parallel
resumes, late directory recovery and dispose. Existing sharing and icon tests
remain part of the check scope. Both Runner and the embedded extension compile
for the simulator; compiled metadata contains all five app icons.

The requested UI verification is still pending: Xcode 27 uses Device Hub at
`Xcode.app/Contents/Applications/DeviceHub.app`; old Simulator.app is absent by
design here. Background Computer Use launched Device Hub, but window binding
returned `cgWindowNotFound`. Under the user's background-only AGENTS instruction,
no CLI boot/install/launch, global input or foreground-raising fallback was used.
The user has been asked to open a bindable simulator window. No physical iPhone
was installed or launched by this task.
