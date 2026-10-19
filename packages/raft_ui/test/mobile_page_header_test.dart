import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final theme in raftThemeMatrix([raftTheme(), raftTheme(dark: true)])) {
    testWidgets(
      'Mobile headers align navigation and accept keyboard in ${theme.brightness}',
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
        final tokens = theme.extension<RaftTokens>()!;
        // Panel / detail headers render Web's phone PanelHeader: h-56, boxed
        // PanelAction Back.
        const webHeight = 56.0;
        // The tab-root header is Web's Sidebar mobile navbar: the same
        // `h-panel-header`, px-4, layer-panel + 1px line-muted.
        final root = find.byType(RaftMobilePageHeader);
        expect(root, findsOneWidget);
        expect(tester.getSize(root).height, webHeight);
        final rootBox = tester.widget<Container>(
          find.descendant(of: root, matching: find.byType(Container)).first,
        );
        final rootDecoration = rootBox.decoration! as BoxDecoration;
        expect(rootDecoration.color, tokens.panel);
        final rootEdge = (rootDecoration.border! as Border).bottom;
        expect(rootEdge.width, 1);
        expect(rootEdge.color, tokens.colors['line-muted']);
        expect(tester.getTopLeft(find.text('Settings')).dx, 16);
        final backs = find.byType(RaftPanelAction);
        expect(backs, findsNWidgets(3));
        // PanelAction: `px-2 py-2` + 16px icon = 32x32.
        const actionSize = Size(32, 32);
        for (var index = 0; index < 3; index++) {
          expect(tester.getSize(backs.at(index)), actionSize);
          // The settings Panel's left edge is desktop-only (owner decision
          // 2026-10-12): none on the phone; then max-md:pl-5, then half the
          // action width.
          expect(
            tester.getCenter(backs.at(index)).dx,
            20 + actionSize.width / 2,
          );
          // The visual is Web's size; the touch target is still >= 48.
          expect(
            tester
                .getSize(
                  find.descendant(
                    of: backs.at(index),
                    matching: find.byType(RaftTouchTargetExpander),
                  ),
                )
                .shortestSide,
            actionSize.shortestSide,
          );
        }
        final channelHeader = find.byType(RaftChannelHeader);
        expect(tester.getSize(channelHeader).height, webHeight);
        // The Back hit area extends beyond the 32x32 visual to >= 44.
        final centre = tester.getCenter(backs.first);
        await tester.tapAt(centre + const Offset(0, 20));
        await tester.pump();
        expect(back, 1);
        back = 0;
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
