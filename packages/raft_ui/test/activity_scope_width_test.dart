import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

class _AnyLocale<T> extends LocalizationsDelegate<T> {
  const _AnyLocale(this.loadLocale);
  final Future<T> Function(Locale) loadLocale;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<T> load(Locale locale) => loadLocale(const Locale('en'));
  @override
  bool shouldReload(covariant LocalizationsDelegate<T> old) => false;
}

void main() {
  for (final family in RaftFamily.values) {
    for (final width in [768.0, 816.0]) {
      for (final (language, scale) in [('en', 1.0), ('zh', 1.3)]) {
        for (final withSearch in [false, true]) {
          testWidgets('$family $width $language $scale search=$withSearch '
              'keeps the read action visible and clickable', (t) async {
            t.view.physicalSize = Size(width, 900);
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
            final query = TextEditingController();
            final focus = FocusNode();
            addTearDown(query.dispose);
            addTearDown(focus.dispose);
            var reads = 0;
            final masterWidth = (width - 132) / 2;
            await t.pumpWidget(
              MaterialApp(
                theme: raftTheme(family),
                locale: Locale(language),
                supportedLocales: const [Locale('en'), Locale('zh')],
                localizationsDelegates: [
                  _AnyLocale<MaterialLocalizations>(
                    DefaultMaterialLocalizations.delegate.load,
                  ),
                  _AnyLocale<WidgetsLocalizations>(
                    DefaultWidgetsLocalizations.delegate.load,
                  ),
                  _AnyLocale<CupertinoLocalizations>(
                    DefaultCupertinoLocalizations.delegate.load,
                  ),
                ],
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: masterWidth,
                      child: RaftActivityScopeToolbar(
                        compact: true,
                        view: RaftActivityView.all,
                        onView: (_) {},
                        onOpenSwitcher: () {},
                        sort: 'desc',
                        onSort: (_) {},
                        search: withSearch
                            ? RaftActivitySearchInput(
                                controller: query,
                                focusNode: focus,
                                onChanged: (_) {},
                                onDismissEmpty: () {},
                              )
                            : null,
                        markAllRead: RaftTextButton(
                          key: const ValueKey('read-all'),
                          label: 'Mark all read',
                          visualHeight: 32,
                          minimumTargetSize: 32,
                          onPressed: () => reads++,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();
            expect(t.takeException(), isNull);
            final action = find.byKey(const ValueKey('read-all'));
            final toolbar = t.getRect(find.byType(RaftActivityScopeToolbar));
            final bounds = t.getRect(action);
            expect(bounds.left, greaterThanOrEqualTo(toolbar.left + 16));
            expect(bounds.right, lessThanOrEqualTo(toolbar.right - 16));
            final label = find.text(
              language == 'zh' ? '全部已读' : 'Mark all read',
            );
            expect(
              t.renderObject<RenderParagraph>(label).didExceedMaxLines,
              isFalse,
            );
            await t.tap(action);
            await t.pump();
            expect(reads, 1);
            expect(t.takeException(), isNull);
            await t.pumpWidget(const SizedBox.shrink());
          });
        }
      }
    }
  }
}
