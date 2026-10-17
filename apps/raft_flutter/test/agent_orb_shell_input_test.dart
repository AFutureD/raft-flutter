import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_orb_shell_test.dart' show OrbFixture;

/// What the person is typing in the orb's input survives the keyboard going
/// down (Android Back), the sheet closing and opening again, and an IME that is
/// in the middle of composing (pinyin, kana).

void main() {
  late OrbFixture f;

  Future<void> fixture(WidgetTester t) async {
    f = OrbFixture(t);
    await f.setUp();
    addTearDown(f.tearDown);
    await f.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));
  }

  final input = find.byKey(const ValueKey('orb-sheet-input'));
  String typed(WidgetTester t) =>
      t.widget<EditableText>(find.byType(EditableText)).controller.text;
  bool focused(WidgetTester t) =>
      t.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus;

  /// The person is part-way through a word: "nihao" composing as pinyin.
  Future<void> compose(WidgetTester t, String text) async {
    await t.tap(input);
    await settle(t);
    t.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
        composing: TextRange(start: 0, end: text.length),
      ),
    );
    await t.pump();
  }

  Future<void> openSheet(WidgetTester t) async {
    await t.tap(OrbFixture.orbFinder);
    await settle(t);
  }

  testWidgets('Back with the keyboard open drops the keyboard, not the text '
      'and not the sheet', (t) async {
    await fixture(t);
    await openSheet(t);
    await compose(t, '去 raft');
    expect(typed(t), '去 raft');
    expect(focused(t), isTrue);

    // Back reaches the app (some keyboards pass it on): it is for the
    // keyboard first.
    expect(await t.binding.handlePopRoute(), isTrue);
    await settle(t);

    expect(f.controller.sheetOpen, isTrue, reason: 'the sheet stays');
    expect(focused(t), isFalse, reason: 'the keyboard went down');
    expect(typed(t), '去 raft');
    // Back once more closes the sheet.
    expect(await t.binding.handlePopRoute(), isTrue);
    await settle(t);
    expect(f.controller.sheetOpen, isFalse);
  });

  testWidgets('the keyboard going down in the middle of composing keeps the '
      'text and its composing range', (t) async {
    await fixture(t);
    await openSheet(t);
    await compose(t, 'nihao');
    final value = f.controller.draft.value;
    expect(value.composing, const TextRange(start: 0, end: 5));

    t.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    t.view.viewInsets = FakeViewPadding.zero;
    await settle(t);

    expect(typed(t), 'nihao');
    expect(f.controller.draft.text, 'nihao');
    expect(f.controller.sheetOpen, isTrue);
  });

  testWidgets('closing the sheet and opening it again brings the draft back', (
    t,
  ) async {
    await fixture(t);
    await openSheet(t);
    await compose(t, '去动态看看');
    await t.tap(find.byKey(const ValueKey('orb-sheet-close')));
    await settle(t);
    expect(f.controller.sheetOpen, isFalse);

    await openSheet(t);
    expect(typed(t), '去动态看看');
    // It is not left half-composed with no keyboard to finish it.
    expect(f.controller.draft.value.composing.isValid, isFalse);
  });

  testWidgets('sending clears the draft; an empty one stays empty', (t) async {
    await fixture(t);
    await openSheet(t);
    await t.enterText(input, '你好');
    await t.tap(find.byKey(const ValueKey('orb-sheet-send')));
    await t.pump();
    expect(typed(t), isEmpty);
    expect(f.controller.draft.text, isEmpty);
  });
}
