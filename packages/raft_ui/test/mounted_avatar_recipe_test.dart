import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/src/components.dart';
import 'package:raft_ui/src/icons.dart';
import 'package:raft_ui/src/mounted_avatar_recipe.dart';
import 'package:raft_ui/src/theme.dart';
import 'package:raft_ui/src/tooltip.dart';
import 'package:raft_ui/test_themes.dart';

const busy = RaftAvatarPresence(activity: RaftAvatarActivity.working);
Widget host(Widget child, bool dark) => MaterialApp(
  theme: raftTheme(dark: dark),
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

void main() {
  for (final (dark) in raftThemeMatrix([(false), (true)], full: true)) {
    for (final (context, extent, inner) in [
      (RaftMountedAvatarContext.panelHeader, 36.0, 32.0),
      (RaftMountedAvatarContext.compactList, 20.0, 18.0),
      (RaftMountedAvatarContext.previewMini, 14.0, 12.0),
    ]) {
      testWidgets(
        'mounted $context frame and real inner content ${dark ? 'dark' : 'light'}',
        (tester) async {
          await tester.pumpWidget(
            host(
              RaftMountedAvatarFrame(
                name: 'Public identity',
                avatarContext: context,
                child: const ColoredBox(
                  key: Key('public-content'),
                  color: Colors.red,
                ),
              ),
              dark,
            ),
          );
          expect(
            tester.getSize(find.byType(RaftMountedAvatarFrame)),
            Size.square(extent),
          );
          expect(
            tester.getSize(find.byKey(const Key('public-content'))),
            Size.square(inner),
          );
          final frame = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('mounted-avatar-frame')),
          );
          final decoration = frame.decoration as BoxDecoration;
          expect(decoration.border!.top.width, (extent - inner) / 2);
          expect(decoration.border!.top.color, Colors.transparent);
          expect(decoration.borderRadius, BorderRadius.circular(extent / 2));
          final fill = tester.widget<DecoratedBox>(
            find.byKey(const ValueKey('mounted-avatar-fallback-fill')),
          );
          final t = Theme.of(
            tester.element(find.byType(RaftMountedAvatarFrame)),
          ).extension<RaftTokens>()!;
          expect(
            (fill.decoration as BoxDecoration).color,
            t.colors['fill-strong'],
          );
          expect(
            find.byKey(const ValueKey('mounted-avatar-presence')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      'muted mention frame hides status without changing layout ${dark ? 'dark' : 'light'}',
      (tester) async {
        await tester.pumpWidget(
          host(
            const RaftAvatar(
              name: 'Cindy',
              kind: RaftAvatarKind.agent,
              mountedContext: RaftMountedAvatarContext.compactList,
              presence: busy,
              muted: true,
            ),
            dark,
          ),
        );
        expect(
          tester.getSize(find.byType(RaftMountedAvatarFrame)),
          const Size.square(20),
        );
        final frame = tester.widget<DecoratedBox>(
          find.byKey(const ValueKey('mounted-avatar-frame')),
        );
        expect(
          (frame.decoration as BoxDecoration).border!.top.color,
          Colors.black.withValues(alpha: .4),
        );
        expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, .6);
        expect(
          find.byKey(const ValueKey('mounted-avatar-presence')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'agent panel badge matches mounted DOM and remains outside image clip ${dark ? 'dark' : 'light'}',
      (tester) async {
        await tester.pumpWidget(
          host(
            const RaftMountedAvatarFrame(
              name: 'Cindy',
              identity: RaftMountedAvatarIdentity.agent,
              presence: busy,
              child: ColoredBox(color: Colors.blue),
            ),
            dark,
          ),
        );
        final badge = find.byKey(const ValueKey('mounted-avatar-presence'));
        final row = find.byType(RaftMountedAvatarFrame);
        final delta = tester.getTopLeft(badge) - tester.getTopLeft(row);
        expect(tester.getSize(badge), const Size.square(10));
        expect(delta.dx, 25);
        expect(delta.dy, 25);
        expect(
          find.ancestor(of: badge, matching: find.byType(ClipRRect)),
          findsNothing,
        );
        final decoration =
            tester.widget<DecoratedBox>(badge).decoration as BoxDecoration;
        expect(decoration.color, const Color(0xffffd440));
        expect(decoration.border!.top.width, 1);
        expect(decoration.boxShadow!.length, 1);
        final t = RaftTokens.of(tester.element(row));
        expect(decoration.boxShadow!.single.color, t.panel);
        expect(decoration.boxShadow!.single.spreadRadius, 2);

        await tester.pump();
        expect(tester.binding.hasScheduledFrame, isFalse);
      },
    );
    testWidgets(
      'explicit and nested Gravatar fallbacks use separate source glyph sizes ${dark ? 'dark' : 'light'}',
      (tester) async {
        await tester.pumpWidget(
          host(const RaftMountedAvatarFrame(name: 'Public human'), dark),
        );
        var glyph = tester.widget<RaftIcon>(find.byType(RaftIcon));
        expect(glyph.size, 18);
        final t = RaftTokens.of(
          tester.element(find.byType(RaftMountedAvatarFrame)),
        );
        expect(
          glyph.color,
          // opacity-70 over the token's own alpha (Raft hint is translucent).
          t.colors['foreground-placeholder']!.withValues(
            alpha: t.colors['foreground-placeholder']!.a * .7,
          ),
        );
        await tester.pumpWidget(
          host(
            const RaftMountedAvatarFrame(
              name: 'Public human',
              child: RaftMountedAvatarFallback(gravatar: true),
            ),
            dark,
          ),
        );
        glyph = tester.widget<RaftIcon>(find.byType(RaftIcon));
        expect(glyph.size, 18);
      },
    );
  }

  testWidgets(
    'unknown/human/deactivated status is not admitted and replacement clears badge',
    (tester) async {
      for (final identity in RaftMountedAvatarIdentity.values) {
        await tester.pumpWidget(
          host(
            RaftMountedAvatarFrame(
              name: 'Public',
              identity: identity,
              presence: busy,
            ),
            false,
          ),
        );
        expect(
          find.byKey(const ValueKey('mounted-avatar-presence')),
          identity == RaftMountedAvatarIdentity.agent
              ? findsOneWidget
              : findsNothing,
        );
      }
      await tester.pumpWidget(
        host(
          const RaftMountedAvatarFrame(
            name: 'Public',
            identity: RaftMountedAvatarIdentity.agent,
            presence: busy,
            deactivated: true,
          ),
          false,
        ),
      );
      expect(
        find.byKey(const ValueKey('mounted-avatar-presence')),
        findsNothing,
      );
      expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, .6);
      expect(find.byType(ColorFiltered), findsOneWidget);
      await tester.pumpWidget(
        host(
          const RaftMountedAvatarFrame(
            name: 'Public',
            identity: RaftMountedAvatarIdentity.agent,
          ),
          false,
        ),
      );
      expect(
        find.byKey(const ValueKey('mounted-avatar-presence')),
        findsNothing,
      );
      expect(find.byType(ColorFiltered), findsNothing);
    },
  );

  testWidgets(
    'external offline stays neutral, online external uses authorized activity',
    (tester) async {
      for (final online in [false, true]) {
        await tester.pumpWidget(
          host(
            RaftMountedAvatarFrame(
              name: 'Public external',
              identity: RaftMountedAvatarIdentity.agent,
              presence: RaftAvatarPresence(
                activity: RaftAvatarActivity.working,
                external: true,
                online: online,
              ),
            ),
            true,
          ),
        );
        final t = RaftTokens.of(
          tester.element(find.byType(RaftMountedAvatarFrame)),
        );
        final d =
            tester
                    .widget<DecoratedBox>(
                      find.byKey(const ValueKey('mounted-avatar-presence')),
                    )
                    .decoration
                as BoxDecoration;
        expect(
          d.color,
          online
              ? RaftAvatarStatusPrimitives.busy
              : t.colors['color-brutal-cyan'],
        );
      }
    },
  );

  testWidgets(
    'status tooltip is provider-owned and disposal releases the surface',
    (tester) async {
      await tester.pumpWidget(
        host(
          const RaftTooltipProvider(
            delay: Duration(milliseconds: 600),
            child: RaftMountedAvatarFrame(
              name: 'Public agent',
              identity: RaftMountedAvatarIdentity.agent,
              presence: RaftAvatarPresence(
                activity: RaftAvatarActivity.online,
                label: 'Online',
              ),
            ),
          ),
          false,
        ),
      );
      expect(
        tester.widget<RaftTooltip>(find.byType(RaftTooltip)).message,
        'Online',
      );
      await tester.pumpWidget(host(const SizedBox.shrink(), false));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RaftTooltip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('generic avatar preserves arbitrary size and original behavior', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(const RaftAvatar(name: 'Public generic', size: 44), false),
    );
    expect(find.byType(RaftMountedAvatarFrame), findsNothing);
    expect(tester.getSize(find.byType(RaftAvatar)), const Size.square(44));
    await tester.pumpWidget(
      host(
        const RaftAvatar(
          name: 'Public mounted',
          mountedContext: RaftMountedAvatarContext.compactList,
        ),
        false,
      ),
    );
    expect(tester.getSize(find.byType(RaftAvatar)), const Size.square(20));
    expect(find.byType(RaftMountedAvatarFrame), findsOneWidget);
  });
}
