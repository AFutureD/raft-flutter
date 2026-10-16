import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_mode/agent_consent_tray.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_capability.dart';
import 'package:raft_flutter/features/agent_mode/capabilities/agent_consent.dart';
import 'package:raft_ui/raft_ui.dart';

/// What counts as the person agreeing, and the confirm cards they press.
void main() {
  group('reading the person\'s answer', () {
    test('short agreement is a yes', () {
      for (final said in [
        '对',
        '好',
        '好的',
        '确认',
        '可以',
        '行',
        '嗯，确认',
        '好，做吧',
        '没问题',
        '是的',
        'yes',
        'Yes!',
        'ok',
        'OK, go ahead',
        'sure',
        'confirm',
      ]) {
        expect(classifyUtterance(said), AgentUtterance.yes, reason: said);
      }
    });

    test('any negation is a no, even next to a yes', () {
      for (final said in [
        '不',
        '不要',
        '不用了',
        '别',
        '取消',
        '算了',
        '先不',
        '等等',
        '好吧，不用了',
        '确认？不对',
        '没有',
        'no',
        "don't",
        'cancel',
        'wait',
        'ok, never mind, stop',
      ]) {
        expect(classifyUtterance(said), AgentUtterance.no, reason: said);
      }
    });

    test('questions, long requests and other talk are not an answer', () {
      for (final said in [
        '可以吗？',
        '确认吗',
        '好多任务啊',
        '运行情况怎么样',
        '对于这个任务你怎么看',
        '给我看一下好的那个任务的详情和最近的进展情况',
        '这个任务怎么样',
        '第二个',
        '',
        '  ',
        'is it ok?',
        'okay but what about the other one tomorrow afternoon',
      ]) {
        expect(classifyUtterance(said), AgentUtterance.other, reason: said);
      }
    });
  });

  group('the ledger', () {
    var clock = DateTime.utc(2026, 10, 15, 12);
    late AgentConsentLedger ledger;
    setUp(() {
      clock = DateTime.utc(2026, 10, 15, 12);
      ledger = AgentConsentLedger(now: () => clock, random: Random(5));
      addTearDown(ledger.dispose);
    });

    AgentConsentRequest request(
      String token, {
      AgentCapabilityRisk risk = AgentCapabilityRisk.change,
      int step = 1,
      int total = 1,
    }) => AgentConsentRequest(
      token: token,
      capabilityId: 'tasks.finish',
      preview: const AgentActionPreview(
        summary: '把 #98 标记为已完成',
        changes: ['状态: 等验收 → 已完成'],
      ),
      risk: risk,
      expires: clock.add(const Duration(minutes: 2)),
      step: step,
      total: total,
    );

    test('nothing shown, nothing to consent to', () {
      ledger.userSaid('好的');
      expect(ledger.take('cf_x'), AgentConsentVerdict.pending);
    });

    test('a yes approves, once', () {
      ledger.previewShown(request('cf_a'));
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
      ledger.userSaid('好的');
      expect(ledger.take('cf_a'), AgentConsentVerdict.granted);
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
      expect(ledger.active, isEmpty);
    });

    test('speech arrives in chunks and is judged as a whole', () {
      ledger.previewShown(request('cf_a'));
      ledger.userSaid('不', fresh: true);
      expect(ledger.take('cf_a'), AgentConsentVerdict.declined);
      ledger.previewShown(request('cf_b'));
      ledger.userSaid('好', fresh: true);
      ledger.userSaid('的', fresh: false);
      expect(ledger.take('cf_b'), AgentConsentVerdict.granted);
    });

    test('only the newest ordinary preview is approved by a yes', () {
      ledger.previewShown(request('cf_a'));
      ledger.previewShown(request('cf_b'));
      ledger.userSaid('确认');
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
      expect(ledger.take('cf_b'), AgentConsentVerdict.granted);
    });

    test('a no cancels every preview that is waiting', () {
      ledger.previewShown(request('cf_a'));
      ledger.previewShown(request('cf_b'));
      ledger.userSaid('算了');
      expect(ledger.active, isEmpty);
      expect(ledger.take('cf_a'), AgentConsentVerdict.declined);
      expect(ledger.take('cf_b'), AgentConsentVerdict.declined);
    });

    test('a sensitive preview takes a tap, never words', () {
      ledger.previewShown(
        request('cf_s', risk: AgentCapabilityRisk.sensitive, total: 2),
      );
      ledger.userSaid('确认');
      ledger.userSaid('好的，可以');
      expect(ledger.take('cf_s'), AgentConsentVerdict.pending);
      expect(ledger.cardTapped(ledger.active.single.cardId, yes: true), isTrue);
      expect(ledger.take('cf_s'), AgentConsentVerdict.granted);
    });

    test('a card is decided once', () {
      ledger.previewShown(request('cf_a'));
      final id = ledger.active.single.cardId;
      expect(ledger.cardTapped(id, yes: true), isTrue);
      expect(ledger.cardTapped(id, yes: false), isFalse);
      expect(ledger.take('cf_a'), AgentConsentVerdict.granted);
      expect(ledger.cardTapped(id, yes: true), isFalse);
    });

    test('a press tells the app which request it decided', () {
      final seen = <(String, bool)>[];
      ledger.onTapped = (r, yes) => seen.add((r.token, yes));
      ledger.previewShown(request('cf_a'));
      ledger.cardTapped(ledger.active.single.cardId, yes: false);
      expect(seen, [('cf_a', false)]);
    });

    test('a preview runs out after its window', () {
      ledger.previewShown(request('cf_a'));
      ledger.userSaid('好');
      clock = clock.add(const Duration(minutes: 2));
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
      expect(ledger.active, isEmpty);
    });

    test('a new preview of the same token starts over', () {
      ledger.previewShown(request('cf_a'));
      ledger.userSaid('好');
      ledger.previewShown(request('cf_a'));
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
    });
  });

  group('the confirm cards', () {
    var clock = DateTime.utc(2026, 10, 15, 12);
    late AgentConsentLedger ledger;

    setUp(() {
      clock = DateTime.utc(2026, 10, 15, 12);
      ledger = AgentConsentLedger(now: () => clock, random: Random(5));
      addTearDown(ledger.dispose);
    });

    Future<void> show(WidgetTester t) async {
      t.view.physicalSize = const Size(800, 1400);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: raftTheme(RaftFamily.elegant, dark: false),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AgentConsentTray(ledger: ledger, now: () => clock),
            ),
          ),
        ),
      );
    }

    AgentConsentRequest request(
      String token, {
      AgentCapabilityRisk risk = AgentCapabilityRisk.change,
      int step = 1,
      int total = 1,
      String summary = '把 #98 标记为已完成',
    }) => AgentConsentRequest(
      token: token,
      capabilityId: 'tasks.finish',
      preview: AgentActionPreview(
        summary: summary,
        changes: const ['状态: 等验收 → 已完成'],
      ),
      risk: risk,
      expires: clock.add(const Duration(minutes: 2)),
      step: step,
      total: total,
    );

    testWidgets('the app draws the preview, 确认 approves it', (t) async {
      await show(t);
      expect(find.text('把 #98 标记为已完成'), findsNothing);
      ledger.previewShown(request('cf_a'));
      await t.pump();
      expect(find.text('把 #98 标记为已完成'), findsOneWidget);
      expect(find.textContaining('等验收'), findsOneWidget);
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);

      await t.tap(find.text('确认'));
      await t.pump();
      expect(ledger.active.single.approved, isTrue);
      expect(ledger.take('cf_a'), AgentConsentVerdict.granted);
      await t.pump();
      expect(find.text('把 #98 标记为已完成'), findsNothing);
    });

    testWidgets('取消 declines it', (t) async {
      await show(t);
      ledger.previewShown(request('cf_a'));
      await t.pump();
      await t.tap(find.text('取消'));
      await t.pump();
      expect(find.text('把 #98 标记为已完成'), findsNothing);
      expect(ledger.take('cf_a'), AgentConsentVerdict.declined);
    });

    testWidgets('a sensitive preview is marked, and says which step', (t) async {
      await show(t);
      ledger.previewShown(
        request('cf_s', risk: AgentCapabilityRisk.sensitive, step: 2, total: 2),
      );
      await t.pump();
      expect(find.text('敏感操作'), findsOneWidget);
      expect(find.textContaining('第 2/2 次确认'), findsOneWidget);
    });

    testWidgets('the card goes away when the confirmation runs out', (t) async {
      await show(t);
      ledger.previewShown(request('cf_a'));
      await t.pump();
      expect(find.text('把 #98 标记为已完成'), findsOneWidget);
      clock = clock.add(const Duration(minutes: 2, seconds: 1));
      await t.pump(const Duration(minutes: 2, seconds: 1));
      expect(find.text('把 #98 标记为已完成'), findsNothing);
      expect(ledger.take('cf_a'), AgentConsentVerdict.pending);
    });

    testWidgets('words that cancel take the card down', (t) async {
      await show(t);
      ledger.previewShown(request('cf_a'));
      await t.pump();
      ledger.userSaid('算了');
      await t.pump();
      // The card says it was cancelled for a moment, then goes.
      expect(find.text('已取消'), findsOneWidget);
      expect(find.text('确认'), findsNothing);
      final gone = AgentConsentLedger.cancelledStay + const Duration(seconds: 1);
      clock = clock.add(gone);
      await t.pump(gone);
      expect(find.text('把 #98 标记为已完成'), findsNothing);
    });

    testWidgets('each preview has its own card', (t) async {
      await show(t);
      ledger.previewShown(request('cf_a', summary: '甲'));
      ledger.previewShown(request('cf_b', summary: '乙'));
      await t.pump();
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsOneWidget);
      await t.tap(find.text('确认').first);
      await t.pump();
      expect(ledger.take('cf_a'), AgentConsentVerdict.granted);
      expect(ledger.take('cf_b'), AgentConsentVerdict.pending);
    });
  });
}
