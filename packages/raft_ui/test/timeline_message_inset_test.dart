import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';

void main() {
  // Owner decision 2026-10-12 (intended difference from Web): on a phone the
  // message wrapper has no inset, so the Brutal avatar sits at 20 dp like the
  // header buttons; tablets and desktop keep Web's 12 dp.
  test('phone timeline rows drop the wrapper inset', () {
    const recipe = RaftTimelineCompositionRecipe();
    expect(recipe.messageInsetFor(390), EdgeInsets.zero);
    expect(recipe.messageInsetFor(767), EdgeInsets.zero);
    expect(recipe.messageInsetFor(768), recipe.messageInset);
    expect(recipe.messageInsetFor(1280), recipe.messageInset);
  });
}
