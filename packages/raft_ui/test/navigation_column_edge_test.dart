import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart';
import 'package:raft_ui/test_themes.dart';

/// A painted vertical border stroke, in global coordinates.
class _Rule {
  const _Rule(this.x, this.width, this.height);
  final double x, width, height;
  @override
  String toString() => 'rule(x=$x w=$width h=$height)';
}

List<_Rule> _rules() {
  final rules = <_Rule>[];
  void visit(RenderObject node) {
    if (node is RenderDecoratedBox && node.hasSize) {
      final decoration = node.decoration;
      if (decoration is BoxDecoration && decoration.border is Border) {
        final border = decoration.border! as Border;
        final origin = node.localToGlobal(Offset.zero);
        if (border.left.width > 0 && border.left.style == BorderStyle.solid) {
          rules.add(_Rule(origin.dx, border.left.width, node.size.height));
        }
        if (border.right.width > 0 &&
            border.right.style == BorderStyle.solid) {
          rules.add(
            _Rule(
              origin.dx + node.size.width - border.right.width,
              border.right.width,
              node.size.height,
            ),
          );
        }
      }
    }
    node.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.renderViews.first);
  return rules;
}

void main() {
  const width = 900.0;
  const height = 900.0;
  const navWidth = 56.0;

  for (final family in [RaftFamily.brutal, RaftFamily.elegant]) {
    for (final direction in [TextDirection.ltr, TextDirection.rtl]) {
      for (final side in [RaftRailSide.start, RaftRailSide.end]) {
        final onRight = RaftRailSideScope.onRight(side, direction);
        testWidgets(
          '$family ${direction.name} rail ${side.name} '
          'keeps the divider on the content side',
          (t) async {
            t.view.physicalSize = const Size(width, height);
            t.view.devicePixelRatio = 1;
            addTearDown(t.view.reset);
            await t.pumpWidget(
              MaterialApp(
                theme: raftTheme(family, dark: false),
                home: Scaffold(
                  body: Directionality(
                    textDirection: direction,
                    child: RaftNavigationColumnScope(
                      onRight: onRight,
                      child: Row(
                        textDirection: TextDirection.ltr,
                        children: [
                          if (!onRight) _nav(onRight),
                          const Expanded(child: _ActivityEdge()),
                          if (onRight) _nav(onRight),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
            await t.pumpAndSettle();

            final content = t.getRect(find.byKey(const Key('content-panel')));
            final rules = _rules().where((r) => r.height >= 200).toList();
            final at = rules.where((r) => (r.x - content.left).abs() <= .6);
            if (onRight) {
              expect(
                at,
                isEmpty,
                reason:
                    'A ${family.name} line sits on the window edge at '
                    'x=${content.left}. Rules: $rules',
              );
              final boundary = rules.where(
                (r) => (r.x - content.right).abs() <= .6,
              );
              expect(
                boundary,
                isNotEmpty,
                reason:
                    'No divider faces the content at x=${content.right}. '
                    'Rules: $rules',
              );
            } else {
              expect(
                at.where((r) => (r.width - 1).abs() <= .1),
                isNotEmpty,
                reason:
                    'The Activity line is missing beside the column at '
                    'x=${content.left}. Rules: $rules',
              );
              expect(content.left, navWidth);
            }
          },
        );
      }
    }
  }
}

/// The navigation column's own facing divider, matching the desktop shell:
/// Brutal always, Elegant only when the column is on the right.
class _Nav extends StatelessWidget {
  const _Nav(this.onRight);
  final bool onRight;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final line = BorderSide(
      color: t.brutal ? Colors.black : t.colors['line-muted']!,
      width: t.brutal ? 2 : 1,
    );
    final border = t.brutal
        ? (onRight ? Border(left: line) : Border(right: line))
        : onRight
        ? Border(left: line)
        : null;
    return Container(
      key: const Key('nav-column'),
      width: 56,
      decoration: BoxDecoration(border: border),
    );
  }
}

Widget _nav(bool onRight) => _Nav(onRight);

class _ActivityEdge extends StatelessWidget {
  const _ActivityEdge();

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('content-panel'),
    decoration: BoxDecoration(
      border: RaftPanelEdge.besideNavigation(
        context,
        RaftPanelEdgeStyle.activityInbox,
      ),
    ),
  );
}
