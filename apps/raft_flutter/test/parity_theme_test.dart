import 'package:flutter_test/flutter_test.dart';

import 'parity/parity_harness.dart';

void main() {
  final official = <String, dynamic>{'id': 'components.ui.button.states'};
  final elegantNamed = <String, dynamic>{
    'id': 'components.ui.button.states.elegant',
  };
  test('official cases render the one light look', () {
    expect(parityThemeFor(official), isFalse);
    expect(parityThemeFor(elegantNamed), isFalse);
  });
  test('supplemental runs choose light or dark explicitly', () {
    for (final c in [official, elegantNamed]) {
      expect(parityThemeFor(c, override: 'brutal-light'), isFalse);
      expect(parityThemeFor(c, override: 'elegant-light'), isFalse);
      expect(parityThemeFor(c, override: 'elegant-dark'), isTrue);
      expect(
        () => parityThemeFor(c, override: 'elegant-black'),
        throwsArgumentError,
      );
    }
  });
  test('extension cases name their theme', () {
    final dark = <String, dynamic>{
      'id': 'ext.case',
      'variants': [
        {
          'props': {'parityTheme': 'elegant-dark'},
        },
      ],
    };
    expect(parityThemeFor(dark), isTrue);
  });
}
