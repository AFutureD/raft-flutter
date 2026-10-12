import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

const body = '''
Intro paragraph with `inline code`, **bold** and a [link](https://raft.build).

## Section

- First item
- Second item

1. One
2. Two
''';

Widget frame(
  RaftFamily family,
  bool dark, {
  List<RaftAnnouncementPage> pages = const [
    RaftAnnouncementPage(title: 'Welcome', body: body),
    RaftAnnouncementPage(body: 'Second page.'),
  ],
  VoidCallback? onClose,
  VoidCallback? onConfirm,
  ValueChanged<String>? onLink,
  Locale? locale,
}) => MaterialApp(
  theme: raftTheme(family, dark: dark),
  home: Scaffold(
    body: Builder(
      builder: (context) => Localizations.override(
        context: context,
        locale: locale,
        child: RaftAnnouncementModal(
          title: 'What is new',
          pages: pages,
          onClose: onClose ?? () {},
          onConfirm: onConfirm ?? () {},
          onLink: onLink,
        ),
      ),
    ),
  ),
);

void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets('renders every block in ${family.name}${dark ? ' dark' : ''}', (
      t,
    ) async {
      await t.pumpWidget(frame(family, dark));
      expect(t.takeException(), isNull);
      expect(find.text('WHAT IS NEW'), findsOneWidget);
      expect(find.text('WELCOME'), findsOneWidget);
      expect(find.text('inline code'), findsOneWidget);
      expect(find.text('SECTION'), findsOneWidget);
      expect(find.text('First item'), findsOneWidget);
      expect(find.text('2. '), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      // max-w-xl
      expect(
        t.getSize(find.byKey(const ValueKey('announcement-modal'))).width,
        RaftAnnouncementCard.maxWidth,
      );
    });
  }

  testWidgets('pages, Enter, Escape, backdrop and links', (t) async {
    var closes = 0, confirms = 0;
    final links = <String>[];
    await t.pumpWidget(
      frame(
        RaftFamily.elegant,
        false,
        onClose: () => closes++,
        onConfirm: () => confirms++,
        onLink: links.add,
      ),
    );
    await t.pump();
    expect(find.byKey(const ValueKey('announcement-back')), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byKey(const ValueKey('announcement-ok')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('announcement-back')));
    await t.pump();
    expect(find.text('1 / 2'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('announcement-next')));
    await t.pump();
    await t.tap(find.byKey(const ValueKey('announcement-ok')));
    expect(confirms, 1);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(closes, 1);
    await t.tapAt(const Offset(2, 2));
    expect(closes, 2);
    expect(confirms, 1);
  });

  testWidgets('single page: OK only, no indicator; zh copy', (t) async {
    await t.pumpWidget(
      frame(
        RaftFamily.brutal,
        false,
        pages: const [RaftAnnouncementPage(body: 'Only page.')],
        locale: const Locale('zh', 'CN'),
      ),
    );
    expect(
      find.byKey(const ValueKey('announcement-page-indicator')),
      findsNothing,
    );
    expect(find.text('确定'), findsOneWidget);
  });
}
