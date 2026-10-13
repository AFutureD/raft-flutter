import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Resource-release guard (owner request 2026-10-13, "同类的资源不释放问题都要
/// 解决"). A field that owns a controller, timer, subscription or lifecycle
/// observer must release it in the same file; a leak here keeps a hidden
/// page's tickers, listeners or native handles alive for the app's lifetime.
///
/// This is a textual check in the style of `idle_work_guard_test.dart`: it
/// finds `field = Type(...)` / `field = stream.listen(...)` assignments and
/// requires a matching `field.dispose()` / `.cancel()` / `.close()` somewhere
/// in the file. Anything it cannot prove needs an allowlist entry that says
/// who releases it. Entries that no longer match must be removed.
final _ownedControllers = RegExp(
  r'^\s{2}(?:late\s+|final\s+|static\s+)*(?:[\w<>?,. ]+?\s+)?(_?\w+)\s*=\s*'
  r'(?:const\s+)?(AnimationController|ScrollController|TextEditingController|'
  r'FocusNode|FocusScopeNode|PageController|TabController|'
  r'TransformationController|UndoHistoryController|ValueNotifier|'
  r'StreamController)(?:<[^>]*>)?\(',
  multiLine: true,
);
final _ownedTimers = RegExp(
  r'(?:^|[\s;{(])(_?\w+)\s*=\s*(?:Timer(?:\.periodic)?|RaftIdleTimer|'
  r'RaftForegroundPeriodic)\(',
  multiLine: true,
);
final _ownedSubscriptions = RegExp(
  r'(?:^|[\s;{(])(_?\w+)\s*=\s*[\w.!?]+\.listen\(',
  multiLine: true,
);

/// 'path#field' -> who releases it.
const _allow = <String, String>{
  'apps/raft_flutter/lib/data/attachment_image_repository.dart#transfer':
      'Per-entry progress mirror; it has no listener once the entry is '
      'dropped and is collected with it.',
  'apps/raft_flutter/lib/features/layout_hold.dart#count':
      'Process-wide singleton counter, never torn down.',
  'apps/raft_flutter/lib/platform/desktop_title_bar.dart#state':
      'Process-wide singleton, never torn down.',
  'apps/raft_flutter/lib/platform/oauth_broker.dart#helpUrl':
      'Process-wide singleton, never torn down.',
  'apps/raft_flutter/lib/platform/route_frame_diagnostics.dart#_flushTimer':
      'Opt-in probe, lives for the whole run by design.',
  'apps/raft_flutter/lib/platform/incoming_share_staging.dart#progress':
      'Value notifiers of one staging run; collected with the run.',
  'apps/raft_flutter/lib/platform/incoming_share_staging.dart#overall':
      'Value notifiers of one staging run; collected with the run.',
  'apps/raft_flutter/lib/features/agent_apps_view.dart#payload':
      'Dialog-local notifier with no listener outside the dialog.',
  'apps/raft_flutter/lib/features/agent_apps_view.dart#failure':
      'Dialog-local notifier with no listener outside the dialog.',
  'apps/raft_flutter/lib/features/fleet_views.dart#content':
      'Dialog-local notifier with no listener outside the dialog.',
  'apps/raft_flutter/lib/features/quick_switcher.dart#controller':
      'Local variable of a one-shot dialog builder, disposed by the dialog.',
  'apps/raft_flutter/lib/features/inline_attachment_media.dart#playbackEvents':
      'Cancelled through the `events` alias in releaseInputs().',
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

String _code(String source) => source
    .split('\n')
    .map((line) {
      final i = line.indexOf('//');
      return i < 0 ? line : line.substring(0, i);
    })
    .join('\n');

Iterable<File> _sources(Directory root) sync* {
  for (final base in const [
    'apps/raft_flutter/lib',
    'packages/raft_ui/lib',
    'packages/flutter_chat_ui/lib',
    'packages/raft_client/lib',
    'packages/raft_sync/lib',
  ]) {
    final dir = Directory('${root.path}/$base');
    if (!dir.existsSync()) continue;
    yield* dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
  }
}

/// `name.dispose()`, a `name.dispose` tear-off, or `for (final c in [a, name])
/// c.dispose()`.
bool _releases(String code, String name) {
  final escaped = RegExp.escape(name);
  return RegExp(
        '\\b$escaped[?!]?\\.(?:dispose|cancel|close|stop)\\b',
      ).hasMatch(code) ||
      RegExp(
        '\\bin\\s*\\[[^\\]]*\\b$escaped\\b[^\\]]*\\]\\s*\\)\\s*'
        '\\{?\\s*\\w+\\.(?:dispose|cancel|close)\\(',
      ).hasMatch(code);
}

/// Names created in [code] (comments already stripped) that nothing releases.
Iterable<(String, int)> _unreleased(String code) sync* {
  for (final pattern in [_ownedControllers, _ownedTimers, _ownedSubscriptions]) {
    for (final m in pattern.allMatches(code)) {
      final name = m.group(1)!;
      if (const {'final', 'var', 'late', 'return'}.contains(name)) continue;
      if (_releases(code, name)) continue;
      yield (name, code.substring(0, m.start).split('\n').length);
    }
  }
}

void main() {
  test('the scanner flags what is never released and accepts what is', () {
    const leaky = '''
class _S extends State<W> with SingleTickerProviderStateMixin {
  late final ctl = AnimationController(vsync: this);
  final focus = FocusNode();
  final scroll = ScrollController();
  Timer? timer;
  late StreamSubscription<int> sub;
  void init() {
    timer = Timer(const Duration(seconds: 1), () {});
    sub = stream.listen((_) {});
  }
  @override
  void dispose() {
    focus.dispose();
    for (final c in [scroll]) c.dispose();
    super.dispose();
  }
}
''';
    expect(
      _unreleased(leaky).map((e) => e.$1).toList()..sort(),
      ['ctl', 'sub', 'timer'],
    );
  });

  test('every owned controller, timer and subscription is released in its file', () {
    final root = _repoRoot();
    final problems = <String>[];
    final used = <String>{};
    for (final file in _sources(root)) {
      final rel = file.path.substring(root.path.length + 1);
      final code = _code(file.readAsStringSync());
      for (final (name, line) in _unreleased(code)) {
        final key = '$rel#$name';
        if (_allow.containsKey(key)) {
          used.add(key);
          continue;
        }
        problems.add('$rel:$line: `$name` is created here but never '
            'disposed/cancelled in this file');
      }
    }
    final stale = _allow.keys.where((k) => !used.contains(k));
    expect(
      [
        ...problems,
        ...stale.map((k) => 'stale allowlist entry: $k (it is released now)'),
      ],
      isEmpty,
      reason:
          'Dispose or cancel the resource, or add a reasoned allowlist entry.',
    );
  });

  test('a WidgetsBindingObserver registered by a State is removed in the same file', () {
    final root = _repoRoot();
    final problems = <String>[];
    for (final file in _sources(root)) {
      final rel = file.path.substring(root.path.length + 1);
      final code = _code(file.readAsStringSync());
      final adds = RegExp(r'addObserver\(').allMatches(code).length;
      final removes = RegExp(r'removeObserver\(').allMatches(code).length;
      if (adds > removes) {
        problems.add('$rel: $adds addObserver vs $removes removeObserver');
      }
    }
    expect(problems, isEmpty);
  });

  test('image stream listeners are removed where they are added', () {
    final root = _repoRoot();
    final problems = <String>[];
    for (final file in _sources(root)) {
      final rel = file.path.substring(root.path.length + 1);
      final code = _code(file.readAsStringSync());
      if (!code.contains('ImageStreamListener(')) continue;
      final adds = RegExp(r'\.addListener\(\s*\w*[lL]istener').allMatches(code).length;
      final removes = RegExp(r'\.removeListener\(\s*\w*[lL]istener').allMatches(code).length;
      if (adds > removes) problems.add('$rel: $adds adds vs $removes removes');
    }
    expect(problems, isEmpty);
  });
}
