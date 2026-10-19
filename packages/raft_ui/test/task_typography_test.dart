import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

Future<void> loadTaskFonts(WidgetTester tester) => tester.runAsync(() async {
  for (final family in ['HankenGrotesk', 'Inter', 'Geist', 'GeistMono']) {
    ByteData data;
    try {
      data = await rootBundle.load('packages/raft_ui/assets/fonts/$family.ttf');
    } on FlutterError {
      data = await rootBundle.load('assets/fonts/$family.ttf');
    }
    await (FontLoader(
      'packages/raft_ui/$family',
    )..addFont(Future.value(data))).load();
  }
});

void main() {
  for (final dark in raftThemeMatrix([false, true])) {
    testWidgets(
      '${dark ? 'dark' : 'light'} task inherits document face and retains separate status action',
      (tester) async {
        await loadTaskFonts(tester);
        var opened = 0;
        String? selected;
        final theme = raftTheme(dark: dark);
        final tokens = theme.extension<RaftTokens>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: DefaultTextStyle(
                style: RaftTaskSectionRecipe(tokens).documentStyle,
                child: SizedBox(
                  width: 600,
                  child: RaftTaskCard(
                    title: 'Review the thread header strip baselines',
                    number: '210',
                    channel: 'design',
                    description: 'Source task description',
                    status: 'todo',
                    onTap: () => opened++,
                    statusOptions: const ['todo', 'in_progress'],
                    onStatus: (value) => selected = value,
                  ),
                ),
              ),
            ),
          ),
        );
        // MainLayout font-display is inherited; the number keeps its explicit
        // Source family: font-sans.
        expect(
          tester
              .widget<Text>(
                find.text('Review the thread header strip baselines'),
              )
              .style!
              .fontFamily,
          tokens.headingFont,
        );
        expect(
          tester
              .widget<Text>(find.text('Source task description'))
              .style!
              .fontFamily,
          tokens.headingFont,
        );
        expect(
          tester.widget<Text>(find.text('#210')).style!.fontFamily,
          tokens.bodyFont,
        );
        await tester.tap(find.text('Review the thread header strip baselines'));
        expect(opened, 1);
        await tester.tap(find.text('Todo'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('In Progress'));
        await tester.pumpAndSettle();
        expect(selected, 'in_progress');
        expect(opened, 1);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${dark ? 'dark' : 'light'} inline status inherits its document face',
      (tester) async {
        await loadTaskFonts(tester);
        final theme = raftTheme(dark: dark);
        final tokens = theme.extension<RaftTokens>()!;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: RaftInlineLineBox(
                  style: RaftTaskSectionRecipe(tokens).documentStyle,
                  child: RaftTaskStatusEditor(
                    status: 'in_progress',
                    options: raftTaskStatuses,
                    onSelect: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester.widget<Text>(find.text('In Progress')).style!.fontFamily,
          tokens.headingFont,
        );
        // Source DOM: the h22 badge plus its baseline descent grows the inline
        // line to h25.
        expect(tester.getSize(find.byType(RaftInlineLineBox)).height, 25);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('task keeps the Source meta line and card height', (
    tester,
  ) async {
    await loadTaskFonts(tester);
    final theme = raftTheme();
    final tokens = theme.extension<RaftTokens>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: DefaultTextStyle(
              style: RaftTaskSectionRecipe(tokens).documentStyle,
              child: SizedBox(
                width: 358,
                child: RaftTaskCard(
                  title: 'Review the thread header strip baselines',
                  number: '210',
                  channel: 'design',
                  status: 'in_review',
                  statusOptions: raftTaskStatuses,
                  onStatus: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final number = find.ancestor(
      of: find.text('#210'),
      matching: find.byType(RaftCssText),
    );
    expect(tester.getSize(number).height, 14);
    // 358px card, one title line, editable status, Elegant task-card recipe
    // (the Brutal DOM measurement was 103.25).
    expect(tester.getSize(find.byType(RaftTaskCard)).height, 103);
    expect(tester.takeException(), isNull);
  });
}
