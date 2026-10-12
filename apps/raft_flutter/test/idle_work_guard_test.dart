import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Idle-CPU guard (owner decision 2026-10-12, after 6785f8f2).
///
/// `scheduleTask(..., Priority.idle)` is rejected while any ticker runs and
/// Flutter retries it through `Timer.run`: a zero-delay hot loop that pegs a
/// core on every platform and starves native input on Windows. The same hazard
/// comes from any zero-delay timer that re-arms itself, from perpetual
/// animations that are not gated by TickerMode, and from periodic timers that
/// keep waking a hidden app.
///
/// Deferred work therefore goes through `RaftIdleTimer` (positive delay,
/// animation gate, back-off) and polls through `RaftForegroundPeriodic`, both
/// in `packages/raft_ui/lib/src/idle_work.dart`. Each pattern below may only
/// appear where an allowlist entry says why it cannot loop or spin. The
/// entry's count is exact, so a second use in the same file needs a new
/// review. Entries that no longer match must be removed.
const _patterns = <String, String>{
  'scheduleTask': r'\bscheduleTask\b',
  'Priority.idle': r'\bPriority\.idle\b',
  'Timer.run': r'\bTimer\.run\(',
  'zero-delay timer':
      r'\bTimer\(\s*(?:const\s+)?Duration(?:\.zero|\(\))|'
      r'\bFuture\.delayed\(\s*(?:const\s+)?Duration(?:\.zero|\(\))|'
      r'=\s*Duration\.zero\s*\]',
  'Future(': r'\bFuture(?:<[^>]*>)?\(\s*\(\s*\)\s*(?:=>|\{)|\bFuture\.microtask\(',
  'scheduleMicrotask': r'\bscheduleMicrotask\(',
  '.repeat(': r'\.repeat\(',
  'Timer.periodic': r'\bTimer\.periodic\(|\bStream\.periodic\(',
  'frame request':
      r'\bscheduleFrame\(|\bensureVisualUpdate\(|\bscheduleForcedFrame\(',
  'self-registering post-frame callback':
      r'addPostFrameCallback\(\s*[A-Za-z_]\w*\s*\)',
  'raw ticker':
      r'\bTicker\(|\bcreateTicker\(|addPersistentFrameCallback|'
      r'scheduleFrameCallback',
};

const _oneShotMicrotask =
    'One-shot deferral out of a build or notification; the callback does not '
    'schedule another microtask itself.';
const _vsyncState =
    'Loop driven by an AnimationController whose vsync is this State, so '
    'TickerMode (hidden routes, offstage tabs, folded panels) mutes it, it is '
    'disposed with the widget, and reduced motion stops it.';
const _oneShotFrame =
    'Single request after a state change; nothing re-requests from the '
    'callback.';

typedef _Allow = ({int count, String reason});

/// file -> pattern name -> exact count and reason
const _allow = <String, Map<String, _Allow>>{
  'packages/raft_ui/lib/src/idle_work.dart': {
    'Timer.periodic': (
      count: 1,
      reason:
          'RaftForegroundPeriodic itself: the sanctioned periodic timer; it '
          'stops while the app is hidden, paused or detached.',
    ),
  },
  'apps/raft_flutter/lib/data/attachment_image_repository.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/data/followed_threads_store.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/data/thread_agent_followers.dart': {
    'scheduleMicrotask': (
      count: 1,
      reason: 'Coalesces requests into one flush; guarded by _flushing.',
    ),
  },
  'apps/raft_flutter/lib/data/workspace_controller.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/data/workspace_entity_directory.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/data/workspace_grid_sessions.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/features/profile_side_panel.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/features/runtime_usage_chip.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
    'Timer.periodic': (
      count: 1,
      reason:
          'One-second countdown that exists only while a refresh cooldown '
          'runs and cancels itself at zero; bounded by the cooldown.',
    ),
  },
  'apps/raft_flutter/lib/features/composer_directory.dart': {
    'Timer.run': (
      count: 1,
      reason:
          'One-shot roster load after the channel changes; the callback '
          'starts a request and never re-arms.',
    ),
  },
  'apps/raft_flutter/lib/features/system_notification_center.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'apps/raft_flutter/lib/main.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/agent_avatar_dialog.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/announcement_host.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/message_image_export.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/private_route_guard.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/root_error_boundary.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'packages/raft_ui/lib/src/anchored_popup.dart': {
    'frame request': (count: 1, reason: _oneShotFrame),
  },
  'apps/raft_flutter/lib/features/chat_view.dart': {
    'frame request': (
      count: 2,
      reason:
          'reveal(): ensures one frame for the first check and re-requests '
          'only while the target row is not visible, capped at 8 attempts.',
    ),
    'self-registering post-frame callback': (
      count: 2,
      reason:
          'reveal() check callback; re-registers at most 8 times and stops '
          'when the reveal is superseded or unmounted.',
    ),
  },
  'apps/raft_flutter/lib/platform/android_performance_hint.dart': {
    'frame request': (
      count: 2,
      reason:
          'Binding override that observes scheduleFrame to open a '
          'performance-hint session; it forwards to super and requests none.',
    ),
  },
  'apps/raft_flutter/lib/platform/macos_dock_unread.dart': {
    'Timer.periodic': (
      count: 1,
      reason:
          'Dock badge reconcile every 30 s. It must keep running while the '
          'app is hidden (the badge is how the user sees unread), and it '
          'builds no UI so it requests no frames.',
    ),
  },
  'apps/raft_flutter/lib/platform/route_frame_diagnostics.dart': {
    'Timer.periodic': (
      count: 1,
      reason:
          '3 s flush of the opt-in route frame probe; only created when the '
          'diagnostics flag is on, never in a normal run.',
    ),
  },
  'packages/raft_ui/lib/src/attachment_transfer.dart': {
    '.repeat(': (count: 1, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/chat_composition.dart': {
    '.repeat(': (count: 1, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/design_primitives.dart': {
    '.repeat(': (count: 2, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/member_graph.dart': {
    '.repeat(': (count: 2, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/indicators.dart': {
    '.repeat(': (count: 1, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/message_translation.dart': {
    '.repeat(': (count: 1, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/quoted_message_card.dart': {
    '.repeat(': (count: 1, reason: _vsyncState),
  },
  'packages/raft_ui/lib/src/message_body.dart': {
    'scheduleMicrotask': (count: 1, reason: _oneShotMicrotask),
  },
  'packages/raft_ui/lib/src/sized_image.dart': {
    'scheduleMicrotask': (
      count: 1,
      reason: 'One-shot image cache eviction after a load error.',
    ),
  },
};

Directory _repoRoot() {
  var dir = Directory.current.absolute;
  while (!File('${dir.path}/pubspec.yaml').existsSync() ||
      !Directory('${dir.path}/packages/raft_ui').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) fail('repository root not found');
    dir = parent;
  }
  return dir;
}

String _stripComments(String line) {
  final i = line.indexOf('//');
  return i < 0 ? line : line.substring(0, i);
}

void main() {
  test('deferred work and perpetual loops only appear where reviewed', () {
    final root = _repoRoot();
    final regexps = {for (final e in _patterns.entries) e.key: RegExp(e.value)};
    final found = <String, Map<String, int>>{};
    for (final base in const [
      'apps/raft_flutter/lib',
      'packages/raft_ui/lib',
      'packages/flutter_chat_ui/lib',
      'packages/raft_client/lib',
      'packages/raft_sync/lib',
      'packages/flutter_dynamic_icon_plus/lib',
    ]) {
      final dir = Directory('${root.path}/$base');
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.dart'),
      )) {
        final rel = f.path.substring(root.path.length + 1);
        for (final line in f.readAsLinesSync()) {
          final code = _stripComments(line);
          for (final e in regexps.entries) {
            if (e.value.hasMatch(code)) {
              final counts = found.putIfAbsent(rel, () => {});
              counts[e.key] = (counts[e.key] ?? 0) + 1;
            }
          }
        }
      }
    }

    final problems = <String>[
      for (final f in found.entries)
        for (final p in f.value.entries)
          if (_allow[f.key]?[p.key] == null)
            '${f.key}: ${p.key} x${p.value} is not allowlisted. Use '
                'RaftIdleTimer / RaftForegroundPeriodic (raft_ui idle_work) '
                'or add an entry with a reason it cannot spin.'
          else if (_allow[f.key]![p.key]!.count != p.value)
            '${f.key}: ${p.key} appears ${p.value} times, allowlist says '
                '${_allow[f.key]![p.key]!.count}.',
      for (final f in _allow.entries)
        for (final p in f.value.keys)
          if (found[f.key]?[p] == null)
            '${f.key}: stale allowlist entry for $p.',
    ]..sort();
    expect(problems, isEmpty, reason: problems.join('\n'));

    for (final f in _allow.values) {
      for (final entry in f.values) {
        expect(entry.reason.trim().length, greaterThan(30));
      }
    }
  });

  test('scheduleTask and Priority.idle have no allowlist at all', () {
    // The one pattern with no legitimate use: a rejected idle task retries
    // through a zero-delay timer for as long as any animation runs.
    for (final f in _allow.entries) {
      expect(f.value.containsKey('scheduleTask'), isFalse, reason: f.key);
      expect(f.value.containsKey('Priority.idle'), isFalse, reason: f.key);
    }
  });
}
