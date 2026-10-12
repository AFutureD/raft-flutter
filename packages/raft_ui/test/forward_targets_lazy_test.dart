import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final theme in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets('large target directory builds visible rows only ($theme)', (
      t,
    ) async {
      final search = TextEditingController(), focus = FocusNode();
      var built = 0;
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(theme.$1, dark: theme.$2),
          home: SizedBox(
            width: 412,
            height: 600,
            child: RaftForwardPage(
              child: RaftForwardTargetsBody(
                search: RaftForwardSearchInput(
                  controller: search,
                  focusNode: focus,
                  placeholder: 'Search',
                  onChanged: (_) {},
                ),
                label: 'Targets',
                itemCount: 10000,
                itemBuilder: (_, index) {
                  built++;
                  return RaftForwardTargetRow(
                    label: 'Channel $index',
                    icon: const Icon(Icons.tag),
                    selected: false,
                    checkbox: true,
                    onTap: () {},
                  );
                },
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(built, lessThan(30));
      expect(find.text('Channel 9999'), findsNothing);
      await t.pumpWidget(const SizedBox());
      search.dispose();
      focus.dispose();
    });
  }
}
