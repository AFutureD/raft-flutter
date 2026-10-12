# macOS Dock unread count

The Dock badge shows the sum of the signed-in account's Activity unread counts
across its known servers. It uses the mounted `/servers/unread-summary` contract;
the selected server's shared `SourceActivityUnreadStore` replaces that server's
summary count. Channel, DM and thread counters are not added again. Legacy
summaries without `activityUnreadCount` do not invent an Activity count.

The badge updates after accepted inbox windows, socket arrivals and persisted
read/read-all responses. A 30-second summary reconciliation covers other servers
whose socket rooms are not selected. The selected workspace retains its existing
shared inbox owner; there is no second socket or inbox poller.

Reading reduces the count; an accepted zero clears it. Removing server membership
removes that server's contribution. Retiring the workspace, logging out or ending
the account clears the badge. Account, server, generation, role and membership
changes fence late receipts. Native writes are serialized, and a queued stale
write cannot restore a retired badge. Transient fetch failures retain accepted
counts; failed native writes retry on synchronization. Closing the app's service
stops its timers/listeners and clears the badge.

Returning to the foreground is not itself a read receipt. Disabling notification
alerts or server push delivery does not mark messages read or clear unread state.
The Dock count therefore does not depend on notification delivery permission.

## Platform dependency

`flutter_local_notifications` 22.3.1 supports a notification's `badgeNumber`, but
has no standalone application badge update/clear API. Its [official documentation](https://pub.dev/documentation/flutter_local_notifications/latest/)
explicitly records this limitation. Posting a dummy notification on every read
would create unrelated notification-center entries and require alert permission.

This feature uses [app_badge_plus](https://pub.dev/packages/app_badge_plus) 1.3.5.
Its reviewed macOS implementation sets the system
[NSDockTile.badgeLabel](https://developer.apple.com/documentation/appkit/nsdocktile/badgelabel)
on the main queue and clears it with a zero count. It does not activate windows
or request notification permission. No custom native badge bridge is added.
Other platforms retain their existing notification and badge behavior.

## Validation

`macos_dock_unread_test.dart` covers membership-bounded cross-server counts,
current inbox replacement, reads, foreground transitions, revocation, account
retirement, rejected old role receipts, socket and persisted-read refresh,
periodic reconciliation, timer disposal, serialized writes, native failures,
the actual plugin channel and unsupported platforms. Related desktop alert and
notification-navigation regressions must remain green.

Native compilation checks plugin registration and linking. Visual Dock display,
real cross-device read receipts and OS lifecycle behavior need an actual macOS
app session; compilation and unit tests do not substitute for that acceptance.
