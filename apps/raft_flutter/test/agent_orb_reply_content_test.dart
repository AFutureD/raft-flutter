import 'package:flutter_test/flutter_test.dart';
import 'package:raft_flutter/features/agent_orb/actions/orb_reply_content.dart';

/// What the person said the reply should say, and whether a reply says it.

void main() {
  bool known(String name) =>
      {'八戒', 'cody', 'grok', 'alice'}.contains(name.toLowerCase());

  OrbReplyWords? words(String said) => orbReplyWords(said, known: known);

  group('the words the person gave', () {
    // said: (the words, sure)
    const cases = <String, (String, bool)>{
      '回他可以': ('可以', true),
      '回她可以': ('可以', true),
      '回复他说可以合': ('可以合', true),
      '回复他：可以合': ('可以合', true),
      '回他说可以': ('可以', true),
      '回他“晚上看”': ('晚上看', true),
      '回他"晚上看"': ('晚上看', true),
      '回他说“晚上看”': ('晚上看', true),
      '回复他说「晚上看」': ('晚上看', true),
      '回他“晚上看”，然后再说': ('晚上看', true),
      // The person is named, in any script.
      '回复八戒说可以': ('可以', true),
      '回复 八戒 说可以': ('可以', true),
      '跟 Cody 说我马上到': ('我马上到', true),
      '跟八戒说我马上到': ('我马上到', true),
      '回复 @Grok：好的': ('好的', true),
      '回复 Cody 说可以合': ('可以合', true),
      '告诉八戒周五可以': ('周五可以', true),
      '告诉 Alice 周五可以': ('周五可以', true),
      '告诉八戒说周五可以': ('周五可以', true),
      '回复八戒可以': ('可以', true),
      // The pronouns end where the words begin.
      '跟他说我马上到': ('我马上到', true),
      '跟她说：我马上到。': ('我马上到', true),
      '和他说我在路上': ('我在路上', true),
      '告诉她周五可以': ('周五可以', true),
      '告诉他们明天见': ('明天见', true),
      '发给他可以': ('可以', true),
      '帮我回他可以': ('可以', true),
      '好，回他可以': ('可以', true),
      '回他可以。顺便': ('可以', true),
      // Read, but not sure enough to hold anyone to.
      '回复可以合': ('可以合', false),
      '回复收到': ('收到', false),
      '发个收到': ('收到', false),
      // A name nobody knows before 说: the words are clear, the name is not.
      '回复小明说可以': ('可以', false),
    };
    for (final e in cases.entries) {
      test(e.key, () {
        final w = words(e.key);
        expect(w?.text, e.value.$1);
        expect(w?.sure, e.value.$2, reason: 'sure');
      });
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
        expect(words(said), isNull, reason: said);
      }
    });

    test('a name nobody knows after 告诉 is not guessed at', () {
      expect(words('告诉小明周五可以'), isNull);
      expect(orbReplyWords('告诉八戒周五可以'), isNull, reason: 'no directory');
    });

    test('two people to answer: nothing is held', () {
      for (final said in [
        '回他可以，再跟 Alice 说明天见',
        '回他可以再跟 Alice 说明天见',
        '回复他说可以，另外告诉八戒周五可以',
        '回他可以。然后回复 Grok 说好的',
      ]) {
        expect(words(said), isNull, reason: said);
      }
      // One person, a comma in the words.
      expect(words('回他说可以，我马上到')?.text, '可以，我马上到');
    });

    test('a long name is the name, not the words', () {
      expect(words('回复 Cody Smith 说可以')?.text, '可以');
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
