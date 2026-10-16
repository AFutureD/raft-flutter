import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';
import 'package:raft_ui/raft_ui.dart';

/// Fictional data only.
Widget _app(Widget child, {HfSurface? surface}) => MaterialApp(
  theme: raftTheme(RaftFamily.brutal),
  home: Scaffold(
    body: HandsFree(surface: surface, child: child),
  ),
);

void _size(WidgetTester t, Size size) {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

const _phone = Size(412, 915);
const _desktop = Size(1440, 900);
const _tv = Size(1920, 1080);

/// A whole screen made of every component.
Widget _screen() {
  return Builder(
    builder: (context) {
      final hf = HandsFree.of(context);
      final list = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HfSectionLabel('等你决定', tone: HfTone.decision, count: 2),
          SizedBox(height: hf.sp(10)),
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: hf.rowGap),
              child: HfRow(
                index: i + 1,
                tone: HfTone.decision,
                focusId: 'attention#${i + 1}',
                badge: i == 0 ? '最急' : null,
                meta: '#app-dev · 你派的任务',
                title: '验收「#12 修复登录跳转」',
                detail: 'Bo 做完了',
                stat: const HfStatBlock(label: '已等', value: '3', unit: '天'),
              ),
            ),
          const HfPager(from: 1, to: 3, total: 5),
        ],
      );
      return HfScreen(
        header: const HfHeader(
          title: '现在需要你',
          count: HfCountLine(
            counts: [
              HfCount(HfTone.decision, 2, '件等你决定'),
              HfCount(HfTone.blocked, 1, '件卡住了'),
            ],
          ),
        ),
        body: hf.split
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 46, child: list),
                  SizedBox(width: hf.sp(28)),
                  Expanded(
                    flex: 54,
                    child: HfDetail(
                      titleMode: HfDetailTitle.heading,
                      title: '验收「#12 修复登录跳转」',
                      status: '#app-dev · 等你验收',
                      tone: HfTone.decision,
                      facts: const [HfFact('谁', 'Bo'), HfFact('多久', '已等 3 天')],
                      progress: const [
                        HfProgressLine('10:32', 'Bo', '修复已提交，等你验收'),
                      ],
                      actions: [
                        HfAction('通过', kind: HfActionKind.primary),
                        const HfAction('打开讨论'),
                        const HfAction('稍后', kind: HfActionKind.text),
                      ],
                    ),
                  ),
                ],
              )
            : list,
        caption: HfCaptionStrip(
          caption: '先看第一件：Bo 做完了 #12，要验收吗？',
          mood: hf.interactive ? null : '🤔',
        ),
        dock: const HfDock(mood: '🤔'),
      );
    },
  );
}

void main() {
  group('scale', () {
    test('s = clamp(min(height / 540, width / 412), 1, 3)', () {
      expect(HfScale.of(_phone), 1.0);
      expect(HfScale.of(_desktop), closeTo(900 / 540, 1e-9));
      expect(HfScale.of(_tv), 2.0);
      // Below a phone nothing shrinks; far above, nothing grows past 3.
      expect(HfScale.of(const Size(320, 480)), 1.0);
      expect(HfScale.of(const Size(7680, 4320)), 3.0);
    });

    for (final (name, size, s, surface) in [
      ('phone', _phone, 1.0, HfSurface.phone),
      ('desktop', _desktop, 900 / 540, HfSurface.desktop),
      ('tv', _tv, 2.0, HfSurface.tv),
    ]) {
      testWidgets('HandsFree measures s at $name size', (t) async {
        _size(t, size);
        late HfData seen;
        await t.pumpWidget(
          _app(
            Builder(
              builder: (context) {
                seen = HandsFree.of(context);
                return const SizedBox();
              },
            ),
            surface: name == 'tv' ? HfSurface.tv : null,
          ),
        );
        expect(seen.s, closeTo(s, 1e-9));
        expect(seen.surface, surface);
        expect(seen.u, closeTo(4 * s, 1e-9));
        expect(seen.rowGap, closeTo(3 * 4 * s, 1e-9));
        // The headline is 22 s, a row's text never smaller than the ramp.
        expect(seen.type(HfType.headline).fontSize, closeTo(22 * s, 1e-9));
      });
    }

    test('colours mean something, in the spec values', () {
      expect(HfColors.of(HfTone.decision), const Color(0xffff5a69));
      expect(HfColors.of(HfTone.blocked), const Color(0xffff9a4d));
      expect(HfColors.of(HfTone.mention), const Color(0xffff8cc2));
      expect(HfColors.of(HfTone.progress), const Color(0xff7fe0a6));
      expect(HfColors.of(HfTone.info), const Color(0xff2ccbf0));
      expect(HfColors.of(HfTone.sticker), const Color(0xffffd441));
      expect(HfColors.toneOf(AgentPriority.blocked), HfTone.blocked);
    });
  });

  group('type', () {
    testWidgets('no text on a phone is below 13 px; row titles are 22', (
      t,
    ) async {
      _size(t, _phone);
      await t.pumpWidget(_app(_screen()));
      expect(t.takeException(), isNull);
      final sizes = <double>[];
      for (final r in t.widgetList<RichText>(find.byType(RichText))) {
        final size = r.text.style?.fontSize;
        if (size != null) sizes.add(size);
      }
      expect(sizes, isNotEmpty);
      expect(sizes.reduce((a, b) => a < b ? a : b), greaterThanOrEqualTo(13));
      for (final type in HfType.values) {
        expect(type.size, greaterThanOrEqualTo(13));
      }
      final title = t.widget<RichText>(
        find
            .byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText().startsWith('验收'),
            )
            .first,
      );
      expect(title.text.toPlainText(), contains('验收'));
      expect(title.text.style?.fontSize, greaterThanOrEqualTo(22));
    });
  });

  group('HfRow', () {
    testWidgets('title takes two lines, meta and detail one, then ellipsis', (
      t,
    ) async {
      _size(t, _phone);
      final long = '很长很长的标题' * 12;
      await t.pumpWidget(
        _app(
          SingleChildScrollView(
            child: HfRow(
              index: 1,
              tone: HfTone.blocked,
              meta: '#app-dev · ${'频道和原因' * 20}',
              title: long,
              detail: '补充说明' * 30,
              stat: const HfStatBlock(label: '没动', value: '2', unit: '天'),
            ),
          ),
        ),
      );
      expect(t.takeException(), isNull);
      RenderParagraph para(String start) => t.renderObject<RenderParagraph>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().startsWith(start),
        ),
      );
      final title = para('很长很长');
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.didExceedMaxLines, isTrue);
      final meta = para('#app-dev');
      expect(meta.maxLines, 1);
      expect(meta.didExceedMaxLines, isTrue);
      final detail = para('补充说明');
      expect(detail.maxLines, 1);
      expect(detail.didExceedMaxLines, isTrue);
      // 2 title lines at 22 px: the title is at most two lines tall.
      expect(title.size.height, lessThanOrEqualTo(2 * 22 * 1.2 + 1));
    });

    testWidgets(
      'bar and stat block are 56 s / 96 s narrow, 78 s / 150 s wide',
      (t) async {
        _size(t, _tv);
        Widget row(double width) => Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: const HfRow(
              index: 3,
              tone: HfTone.mention,
              title: '标题',
              stat: HfStatBlock(label: '已等', value: '3', unit: '天'),
            ),
          ),
        );
        await t.pumpWidget(_app(row(460)));
        // s = 2: a 460 px row is 230 s-units, narrow.
        expect(t.getSize(find.byType(HfStatBlock)).width, 96 * 2);
        await t.pumpWidget(_app(row(1400)));
        expect(t.getSize(find.byType(HfStatBlock)).width, 150 * 2);
      },
    );

    testWidgets('an entity row puts the state in the meta', (t) async {
      _size(t, _phone);
      await t.pumpWidget(
        _app(
          HfEntityRow(
            index: 2,
            status: '卡住了 · 2 天',
            title: 'Dex',
            detail: '#9 导出报表',
            priority: AgentPriority.blocked,
          ),
        ),
      );
      expect(find.text('卡住了 · 2 天'), findsOneWidget);
      expect(find.text('Dex'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('a focusable row can be pointed at', (t) async {
      _size(t, _phone);
      await t.pumpWidget(
        _app(
          const HfRow(index: 1, tone: HfTone.info, title: '甲', focusId: 'x#1'),
        ),
      );
      expect(find.byType(AgentFocusable), findsOneWidget);
      expect(t.widget<AgentFocusable>(find.byType(AgentFocusable)).id, 'x#1');
    });
  });

  group('HfAction', () {
    testWidgets('is at least 56 s high and presses on a phone', (t) async {
      _size(t, _phone);
      var pressed = 0;
      await t.pumpWidget(
        _app(
          Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 300,
              child: HfAction(
                '通过',
                kind: HfActionKind.primary,
                onPressed: () => pressed++,
              ),
            ),
          ),
        ),
      );
      expect(t.getSize(find.text('通过')).height, greaterThan(0));
      final box = t.getRect(find.byType(HfAction));
      expect(box.height, greaterThanOrEqualTo(56));
      await t.tap(find.text('通过'));
      expect(pressed, 1);
    });

    testWidgets('on a TV the same pills are voice hints that do not react', (
      t,
    ) async {
      _size(t, _tv);
      var pressed = 0;
      await t.pumpWidget(
        _app(
          HfActions(
            actions: [
              HfAction(
                '通过',
                kind: HfActionKind.primary,
                onPressed: () => pressed++,
              ),
              HfAction('打开讨论', onPressed: () => pressed++),
              HfAction(
                '稍后',
                kind: HfActionKind.text,
                onPressed: () => pressed++,
              ),
            ],
          ),
          surface: HfSurface.tv,
        ),
      );
      expect(find.text('通过'), findsNothing);
      expect(find.textContaining('「通过」'), findsOneWidget);
      expect(find.textContaining('「打开讨论」'), findsOneWidget);
      expect(find.textContaining('「稍后」'), findsOneWidget);
      expect(find.text('在手机上处理'), findsNothing);
      // Same pills: still at least 56 s (112 px at s = 2) high.
      expect(
        t.getSize(find.byType(HfAction).first).height,
        greaterThanOrEqualTo(112),
      );
      await t.tap(find.textContaining('「通过」'), warnIfMissed: false);
      expect(pressed, 0);
    });

    testWidgets('a confirm card on a TV shows the words to say', (t) async {
      _size(t, _tv);
      await t.pumpWidget(
        _app(
          const HfConfirm(message: '将把 #12 指派给 Bo —— 确认？'),
          surface: HfSurface.tv,
        ),
      );
      expect(find.text('将把 #12 指派给 Bo —— 确认？'), findsOneWidget);
      expect(find.text('确认'), findsNothing);
      expect(find.textContaining('「对」确认'), findsOneWidget);
      expect(find.textContaining('「取消」'), findsOneWidget);
      await t.pumpWidget(
        _app(
          const HfConfirm(message: '将把 #12 指派给 Bo —— 确认？'),
          surface: HfSurface.phone,
        ),
      );
      expect(find.text('确认'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });
  });

  group('screens', () {
    for (final (name, size, surface) in [
      ('phone', _phone, null),
      ('desktop', _desktop, null),
      ('tv', _tv, HfSurface.tv),
    ]) {
      testWidgets('a full screen lays out at $name size without overflow', (
        t,
      ) async {
        _size(t, size);
        await t.pumpWidget(_app(_screen(), surface: surface));
        expect(t.takeException(), isNull);
        if (name == 'tv') {
          // The desktop layout, without the dock: the mood is in the strip.
          expect(find.byType(HfDock), findsNothing);
          expect(find.byIcon(Icons.mic_rounded), findsNothing);
          expect(find.text('🤔'), findsOneWidget);
        } else {
          expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
        }
        if (name == 'phone') {
          expect(find.byType(HfDetail), findsNothing);
        } else {
          // Wide enough: the detail stands beside the list.
          expect(find.byType(HfDetail), findsOneWidget);
          expect(
            find.textContaining(name == 'tv' ? '「通过」' : '通过'),
            findsOneWidget,
          );
        }
        // The page fits: nothing is cut off at the bottom. (The test font is
        // wider than the real one, so the split layouts are judged by eye in
        // the gallery screenshots.)
        if (name == 'phone') {
          final scroll = t.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          expect(scroll.position.maxScrollExtent, 0);
        }
      });
    }

    testWidgets('detail and confirm screens fit at all three sizes', (t) async {
      for (final (size, surface) in [
        (_phone, null),
        (_desktop, null),
        (_tv, HfSurface.tv),
      ]) {
        _size(t, size);
        await t.pumpWidget(
          _app(
            HfScreen(
              header: const HfHeader(title: '#12 修复登录跳转'),
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  HfDetail(
                    titleMode: HfDetailTitle.none,
                    title: '#12 修复登录跳转',
                    status: '等你验收',
                    tone: HfTone.decision,
                    facts: const [
                      HfFact('谁', 'Bo'),
                      HfFact('哪', '#app-dev'),
                      HfFact('多久', '已等 3 天'),
                    ],
                    progress: const [
                      HfProgressLine('10:32', 'Bo', '修复已提交，等你验收'),
                      HfProgressLine('09:10', 'Bo', '跳转逻辑改完，补了两条测试'),
                    ],
                    actions: [
                      HfAction('通过', kind: HfActionKind.primary),
                      const HfAction('打开讨论'),
                      const HfAction('稍后', kind: HfActionKind.text),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const HfConfirm(message: '将把 #12 指派给 Bo —— 确认？'),
                ],
              ),
              caption: const HfCaptionStrip(caption: '要我现在通过吗？', mood: '😊'),
              dock: const HfDock(),
            ),
            surface: surface,
          ),
        );
        expect(t.takeException(), isNull, reason: '$size');
      }
    });
  });
}
