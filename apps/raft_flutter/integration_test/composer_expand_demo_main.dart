// PROTOTYPE visual host for the expandable composer design (GitHub #153).
// Offline, fixed data; not part of the product. Used with a headless Weston
// session to render the states of the proposal:
//   COMPOSER_DEMO_SURFACE=desktop|phone COMPOSER_DEMO_THEME=brutal|elegant-light|elegant-dark
//   COMPOSER_DEMO_MARKS=<file>  (one line appended per state, ready to shoot)
import 'dart:async';
import 'dart:io' show File, FileMode, Platform;

import 'package:flutter/material.dart';
import 'package:raft_ui/raft_ui.dart';

final _env = Platform.environment;
final _phone = _env['COMPOSER_DEMO_SURFACE'] == 'phone';
final _themeName = _env['COMPOSER_DEMO_THEME'] ?? 'brutal';
final _marks = _env['COMPOSER_DEMO_MARKS'];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final theme = switch (_themeName) {
    'elegant-light' => raftTheme(RaftFamily.elegant),
    'elegant-dark' => raftTheme(RaftFamily.elegant, dark: true),
    _ => raftTheme(RaftFamily.brutal),
  };
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _phone ? theme.copyWith(platform: TargetPlatform.android) : theme,
      home: RaftTooltipProvider(child: const _Demo()),
    ),
  );
}

enum _Stage {
  oneLine('1-one-line'),
  twoLines('2-two-lines'),
  threeLines('3-three-lines-expand-button'),
  scrolling('4-long-inline-scrolls'),
  expanded('5-expanded-editor'),
  // Desktop: preview pane hidden. Phone: the Preview tab.
  expandedAlt('6-expanded-alt'),
  // Phone only: soft keyboard up (simulated inset), the format bar rides it.
  expandedKeyboard('7-expanded-keyboard'),
  done('done');

  const _Stage(this.mark);
  final String mark;
}

class _Demo extends StatefulWidget {
  const _Demo();
  @override
  State<_Demo> createState() => _DemoState();
}

class _DemoState extends State<_Demo> {
  final controller = RaftMarkdownEditingController();
  var stage = _Stage.oneLine;
  var task = false;

  static const _short = 'Can someone review the composer crop before release?';
  static const _two =
      'Can someone review the composer crop before release? The Android '
      'build shows the caret under the send button when the draft is long.';
  static const _three =
      'Can someone review the composer crop before release?\n'
      'The Android build shows the caret under the send button when the '
      'draft is long.\n'
      '这条消息是中文，输入法组合时展开按钮不应该移动光标。';

  String _textFor(_Stage s) => switch (s) {
    _Stage.oneLine => _short,
    _Stage.twoLines => _two,
    _Stage.threeLines => _three,
    _Stage.scrolling =>
      '${List.generate(9, (i) => 'Line ${i + 1}: notes for the release plan.').join('\n')}\n',
    _Stage.expanded ||
    _Stage.expandedAlt ||
    _Stage.expandedKeyboard ||
    _Stage.done => raftComposerExpandSampleDraft(),
  };

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 4));
    for (final s in _Stage.values) {
      if (s == _Stage.expandedKeyboard && !_phone) continue;
      setState(() {
        stage = s;
        controller.text = _textFor(s);
        controller.styled = _isExpanded(s);
      });
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final marks = _marks;
      if (marks != null) {
        File(marks).writeAsStringSync('${s.mark}\n', mode: FileMode.append);
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  }

  static bool _isExpanded(_Stage s) =>
      s == _Stage.expanded ||
      s == _Stage.expandedAlt ||
      s == _Stage.expandedKeyboard;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final expanded = _isExpanded(stage);
    final keyboard = stage == _Stage.expandedKeyboard;
    final page = _ChatPage(
      phone: _phone,
      composer: RaftExpandableComposerPrototype(
        controller: controller,
        desktop: !_phone,
        taskChecked: task,
        onTaskChanged: (v) => setState(() => task = v),
        onExpand: () {},
      ),
    );
    return Scaffold(
      backgroundColor: t.canvas,
      body: Stack(
        children: [
          Positioned.fill(child: page),
          if (expanded && !_phone)
            Positioned.fill(
              child: ColoredBox(
                color: t.semantic.layerBackdrop,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: SizedBox(
                      height: 760,
                      child: RaftExpandedComposerPrototype(
                        key: ValueKey(stage == _Stage.expanded),
                        controller: controller,
                        phone: false,
                        taskChecked: task,
                        onTaskChanged: (v) => setState(() => task = v),
                        showPreview: stage == _Stage.expanded,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (expanded && _phone)
            Positioned.fill(
              bottom: keyboard ? 300 : 0,
              child: RaftExpandedComposerPrototype(
                key: ValueKey(stage == _Stage.expandedAlt),
                controller: controller,
                phone: true,
                taskChecked: task,
                onTaskChanged: (v) => setState(() => task = v),
                showPreview: stage == _Stage.expandedAlt,
              ),
            ),
          if (keyboard)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 300,
              child: ColoredBox(
                color: const Color(0xffd1d5db),
                child: Center(
                  child: Text(
                    'software keyboard (simulated, 300 px)',
                    style: RaftTypography.body(t, size: 12, line: 16),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A stand-in channel: sidebar (desktop), a header, a few messages, composer.
class _ChatPage extends StatelessWidget {
  const _ChatPage({required this.phone, required this.composer});
  final bool phone;
  final Widget composer;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final line = t.brutal ? Colors.black : t.colors['line-muted']!;
    Widget message(String who, String text) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            who,
            style: RaftTypography.heading(t, size: 14, line: 20, color: t.ink),
          ),
          RaftMessageBody(content: text),
        ],
      ),
    );
    final column = Column(
      children: [
        Container(
          height: 48,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: t.panel,
            border: Border(bottom: BorderSide(color: line)),
          ),
          child: Text(
            '# general',
            style: RaftTypography.heading(t, size: 16, line: 24, color: t.ink),
          ),
        ),
        Expanded(
          child: ListView(
            reverse: true,
            children: [
              message(
                'Cindy',
                'The **expand** button lands in #153. Draft: [issue](https://example.com/153)',
              ),
              message(
                'Kevin',
                'Longer messages are hard to review in 6 lines.',
              ),
              message('Cindy', 'Agreed. I will prototype the editor first.'),
            ],
          ),
        ),
        composer,
      ],
    );
    if (phone) return SafeArea(child: column);
    return Row(
      children: [
        Container(
          width: 280,
          decoration: BoxDecoration(
            color: t.sidebar,
            border: Border(right: BorderSide(color: line)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final c in ['# general', '# raft-flutter', '# design'])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    c,
                    style: RaftTypography.heading(
                      t,
                      size: 14,
                      line: 20,
                      weight: FontWeight.w500,
                      color: t.ink,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: column),
      ],
    );
  }
}
