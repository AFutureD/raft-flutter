import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

class _Lifetime {
  int mounts = 0, disposals = 0;
}

class _Sidebar extends StatefulWidget {
  const _Sidebar(this.lifetime);
  final _Lifetime lifetime;
  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final edit = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.lifetime.mounts++;
  }

  @override
  void dispose() {
    widget.lifetime.disposals++;
    edit.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      TextField(controller: edit, focusNode: focus),
      Expanded(
        child: ListView.builder(
          controller: scroll,
          itemCount: 100,
          itemExtent: 40,
          itemBuilder: (_, i) => Text('Sidebar item $i'),
        ),
      ),
    ],
  );
}

Widget _host(_Lifetime lifetime, bool visible, {String authority = 'alice'}) =>
    MaterialApp(
      theme: raftTheme(RaftFamily.elegant),
      home: Scaffold(
        body: RaftAdaptiveWorkspace(
          key: ValueKey(authority),
          sidebarVisible: visible,
          sidebar: _Sidebar(lifetime),
          rail: const Text('Rail'),
          content: const SizedBox.expand(key: Key('content')),
        ),
      ),
    );

Future<void> _desktop(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1400, 700);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

void main() {
  testWidgets('visited sidebar retains editing and scroll state across pages', (
    tester,
  ) async {
    await _desktop(tester);
    final lifetime = _Lifetime();
    await tester.pumpWidget(_host(lifetime, true));
    final state = tester.state<_SidebarState>(find.byType(_Sidebar));
    await tester.enterText(find.byType(TextField), 'retained draft');
    state.scroll.jumpTo(500);
    await tester.pump();
    final initialContent = tester.getSize(find.byKey(const Key('content')));
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(_host(lifetime, false));
      expect(find.byType(TextField), findsNothing);
      expect(state.focus.hasFocus, isFalse);
      expect(
        tester.getSize(find.byKey(const Key('content'))).width,
        initialContent.width + 240,
      );
      await tester.pumpWidget(_host(lifetime, true));
      expect(tester.state(find.byType(_Sidebar)), same(state));
      expect(state.edit.text, 'retained draft');
      expect(state.scroll.offset, 500);
      expect(tester.getSize(find.byKey(const Key('content'))), initialContent);
    }
    expect(lifetime.mounts, 1);
    expect(lifetime.disposals, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unvisited sidebar is lazy and authority resets retained state', (
    tester,
  ) async {
    await _desktop(tester);
    final lifetime = _Lifetime();
    await tester.pumpWidget(_host(lifetime, false));
    expect(lifetime.mounts, 0);
    await tester.pumpWidget(_host(lifetime, true));
    expect(lifetime.mounts, 1);
    await tester.pumpWidget(_host(lifetime, false));
    await tester.pumpWidget(_host(lifetime, false, authority: 'bob'));
    expect(lifetime.disposals, 1);
    expect(lifetime.mounts, 1);
    await tester.pumpWidget(_host(lifetime, true, authority: 'bob'));
    final state = tester.state<_SidebarState>(find.byType(_Sidebar));
    expect(state.edit.text, isEmpty);
    expect(state.scroll.offset, 0);
    expect(lifetime.mounts, 2);
    expect(tester.takeException(), isNull);
  });

  for (final family in RaftFamily.values) {
    testWidgets(
      '$family hidden retained menu closes and rejects stale actions',
      (tester) async {
        final controller = RaftMenuController();
        addTearDown(controller.dispose);
        var actions = 0;
        Widget host(bool active) => MaterialApp(
          theme: raftTheme(family),
          home: Scaffold(
            body: TickerMode(
              enabled: active,
              child: RaftDropdownMenu(
                label: 'Sidebar menu',
                controller: controller,
                entries: [
                  RaftMenuEntry(label: 'Action', onPressed: () => actions++),
                ],
              ),
            ),
          ),
        );
        await tester.pumpWidget(host(true));
        controller.open();
        await tester.pumpAndSettle();
        final staleAction = tester
            .widget<RaftMenuItem>(find.byType(RaftMenuItem))
            .onPressed!;
        await tester.pumpWidget(host(false));
        await tester.pump();
        expect(controller.isOpen, isFalse);
        expect(find.byType(RaftMenuItem), findsNothing);
        staleAction();
        controller.open();
        await tester.pump();
        expect(controller.isOpen, isFalse);
        expect(actions, 0);
        await tester.pumpWidget(host(true));
        controller.open();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Action'));
        await tester.pumpAndSettle();
        expect(actions, 1);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
