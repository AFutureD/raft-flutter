import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Page;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'edge_to_edge_audit_test.dart' show richFixture, settle;
import 'mobile_computer_navigation_test.dart' show loadComputerPageFonts;
import 'statusbar_audit_test.dart' show Page, pages;

const _dpr = 2.625;
void main() {
  final names = const String.fromEnvironment('PAGES').split(',');
  final theme = const String.fromEnvironment('THEME', defaultValue: 'elegant-light');
  final w = double.parse(const String.fromEnvironment('W', defaultValue: '816'));
  for (final p in pages.where((p) => names.any(p.name.startsWith))) {
    testWidgets('scratch ${p.name}', (t) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await loadComputerPageFonts(t);
      final f = richFixture();
      p.prepare?.call(f);
      await f.mount(t, theme, w, uri: Uri.parse(p.path));
      t.view.devicePixelRatio = _dpr;
      t.view.physicalSize = Size(w, 900) * _dpr;
      t.view.viewPadding = const FakeViewPadding(top: 40 * _dpr, bottom: 126);
      t.view.padding = const FakeViewPadding(top: 40 * _dpr, bottom: 126);
      await f.flush(t);
      await settle(t);
      await p.act?.call(t, f);
      final xs = const String.fromEnvironment('XS', defaultValue: '440').split(',').map(double.parse);
      for (final x in xs) {
        final pt = Offset(x, 41);
        print('=== ${p.name} x=$x');
        final hits = <String>[];
        void visit(Element e) {
          final ro = e.renderObject;
          if (e.renderObject is RenderBox && (e.renderObject as RenderBox).hasSize && e.renderObject!.attached) {
            final b = e.renderObject as RenderBox;
            try {
              final tl = b.localToGlobal(Offset.zero);
              final r = tl & b.size;
              if (r.contains(pt) && r.top <= 40.6) {
                final wd = e.widget;
                Color? c;
                if (wd is ColoredBox) c = wd.color;
                if (wd is DecoratedBox && wd.decoration is BoxDecoration) c = (wd.decoration as BoxDecoration).color;
                if (wd is Material) c = wd.color;
                if (wd is Container && wd.decoration is BoxDecoration) c = (wd.decoration as BoxDecoration).color;
                if (c != null || wd.runtimeType.toString().contains('Raft')) {
                  hits.add('${wd.runtimeType} ${c != null ? '#${c.toARGB32().toRadixString(16)}' : ''} rect=${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} ${r.width.toStringAsFixed(0)}x${r.height.toStringAsFixed(0)}');
                }
              }
            } catch (_) {}
          }
          e.visitChildren(visit);
        }
        t.binding.rootElement!.visitChildren(visit);
        hits.forEach(print);
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }
}
