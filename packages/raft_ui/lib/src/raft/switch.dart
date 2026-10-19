// raft-ui 0.7.1 `Switch` (dist `switchRecipe`): a 50x30 round track with a 1.5px ink border and a 22px thumb that
// carries its own 1.5px ring. Off is a `fill-muted` track; on is the `brand` sticker (ink border, `sticker-edge`
// ring) with a `sticker-paper` thumb; disabled reads `fill-muted` / `foreground-disabled`. Keyboard focus swaps the
// sticker ring for the `focus-ring`. The thumb slides 220ms on `ease-slide`, the track colours 150ms.
import 'package:flutter/material.dart';

import '../design_primitives.dart';
import '../theme.dart';
import '../tokens/tokens.dart';
import 'css_box.dart';
import 'ui_tokens.dart';

/// The fixed geometry of the 0.7.1 switch (`h-[30px] w-[50px] p-[2.5px]`, `size-[22px]`, `translate-x-5`).
abstract final class RaftSwitchMetrics {
  static const double width = 50, height = 30, padding = 2.5;
  static const double thumb = 22, travel = 20, ring = 1.5;
}

/// Controlled raft-ui 0.7.1 `Switch`. A null [onChanged] (or `enabled: false`) is `disabled` and never fires.
class RaftSwitchControl extends StatelessWidget {
  const RaftSwitchControl({
    super.key,
    required this.value,
    this.onChanged,
    this.enabled = true,
    this.semanticLabel,
    this.semanticDescription,
    this.focusNode,
    this.minimumTargetSize,
  });

  final bool value, enabled;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel, semanticDescription;
  final FocusNode? focusNode;

  /// Layout minimum around the 50x30 track (a larger tap target that does take space); null adds none.
  final double? minimumTargetSize;

  /// The thumb's left offset inside the padding box. Blink lays out in CSS px under an emulated device scale
  /// factor and paints the box snapped to whole CSS px (`19.5` paints at `20`); [RaftBorderSnap] mirrors that.
  static double _thumbOffset(double slide, double border) {
    final offset = RaftSwitchMetrics.travel * slide;
    if (!RaftBorderSnap.emulatedDeviceScaleFactor) return offset;
    final origin = border + RaftSwitchMetrics.padding;
    return (origin + offset).roundToDouble() - origin;
  }

  bool get _enabled => enabled && onChanged != null;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final ui = t.ui;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final disabled = !_enabled;
    // Touch density adds no layout (the 0.7.1 `after:` hit slop takes no space): [RaftInteractive] extends the 48px
    // hit target and semantics rect around the 50x30 track.
    final min = minimumTargetSize ?? 0;
    return RaftInteractive(
      onPressed: disabled ? null : () => onChanged!(!value),
      button: false,
      focusNode: focusNode,
      semanticLabel: semanticLabel,
      builder: (context, st) {
        final borderWidth = raftControlBorderPx(context, 1.5);
        // [track]: the `transition-[background-color,box-shadow]` 150ms ease-out; the thumb slides on `ease-slide`
        // while its colours follow the value at once (`transition-transform` only).
        final control = TweenAnimationBuilder<double>(
          tween: Tween<double>(end: value ? 1 : 0),
          duration: reduced ? Duration.zero : const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          builder: (context, on, _) => TweenAnimationBuilder<double>(
            tween: Tween<double>(end: value ? 1 : 0),
            duration: reduced
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: RaftEase.slide,
            builder: (context, slide, _) {
              final offFill = ui.fillMuted;
              final trackFill = disabled
                  ? ui.fillMuted
                  : Color.lerp(offFill, ui.brand, on)!;
              final disabledInk = raftChromeBlend(
                ui.foregroundDisabled,
                ui.fillMuted,
              );
              final trackBorder = disabled
                  ? disabledInk
                  : Color.lerp(ui.lineStrong, ui.stickerInk, on)!;
              final thumbFill = disabled
                  ? ui.fillMuted
                  : (value ? ui.stickerPaper : ui.layerCard);
              final thumbRing = disabled
                  ? disabledInk
                  : (value ? ui.stickerInk : ui.lineStrong);
              return RaftCssBox(
                radius: RaftSwitchMetrics.height / 2,
                fill: trackFill,
                borderWidth: borderWidth,
                borderColor: trackBorder,
                opaqueRings: true,
                rings: [
                  if (st.focusVisible)
                    for (final layer in ui.focusRing.layers)
                      RaftRing(layer.spread, layer.color)
                  else if (value)
                    RaftRing(RaftSwitchMetrics.ring, ui.stickerEdge),
                ],
                width: RaftSwitchMetrics.width,
                height: RaftSwitchMetrics.height,
                padding: const EdgeInsets.all(RaftSwitchMetrics.padding),
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: _thumbOffset(slide, borderWidth),
                  ),
                  child: RaftCssBox(
                    radius: RaftSwitchMetrics.thumb / 2,
                    fill: thumbFill,
                    opaqueRings: true,
                    rings: [RaftRing(RaftSwitchMetrics.ring, thumbRing)],
                    width: RaftSwitchMetrics.thumb,
                    height: RaftSwitchMetrics.thumb,
                  ),
                ),
              );
            },
          ),
        );
        Widget result = Semantics(
          toggled: value,
          hint: semanticDescription,
          child: ExcludeSemantics(child: control),
        );
        if (min > 0) {
          result = ConstrainedBox(
            constraints: BoxConstraints(minWidth: min, minHeight: min),
            child: Center(widthFactor: 1, heightFactor: 1, child: result),
          );
        }
        return result;
      },
    );
  }
}
