import 'package:flutter_test/flutter_test.dart';
import 'package:raft_agent_ui/raft_agent_ui.dart';

void main() {
  const entityKinds = [
    'message',
    'task',
    'agent',
    'channel',
    'member',
    'computer',
    'file',
  ];

  group('presets', () {
    test('every entity card has the inventory the product asked for', () {
      expect(agentDisplayKinds['message']!.elements, [
        'avatar',
        'author',
        'time',
        'channel',
        'text',
        'attachments',
        'reactions',
        'thread_count',
        'handle',
      ]);
      expect(agentDisplayKinds['task']!.elements, [
        'number',
        'title',
        'status',
        'assignee',
        'channel',
        'updated',
        'description',
        'latest_progress',
        'handle',
      ]);
      expect(agentDisplayKinds['agent']!.elements, [
        'avatar',
        'name',
        'state',
        'activity',
        'since',
        'computer',
        'channel',
        'model',
        'handle',
      ]);
      expect(agentDisplayKinds['channel']!.elements, [
        'name',
        'description',
        'unread',
        'mentions',
        'last_activity',
        'members',
        'handle',
      ]);
      expect(agentDisplayKinds['member']!.elements, [
        'avatar',
        'name',
        'role',
        'presence',
        'handle',
      ]);
      expect(agentDisplayKinds['computer']!.elements, [
        'name',
        'online',
        'runtimes',
        'agents',
        'version',
        'handle',
      ]);
      expect(agentDisplayKinds['file']!.elements, [
        'name',
        'type',
        'size',
        'thumbnail',
        'author',
        'handle',
      ]);
    });

    test('minimum is the headline, medium adds a meta line, detail is all', () {
      for (final kind in entityKinds) {
        final k = agentDisplayKinds[kind]!;
        final min = k.preset(AgentLevel.minimum);
        final med = k.preset(AgentLevel.medium);
        final det = k.preset(AgentLevel.detail);
        expect(min.length, 2, reason: '$kind: headline and handle');
        expect(min, contains('handle'));
        expect(med.containsAll(min), isTrue, reason: kind);
        expect(det, k.elements.toSet(), reason: '$kind detail is everything');
        expect(med.length, greaterThan(min.length), reason: kind);
      }
      expect(agentDisplayKinds['message']!.preset(AgentLevel.minimum), {
        'text',
        'handle',
      });
      expect(agentDisplayKinds['task']!.preset(AgentLevel.minimum), {
        'title',
        'handle',
      });
    });

    test('no level said: the kind keeps what it always drew', () {
      final quote = DisplaySpec.none.resolve('MessageQuote');
      expect(quote.level, AgentLevel.detail);
      expect(
        quote.has('author') && quote.has('bar') && quote.has('text'),
        true,
      );
      final entity = DisplaySpec.none.resolve('task');
      expect(entity.level, AgentLevel.medium);
      // The screen's default (a wide screen is detail) beats the kind's.
      expect(
        DisplaySpec.none
            .resolve('task', fallbackLevel: AgentLevel.detail)
            .level,
        AgentLevel.detail,
      );
    });

    test('level beats the fallback', () {
      const spec = DisplaySpec(level: AgentLevel.minimum);
      final x = spec.resolve('task', fallbackLevel: AgentLevel.detail);
      expect(x.level, AgentLevel.minimum);
      expect(x.shown, {'title', 'handle'});
    });
  });

  group('overrides', () {
    test('show turns single elements on and off over the preset', () {
      const spec = DisplaySpec(
        level: AgentLevel.medium,
        show: {'avatar': false, 'reactions': true},
      );
      final x = spec.resolve('message');
      expect(x.has('avatar'), isFalse);
      expect(x.has('reactions'), isTrue);
      expect(x.has('author'), isTrue);
      expect(x.has('thread_count'), isFalse);
    });

    test('a name the kind does not have is ignored when resolving', () {
      const spec = DisplaySpec(show: {'model': true, 'avatar': false});
      final x = spec.resolve('message');
      expect(x.shown.contains('model'), isFalse);
      expect(x.has('avatar'), isFalse);
    });

    test('lines default by level and clamp to 1 to 8', () {
      expect(
        const DisplaySpec(level: AgentLevel.minimum).resolve('message').lines,
        1,
      );
      expect(
        const DisplaySpec(level: AgentLevel.medium).resolve('message').lines,
        2,
      );
      expect(
        const DisplaySpec(level: AgentLevel.detail).resolve('message').lines,
        8,
      );
      expect(const DisplaySpec(lines: 5).resolve('message').lines, 5);
      expect(const DisplaySpec(lines: 99).resolve('message').lines, 8);
      expect(const DisplaySpec(lines: 0).resolve('message').lines, 1);
    });

    test('size is read and resolved, but there is one type ramp', () {
      // Hands-free screens draw one ramp (HfType): the field is kept so a
      // surface that names it is not refused, and it carries through.
      final x = const DisplaySpec(size: AgentSize.large).resolve('task');
      expect(x.size, AgentSize.large);
      expect(DisplaySpec.none.resolve('task').size, isNull);
    });

    test('json round trip, and anything off the schema is left out', () {
      const spec = DisplaySpec(
        level: AgentLevel.detail,
        show: {'avatar': false},
        lines: 3,
        size: AgentSize.regular,
      );
      expect(DisplaySpec.fromJson(spec.toJson()), spec);
      expect(DisplaySpec.fromJson(null), DisplaySpec.none);
      final odd = DisplaySpec.fromJson({
        'level': 'huge',
        'show': {'a': 1, 'b': true},
        'lines': 'x',
      });
      expect(odd.level, isNull);
      expect(odd.show, {'b': true});
      expect(odd.lines, isNull);
    });
  });

  group('inheritance (childDisplay)', () {
    const parent = DisplaySpec(
      level: AgentLevel.minimum,
      show: {'avatar': false, 'time': true},
    );

    test('a child with nothing of its own takes the parent\'s', () {
      final own = DisplaySpec.none.over(parent);
      expect(own, parent);
      final x = own.resolve('message');
      expect(x.level, AgentLevel.minimum);
      expect(x.has('time'), isTrue);
      expect(x.has('avatar'), isFalse);
    });

    test('a child override wins per field and per element', () {
      const child = DisplaySpec(
        level: AgentLevel.detail,
        show: {'avatar': true},
      );
      final x = child.over(parent).resolve('message');
      expect(x.level, AgentLevel.detail);
      expect(x.has('avatar'), isTrue, reason: 'the child turned it back on');
      expect(x.has('time'), isTrue, reason: 'still the parent\'s');
    });

    test('an element override alone keeps the parent\'s level', () {
      const child = DisplaySpec(show: {'reactions': true});
      final x = child.over(parent).resolve('message');
      expect(x.level, AgentLevel.minimum);
      expect(x.has('reactions'), isTrue);
    });

    test('the nearest list wins over a list further out', () {
      const outer = DisplaySpec(show: {'avatar': false}, lines: 2);
      const inner = DisplaySpec(show: {'avatar': true});
      final seen = inner.over(outer);
      expect(seen.show['avatar'], isTrue);
      expect(seen.lines, 2);
    });

    test('names of other kinds in the inherited spec are harmless', () {
      const spec = DisplaySpec(show: {'model': false, 'avatar': false});
      expect(() => spec.resolve('computer'), returnsNormally);
      expect(spec.resolve('computer').has('name'), isTrue);
    });
  });

  group('validation', () {
    test('an element the kind has not is refused with the valid ones', () {
      final problems = DisplaySpec.problems(
        {
          'show': {'model': true, 'avatar': false},
        },
        'message',
        'x<EntityCard>.display',
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('"model"'));
      for (final name in agentDisplayKinds['message']!.elements) {
        expect(problems.single, contains(name));
      }
    });

    test('valid names pass', () {
      for (final kind in entityKinds) {
        expect(
          DisplaySpec.problems(
            {
              'show': {
                for (final e in agentDisplayKinds[kind]!.elements) e: false,
              },
            },
            kind,
            'p',
          ),
          isEmpty,
        );
      }
    });

    test('the schema names every element with a boolean', () {
      final schema = agentDisplaySchema(['message']);
      final props = schema['properties']! as Map;
      expect((props['level']! as Map)['enum'], ['minimum', 'medium', 'detail']);
      expect((props['size']! as Map)['enum'], ['compact', 'regular', 'large']);
      final lines = props['lines']! as Map;
      expect(lines['minimum'], 1);
      expect(lines['maximum'], 8);
      final show = (props['show']! as Map)['properties']! as Map;
      expect(show.keys.toList(), agentDisplayKinds['message']!.elements);
      for (final e in show.values) {
        expect((e as Map)['type'], 'boolean');
      }
    });

    test('a list\'s schema takes the elements of every child kind', () {
      final schema = agentDisplaySchema(
        agentDisplayKinds.keys,
        childDisplay: true,
      );
      final show =
          ((schema['properties']! as Map)['show']! as Map)['properties']!
              as Map;
      for (final k in agentDisplayKinds.values) {
        for (final e in k.elements) {
          expect(show.containsKey(e), isTrue, reason: '${k.key}.$e');
        }
      }
    });
  });

  group('update_component merges display instead of replacing it', () {
    test('show merges per element and null resets one', () {
      final merged = mergeNodeProps(
        {
          'title': 'a',
          'display': {
            'level': 'medium',
            'show': {'avatar': false, 'time': false},
          },
        },
        {
          'display': {
            'show': {'avatar': null, 'reactions': true},
            'lines': 3,
          },
        },
      );
      expect(merged['title'], 'a');
      expect(merged['display'], {
        'level': 'medium',
        'show': {'time': false, 'reactions': true},
        'lines': 3,
      });
    });

    test('null removes the whole display, other fields stay shallow', () {
      final merged = mergeNodeProps(
        {
          'title': 'a',
          'display': {'level': 'minimum'},
        },
        {'display': null, 'title': 'b'},
      );
      expect(merged, {'title': 'b'});
    });

    test('an empty result drops the key', () {
      final merged = mergeNodeProps(
        {
          'display': {
            'show': {'avatar': false},
          },
        },
        {
          'display': {
            'show': {'avatar': null},
          },
        },
      );
      expect(merged.containsKey('display'), isFalse);
    });
  });
}
