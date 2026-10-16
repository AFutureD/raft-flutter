import 'package:flutter/material.dart';

import '../agent_theme.dart';
import 'hf_tokens.dart';

/// Everything a hands-free component needs to draw itself at the current
/// size: s, the surface, spacing, and the type ramp.
@immutable
class HfData {
  const HfData({
    required this.s,
    required this.surface,
    required this.size,
    required this.theme,
  });

  final double s;
  final HfSurface surface;
  final Size size;
  final RaftAgentTheme theme;

  bool get tv => surface == HfSurface.tv;
  bool get desktop => surface == HfSurface.desktop;
  bool get phone => surface == HfSurface.phone;

  /// Whether things can be pressed. A TV only shows.
  bool get interactive => !tv;

  /// A wide window shows the list and the detail side by side.
  bool get split => desktop && size.width >= HfScale.splitWidth;

  /// Base step 4s.
  double get u => 4 * s;

  /// Gap between rows: 3u, on a TV 3.5u.
  double get rowGap => (tv ? 3.5 : 3) * u;

  /// Screen margins: 4% of the width, 4% above, 6% below (a TV keeps its
  /// taskbar safe area).
  EdgeInsets get margin => EdgeInsets.fromLTRB(
    size.width * .04,
    size.height * .04,
    size.width * .04,
    size.height * .06,
  );

  /// Drawn width a base value takes.
  double sp(double base) => base * s;

  /// A text style from the ramp. [color] defaults to ink.
  TextStyle type(HfType t, {Color color = HfColors.ink, double? base}) {
    final px = (base ?? t.size) * s;
    final style = t.heading
        ? theme.heading(px, weight: t.weight)
        : theme.body(px, color: color, weight: t.weight);
    return style.copyWith(color: color, height: 1.2);
  }

  /// Vertical padding inside a row. A TV or a desktop window is only 540
  /// s-units tall (a phone is 915): three rows and a pager must fit, and a
  /// desktop also carries the dock, so its rows are packed closest.
  double get rowPad => phone ? 12 : 5;

  /// Rows a page of a list holds, pager included: a phone is tall enough for
  /// five, a TV or a desktop window (540 s-units) for three.
  int get listRows => phone ? 5 : 3;

  /// Rows a page of the attention list holds (sections take room too).
  int get attentionRows => phone ? 4 : 3;
}

/// Provides s, the surface and the type ramp to the hands-free components
/// below it. Put it at the top of a screen (it measures its own space), or
/// pass [surface] to force a TV or a phone layout.
class HandsFree extends StatelessWidget {
  const HandsFree({super.key, this.surface, required this.child});

  /// Null picks a phone below [HfScale.desktopWidth] and a desktop above.
  final HfSurface? surface;
  final Widget child;

  static HfData _measure(BuildContext context, Size size, HfSurface? surface) =>
      HfData(
        s: HfScale.of(size),
        size: size,
        surface:
            surface ??
            (size.width >= HfScale.desktopWidth
                ? HfSurface.desktop
                : HfSurface.phone),
        theme: RaftAgentTheme.of(context),
      );

  /// The data of the nearest [HandsFree]; without one, measured from the
  /// window.
  static HfData of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_HfScope>();
    return scope?.data ?? _measure(context, MediaQuery.sizeOf(context), null);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = box.hasBoundedWidth && box.hasBoundedHeight
          ? box.biggest
          : MediaQuery.sizeOf(context);
      return _HfScope(data: _measure(context, size, surface), child: child);
    },
  );
}

class _HfScope extends InheritedWidget {
  const _HfScope({required this.data, required super.child});
  final HfData data;

  @override
  bool updateShouldNotify(_HfScope old) =>
      old.data.s != data.s ||
      old.data.surface != data.surface ||
      old.data.size != data.size ||
      old.data.theme != data.theme;
}
