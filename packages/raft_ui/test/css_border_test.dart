import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/src/css_border.dart';

void main() {
  test('CSS border widths snap to whole device pixels like Blink', () {
    expect(raftCssBorderWidth(.5, 1), 1); // sub-pixel width paints 1px
    expect(raftCssBorderWidth(.5, 2), .5); // 1 device px
    expect(raftCssBorderWidth(.5, 3), closeTo(1 / 3, 1e-9)); // 1.5 floors to 1
    expect(raftCssBorderWidth(1, 3), 1);
    expect(raftCssBorderWidth(2, 1), 2);
    expect(raftCssBorderWidth(0, 3), 0);
  });
}
