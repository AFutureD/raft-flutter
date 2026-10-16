import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

TextEditingValue v(String text, int a, [int? b]) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: a, extentOffset: b ?? a),
);

void main() {
  test('wrap adds and removes inline marks around the selection', () {
    final on = RaftMarkdownFormat.wrap(v('say hi now', 4, 6), '**');
    expect(on.text, 'say **hi** now');
    expect(on.selection, const TextSelection(baseOffset: 6, extentOffset: 8));
    final off = RaftMarkdownFormat.wrap(on, '**');
    expect(off.text, 'say hi now');
  });

  test('line prefixes toggle on every selected line', () {
    final on = RaftMarkdownFormat.linePrefix(v('a\nb\nc', 0, 5), '- ');
    expect(on.text, '- a\n- b\n- c');
    expect(RaftMarkdownFormat.linePrefix(on, '- ').text, 'a\nb\nc');
    final numbered = RaftMarkdownFormat.linePrefix(
      v('a\nb', 0, 3),
      '1. ',
      ordered: true,
    );
    expect(numbered.text, '1. a\n2. b');
  });

  test('heading cycles none -> ## -> ### -> none', () {
    final a = RaftMarkdownFormat.heading(v('title', 0));
    expect(a.text, '## title');
    final b = RaftMarkdownFormat.heading(a);
    expect(b.text, '### title');
    expect(RaftMarkdownFormat.heading(b).text, 'title');
  });

  testWidgets('styled source keeps the exact text', (tester) async {
    final controller = RaftMarkdownEditingController(
      text: raftComposerExpandSampleDraft(),
    )..styled = true;
    addTearDown(controller.dispose);
    late TextSpan span;
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(RaftFamily.elegant),
        home: Builder(
          builder: (context) {
            span = controller.buildTextSpan(
              context: context,
              style: const TextStyle(fontSize: 14),
              withComposing: true,
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(span.toPlainText(), controller.text);
  });
}
