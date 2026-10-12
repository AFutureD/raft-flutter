import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

void main() {
  for (final (family, dark) in raftThemeMatrix([
    (RaftFamily.brutal, false),
    (RaftFamily.elegant, false),
    (RaftFamily.elegant, true),
  ])) {
    testWidgets(
      'prepared prose and code render from the same caches $family/$dark',
      (tester) async {
        raftMarkdownAstCache.clear();
        raftCodeSpanCache.clear();
        final tokens = RaftTokens.theme(family, dark: dark);
        const content =
            'Hello **中文** @alice\n\n```dart\nfinal value = 42;\n```';
        const refs = [
          RaftTextReference(
            text: '@alice',
            href: 'raft-ref://mention/user/alice',
          ),
        ];
        RaftMessageBody.prepareCache(
          content: content,
          tokens: tokens,
          references: refs,
          fontSize: 16,
        );
        final markdownMisses = raftMarkdownAstCache.misses,
            codeMisses = raftCodeSpanCache.misses;
        expect(markdownMisses, greaterThan(0));
        expect(codeMisses, 1);
        await tester.pumpWidget(
          MaterialApp(
            theme: raftTheme(family, dark: dark),
            home: Scaffold(
              body: const RaftMessageBody(
                content: content,
                references: refs,
                fontSize: 16,
                mountedMessage: true,
              ),
            ),
          ),
        );
        expect(raftMarkdownAstCache.misses, markdownMisses);
        expect(raftCodeSpanCache.misses, codeMisses);
        expect(raftMarkdownAstCache.hits, greaterThan(0));
        expect(raftCodeSpanCache.hits, greaterThan(0));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
