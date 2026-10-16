import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/message_history_gaps.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  // Automatic action, stable anchor and reconnect are exercised end-to-end
  // in history_automatic_gap_view_test; this matrix covers passive states.
  for (final theme in [
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ]) {
    for (final scale in [1.0, 3.1]) {
      testWidgets('saved gap and retry controls fit $theme at $scale', (
        t,
      ) async {
        t.view.physicalSize = const Size(360, 700);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        Future<void> pump({bool failed = false}) async {
          await t.pumpWidget(
            MaterialApp(
              theme: raftTheme(theme.$1, dark: theme.$2),
              locale: const Locale('zh', 'CN'),
              supportedLocales: const [Locale('en'), Locale('zh', 'CN')],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(RaftSpace.x2),
                      child: HistoryGapNotice(failed: failed),
                    ),
                  ),
                ),
              ),
            ),
          );
          await t.pumpAndSettle();
          expect(t.takeException(), isNull);
        }

        final semantics = t.ensureSemantics();
        try {
          await pump();
          expect(find.text('正在补齐消息…'), findsOneWidget);
          expect(find.byType(RaftRecipeButton), findsNothing);
          expect(
            t.getSemantics(find.text('正在补齐消息…')).getSemanticsData().label,
            contains('正在补齐消息'),
          );
          await pump(failed: true);
          expect(find.text('联网后自动补齐消息。'), findsOneWidget);
          expect(find.byType(RaftRecipeButton), findsNothing);
          await t.pumpWidget(const SizedBox.shrink());
        } finally {
          semantics.dispose();
        }
      });
    }
  }
}
