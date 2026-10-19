import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/src/message_row_recipe.dart';
import 'package:raft_ui/src/theme.dart';
import 'package:raft_ui/test_themes.dart';

const avatarKey = Key('public-avatar');
const bodyKey = Key('public-body');
const actionKey = Key('public-thread-action');

Widget host({
  bool dark = false,
  bool continuation = false,
  bool coarse = false,
  bool popup = false,
  VoidCallback? action,
  double width = 390,
}) {
  return MaterialApp(
    theme: raftTheme(dark: dark),
    home: MediaQuery(
      data: MediaQueryData(size: Size(width, 480), devicePixelRatio: 1),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: RaftMessageRow(
              author: 'Public Agent',
              timestamp: '14:30',
              continuation: continuation,
              coarsePointer: coarse,
              popupOpen: popup,
              avatar: const ColoredBox(key: avatarKey, color: Colors.blue),
              content: const Text('Public body', key: bodyKey),
              toolbar: RaftMessageToolbar(
                children: [
                  RaftMessageToolbarAction(
                    key: actionKey,
                    label: 'Reply in thread',
                    icon: const SizedBox(),
                    onPressed: action ?? () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  for (final (dark) in raftThemeMatrix([(false), (true)], full: true)) {
    testWidgets(
      'header preserves intrinsic author/model/clock and shrinks description only ${dark ? 'dark' : 'light'}',
      (tester) async {
        var mentions = 0;
        Widget frame(double width) => MaterialApp(
          theme: raftTheme(dark: dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: RaftMessageRow(
                  author: 'Cindy',
                  timestamp: '10:30',
                  onAuthor: () => mentions++,
                  metadata: const SizedBox(
                    key: Key('model'),
                    width: 120,
                    height: 14,
                  ),
                  subtitle: 'Long private description',
                  content: const Text('Body'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpWidget(frame(390));
        final author = find.text('Cindy');
        final authorBox = tester.renderObject<RenderBox>(author);
        final naturalAuthorWidth = authorBox.getMaxIntrinsicWidth(
          double.infinity,
        );
        expect(authorBox.size.width, naturalAuthorWidth);
        expect(tester.getSize(find.byKey(const Key('model'))).width, 120);
        final time = tester.renderObject<RenderBox>(find.text('10:30'));
        expect(time.size.width, time.getMaxIntrinsicWidth(double.infinity));
        expect(tester.getSize(find.text('Long private description')).width, 0);
        expect(
          tester.getTopLeft(find.byKey(const Key('model'))).dx,
          closeTo(tester.getTopRight(author).dx + (6), .01),
        );
        await tester.tap(author);
        await tester.pump();
        expect(mentions, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(frame(700));
        expect(
          tester.getSize(find.text('Long private description')).width,
          greaterThan(0),
        );
        expect(tester.getSize(author).width, naturalAuthorWidth);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'mounted avatar and content origins match source ${dark ? 'dark' : 'light'}',
      (tester) async {
        await tester.pumpWidget(host(dark: dark));
        expect(tester.getSize(find.byKey(avatarKey)), const Size(36, 36));
        expect(tester.getTopLeft(find.byKey(avatarKey)), const Offset(17, 11));
        expect(tester.getTopLeft(find.byKey(bodyKey)).dx, 57);
        final body = tester.widget<Text>(find.byKey(bodyKey));
        expect(body.style, isNull);
        final resolved = DefaultTextStyle.of(
          tester.element(find.byKey(bodyKey)),
        ).style;
        expect(resolved.fontSize, 14);
        expect(resolved.height, 20 / 14);
        expect(
          resolved.fontFamily,
          RaftTokens.of(tester.element(find.byKey(bodyKey))).headingFont,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'hover and keyboard focus reveal the source strip ${dark ? 'dark' : 'light'}',
      (tester) async {
        var activated = 0;
        await tester.pumpWidget(host(dark: dark, action: () => activated++));
        Opacity strip() => tester.widget<Opacity>(
          find
              .ancestor(
                of: find.byType(RaftMessageToolbar),
                matching: find.byType(Opacity),
              )
              .first,
        );
        expect(find.byType(RaftMessageToolbar), findsNothing);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(2, 300));
        await mouse.moveTo(tester.getCenter(find.byKey(bodyKey)));
        await tester.pump();
        expect(strip().opacity, 1);
        final button = find.byKey(actionKey);
        expect(tester.getSize(button), Size.square(28));
        await mouse.moveTo(const Offset(2, 300));
        await tester.pump();
        expect(find.byType(RaftMessageToolbar), findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(strip().opacity, 1);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(activated, 1);
        await mouse.removePointer();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('coarse pointer hides strip at both mobile and desktop widths', (
    tester,
  ) async {
    for (final width in [390.0, 1280.0]) {
      await tester.pumpWidget(host(width: width, coarse: true));
      expect(find.byType(RaftMessageToolbar), findsNothing);
      expect(find.byKey(bodyKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'continuation omits avatar/header but keeps body and hidden gutter clock',
    (tester) async {
      await tester.pumpWidget(host(continuation: true));
      expect(find.byKey(avatarKey), findsNothing);
      expect(find.text('Public Agent'), findsNothing);
      expect(find.text('14:30'), findsOneWidget);
      expect(tester.getTopLeft(find.byKey(bodyKey)), const Offset(57, 7));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('popup retains strip without hover or keyboard focus', (
    tester,
  ) async {
    await tester.pumpWidget(host(popup: true));
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: find.byType(RaftMessageToolbar),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'long author stays one header line rather than wrapping metadata',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: raftTheme(),
          home: const Scaffold(
            body: SizedBox(
              width: 390,
              child: RaftMessageRow(
                author: 'Public long author with more characters than the reserved heading can hold',
                timestamp: '14:30',
                content: Text('Body'),
              ),
            ),
          ),
        ),
      );
      final author = tester.widget<Text>(
        find.text(
          'Public long author with more characters than the reserved heading can hold',
        ),
      );
      expect(author.maxLines, 1);
      expect(author.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'source grouping and breakpoint overrides remain independent of pointer',
    () {
      final t = raftTheme().extension<RaftTokens>()!;
      final mobile = RaftMessageRowRecipe(
        t,
        viewportWidth: 390,
        nextContinuation: true,
      );
      final desktop = RaftMessageRowRecipe(
        t,
        viewportWidth: 1280,
        nextContinuation: true,
      );
      final continued = RaftMessageRowRecipe(
        t,
        viewportWidth: 390,
        continuation: true,
      );
      expect(mobile.padding, const EdgeInsets.fromLTRB(16, 8, 16, 0));
      expect(desktop.padding, const EdgeInsets.fromLTRB(28, 14, 28, 2));
      expect(continued.padding, const EdgeInsets.fromLTRB(16, 6, 16, 6));
      expect(mobile.gutterWidth, 32);
      expect(desktop.gutterWidth, 36);
      expect(mobile.avatarExtent, 36);
      expect(mobile.headerReserve, 96);
      expect(continued.bodyGap, 0);
    },
  );
}
