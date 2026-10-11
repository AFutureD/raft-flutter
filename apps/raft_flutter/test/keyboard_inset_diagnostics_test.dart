import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/platform/keyboard_inset_diagnostics.dart';

class _Host extends StatefulWidget {
  const _Host(this.log);
  final List<String> log;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host>
    with WidgetsBindingObserver, KeyboardInsetLogger<_Host> {
  @override
  void initState() {
    super.initState();
    insetLog = widget.log.add;
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets('logs keyboard transitions and the settled inset (debug only)', (
    tester,
  ) async {
    final log = <String>[];
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_Host(log));
    tester.view.viewInsets = const FakeViewPadding(bottom: 600);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 400);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 301));
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 301));
    expect(log, [
      'raft-inset keyboard shown: 300.0 dp',
      'raft-inset settled viewInsets.bottom=200.0 dp',
      'raft-inset keyboard hidden',
      'raft-inset settled viewInsets.bottom=0.0 dp',
    ]);
  });
}
