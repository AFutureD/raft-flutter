// The Chinese catalog is split into l10n/zh_<feature>.dart files merged by the
// generated l10n/zh_index.g.dart (tool/gen_l10n_index.py). A const map spread
// silently lets a later catalog win a duplicate key, so this test is the
// duplicate-key detector: every key lives in exactly one catalog.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart'
    show raftChinese, raftChineseLateAdditions;
import 'package:raft_ui/src/l10n/zh_index.g.dart'
    show zhCatalogAll, zhCatalogParts;

void main() {
  test('every catalog file is merged and no key is declared twice', () {
    final owner = <String, String>{};
    final duplicates = <String>[];
    void add(String catalog, Map<String, String> entries) {
      for (final key in entries.keys) {
        final previous = owner[key];
        if (previous != null) {
          duplicates.add('"$key" is in both $previous and $catalog');
        }
        owner[key] = catalog;
      }
    }

    zhCatalogParts.forEach(add);
    add('raftChineseLateAdditions', raftChineseLateAdditions);
    expect(
      duplicates,
      isEmpty,
      reason:
          'A key must live in one l10n/zh_*.dart catalog only:\n'
          '${duplicates.join('\n')}',
    );
    expect(raftChinese.length, owner.length);
    expect(
      zhCatalogAll.length,
      zhCatalogParts.values.fold<int>(0, (n, m) => n + m.length),
    );
  });

  test('the generated index lists every zh_*.dart catalog file', () {
    // check-project runs every test from apps/raft_flutter; package tests run from raft_ui.
    final dir = [
      Directory('lib/src/l10n'),
      Directory('../../packages/raft_ui/lib/src/l10n'),
    ].firstWhere((d) => d.existsSync());
    final files =
        dir
            .listSync()
            .whereType<File>()
            .map((f) => f.uri.pathSegments.last)
            .where((n) => n.startsWith('zh_') && !n.endsWith('.g.dart'))
            .toList()
          ..sort();
    final index = File('${dir.path}/zh_index.g.dart').readAsStringSync();
    for (final file in files) {
      expect(index, contains("import '$file' show"), reason: file);
    }
    expect(zhCatalogParts.length, greaterThanOrEqualTo(files.length));
  });
}
