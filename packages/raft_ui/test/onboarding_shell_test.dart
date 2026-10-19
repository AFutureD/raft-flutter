import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

Widget _host(Size size, {Widget? preview}) => MediaQuery(
  data: MediaQueryData(size: size),
  child: MaterialApp(
    theme: raftTheme(),
    home: RaftOnboardingShell(
      preview: preview,
      child: const SizedBox(
        key: Key('form'),
        width: double.infinity,
        height: 200,
      ),
    ),
  ),
);

void main() {
  testWidgets('lg width with a preview splits form panel and dot pane', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(const Size(1280, 800), preview: const SizedBox(key: Key('pv'))),
    );
    // grid-cols-[minmax(320px,2fr)_3fr]: 512 | 768; form panel px-10 (+ 1px hairline border-r) leaves 431.
    expect(tester.getSize(find.byKey(const Key('form'))).width, 431);
    expect(tester.getTopLeft(find.byKey(const Key('form'))).dx, 40);
    expect(tester.getTopLeft(find.byKey(const Key('pv'))).dx, 512 + 32);
    expect(tester.getSize(find.byKey(const Key('pv'))).width, 704);
    expect(tester.takeException(), isNull);
  });

  testWidgets('below lg the shell is the narrow form page without preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _host(const Size(390, 844), preview: const SizedBox(key: Key('pv'))),
    );
    expect(find.byKey(const Key('pv')), findsNothing);
    expect(find.byKey(const Key('form')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('splash body shows its label centred on the cream canvas', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: raftTheme(),
        home: const RaftServerResolutionBody(label: 'Restoring session…'),
      ),
    );
    expect(find.text('Restoring session…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
