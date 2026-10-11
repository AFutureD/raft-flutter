import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  for (final theme in [
    raftTheme(RaftFamily.brutal),
    raftTheme(RaftFamily.elegant),
    raftTheme(RaftFamily.elegant, dark: true),
  ]) {
    testWidgets(
      'Mobile headers align navigation and accept keyboard in ${theme.brightness}/${theme.extension<RaftTokens>()?.family}',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var back = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  const RaftMobileRootHeader(title: 'Settings'),
                  RaftChannelHeader(
                    name: '长标题频道导航位置统一',
                    description: 'Channel description',
                    onBack: () => back++,
                  ),
                  SizedBox(
                    height: 160,
                    child: RaftSettingsPanelFrame(
                      header: RaftSettingsPanelHeader(
                        title: 'Account',
                        onMobileBack: () => back++,
                      ),
                      child: const SizedBox.shrink(),
                    ),
                  ),
                  RaftThreadHeader(
                    presentation: RaftThreadPresentation.side,
                    threadLabel: 'Thread',
                    jumpLabel: 'Jump',
                    backLabel: 'Back',
                    closeLabel: 'Close',
                    onBack: () => back++,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final headers = find.byType(RaftMobilePageHeader);
        expect(headers, findsNWidgets(4));
        for (final element in headers.evaluate()) {
          expect(tester.getSize(find.byWidget(element.widget)).height, 56);
        }
        // Every header draws Web's panel edge: brutal 2px black, elegant 1px.
        final tokens = theme.extension<RaftTokens>()!;
        for (final element in headers.evaluate()) {
          final box = tester.widget<Container>(
            find
                .descendant(
                  of: find.byWidget(element.widget),
                  matching: find.byType(Container),
                )
                .first,
          );
          final edge =
              ((box.decoration! as BoxDecoration).border! as Border).bottom;
          expect(edge.width, tokens.brutal ? 2 : 1);
          if (tokens.brutal) expect(edge.color, Colors.black);
        }
        final buttons = find.byType(BackButtonIcon);
        expect(buttons, findsNWidgets(3));
        for (var index = 0; index < 3; index++) {
          expect(tester.getCenter(buttons.at(index)).dx, 32);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(back, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
