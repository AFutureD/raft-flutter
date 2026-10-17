import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_reply_content.dart';

/// What the person said the reply should say, and whether a reply says it.

void main() {
  group('the words the person gave', () {
    const cases = {
      '回他可以': '可以',
      '回她可以': '可以',
      '回复他说可以合': '可以合',
      '回复他：可以合': '可以合',
      '回复可以合': '可以合',
      '回他说可以': '可以',
      '回他“晚上看”': '晚上看',
      '回他"晚上看"': '晚上看',
      '回复他说「晚上看」': '晚上看',
      '回他“晚上看”，然后再说': '晚上看',
      '跟他说我马上到': '我马上到',
      '跟她说：我马上到。': '我马上到',
      '和他说我在路上': '我在路上',
      '告诉她周五可以': '周五可以',
      '告诉他们明天见': '明天见',
      '发给他可以': '可以',
      '发个收到': '收到',
      '帮我回他可以': '可以',
      '好，回他可以': '可以',
      '回复 Cody 说可以合': '可以合',
      '回他可以。顺便': '可以',
    };
    for (final e in cases.entries) {
      test(e.key, () => expect(orbReplyContent(e.key), e.value));
    }

    test('no words given: no guard', () {
      for (final said in [
        '回他一下',
        '回复他吧',
        '回他',
        '回复他',
        '回他一声',
        '回复一下',
        '回头再看',
        '回来了',
        '稍后提醒我',
        '确认',
        '',
        '  ',
        '跟他说',
        '发给他',
      ]) {
        expect(orbReplyContent(said), isNull, reason: said);
      }
    });
  });

  group('whether the reply says them', () {
    test('the same words, with something around them', () {
      expect(orbSameContent('可以', '可以'), isTrue);
      expect(orbSameContent('@Cody 可以合', '可以合'), isTrue);
      // Punctuation does not count, so these are the same words.
      expect(orbSameContent('可以，合', '可以合'), isTrue);
      expect(orbSameContent('晚上 看。', '晚上看'), isTrue);
      expect(orbSameContent('“晚上看”', '晚上看'), isTrue);
    });

    test('a trailing 吧 / 啊 of speech may be missing', () {
      expect(orbSameContent('可以', '可以吧'), isTrue);
      expect(orbSameContent('周五可以', '周五可以啊'), isTrue);
      expect(orbSameContent('可以吧', '可以吧'), isTrue);
    });

    test('other words are not them (D3: 马上看 for 可以)', () {
      expect(orbSameContent('马上看', '可以'), isFalse);
      expect(orbSameContent('收到', '我马上到'), isFalse);
    });
  });
}
