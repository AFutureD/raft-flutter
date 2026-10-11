# Notification projection during Mac rebuilds

When the notification bell rebuilds during resize or page changes, the previous
projection attempted to parse `planDowngradedAt` before checking the plan. A Pro
server without that field therefore called `DateTime.tryParse('')` on every read,
throwing and catching a `FormatException` despite having no downgrade notice.

The projection now reads and parses the downgrade timestamp only for a Free
plan with a nonempty date. It still derives notices from current inputs and the
current clock on every call. Invalid nonempty Free dates retain the previous
behavior. Notice order, deadlines, fingerprints, permissions, dismissal and
keyboard behavior are preserved; no persistent projection cache is introduced.

## Evidence

Base: `e023cf8f1cf28ea6826c1c5ede0aa2b4257c2d1e`.

The existing native row-resize CPU discovery recorded 4,227 main-isolate samples
over 10.01949 seconds. Of those, 45 reached `DateTime.parse` through
`projectSystemNotifications`. The synthetic server used plan `pro` with no
`planDowngradedAt`. The projection's source bytes match between that profiled
revision and this base. These are inclusive CPU samples, not frame timings or
an after measurement; no frame-rate gain is inferred.

The unchanged production baseline failed two new regression cases and passed
one. Twenty repeated Pro projections accessed the irrelevant downgrade field
20 times; the final implementation accesses it zero times. Tests also cover
Enterprise/unknown plans, live plan and timestamp changes, the precise grace
deadline, absent/empty/invalid dates, and retained feedback notices.

Five related test files passed, 25 unique cases total. After a test-only lint
correction, the three new cases were rerun and passed. Focused `tool/flutter
analyze` and `tool/ds-audit --check` passed. Existing store and mounted bell tests
cover permission reduction, stale responses, dismissal, Back/Escape and focus.

## Remaining native verification

Background Computer Use still returns `cgWindowNotFound` for the canonical Lab.
No new native UI action or Profile frame result was accepted for this change.
Current user instructions require safely bound background Computer Use; the
Android harness exception does not extend to Mac input.

Once binding is available, freeze the current integration baseline and this
candidate with identical fixture, theme, fonts, semantics, viewport and Profile
harness, then compare resize and affected page transitions. Keep cold/warm
captures distinct and preserve errors, fixture misses and actual routes. The
full Mac coverage and stable 120fps objective remain open.
