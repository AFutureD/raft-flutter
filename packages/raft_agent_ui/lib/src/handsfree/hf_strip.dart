import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// "1–5 / 7  还有 2 项，说“下一批”". A phone or a desktop also gets a
/// "下一批" button.
class HfPager extends StatelessWidget {
  const HfPager({
    super.key,
    required this.from,
    required this.to,
    required this.total,
    this.onNext,
  });

  /// First and last item shown, counting from 1, and how many there are.
  final int from, to, total;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final more = total - to;
    return Row(
      children: [
        Text('$from–$to / $total', style: hf.type(HfType.body)),
        SizedBox(width: hf.sp(12)),
        if (more > 0)
          Expanded(
            child: Text(
              '还有 $more 项，说“下一批”',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: hf.type(HfType.meta, color: HfColors.inkSoft),
            ),
          )
        else
          const Spacer(),
        if (hf.interactive && more > 0) ...[
          SizedBox(width: hf.sp(8)),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onNext,
              child: Semantics(
                button: true,
                label: '下一批',
                excludeSemantics: true,
                child: Container(
                  constraints: BoxConstraints(minHeight: hf.sp(30)),
                  padding: EdgeInsets.symmetric(horizontal: hf.sp(14)),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: HfColors.card,
                    borderRadius: BorderRadius.circular(hf.sp(12)),
                    border: Border.all(color: HfColors.ink, width: hf.sp(3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('下一批', style: hf.type(HfType.body)),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: hf.sp(20),
                        color: HfColors.ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The mood of the agent as a cream disc with an emoji.
class HfMood extends StatelessWidget {
  const HfMood(this.mood, {super.key, this.diameter = 52});
  final String mood;

  /// In s-units.
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Container(
      width: hf.sp(diameter),
      height: hf.sp(diameter),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: HfColors.cream,
        shape: BoxShape.circle,
        border: Border.all(color: HfColors.ink, width: hf.sp(3)),
      ),
      child: Text(
        mood,
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: hf.sp(diameter * .55), height: 1.15),
      ),
    );
  }
}

/// The foot of every screen: what the agent says, in two lines, and (when
/// the screen has no dock) its mood. A phone puts it above the dock.
class HfCaptionStrip extends StatelessWidget {
  const HfCaptionStrip({super.key, required this.caption, this.mood});
  final String caption;
  final String? mood;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    return Semantics(
      liveRegion: true,
      label: caption,
      excludeSemantics: true,
      child: Container(
        height: hf.sp(64),
        padding: EdgeInsets.symmetric(horizontal: hf.sp(8)),
        decoration: BoxDecoration(
          color: HfColors.card,
          borderRadius: BorderRadius.circular(hf.sp(18)),
          border: Border.all(color: HfColors.ink, width: hf.sp(3)),
          boxShadow: [
            BoxShadow(color: HfColors.info, offset: Offset(hf.sp(6), hf.sp(6))),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: hf.sp(48),
              height: hf.sp(48),
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: HfColors.ink,
                shape: BoxShape.circle,
              ),
              child: Text(
                'AGENT',
                maxLines: 1,
                softWrap: false,
                style: hf
                    .type(HfType.meta, color: Colors.white)
                    .copyWith(letterSpacing: hf.sp(.2), fontSize: hf.sp(13)),
              ),
            ),
            SizedBox(width: hf.sp(12)),
            Expanded(
              child: Text(
                caption,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: hf.type(HfType.headline),
              ),
            ),
            if (mood != null && mood!.isNotEmpty) ...[
              SizedBox(width: hf.sp(10)),
              HfMood(mood!, diameter: 46),
            ],
          ],
        ),
      ),
    );
  }
}

/// The input area of a phone or desktop: a big microphone, a keyboard button
/// and the agent's mood. A TV has none. Visual only: wire [onMic] and
/// [onKeyboard] to the voice and text input of the screen.
class HfDock extends StatelessWidget {
  const HfDock({
    super.key,
    this.onMic,
    this.onKeyboard,
    this.mood,
    this.listening = false,
  });
  final VoidCallback? onMic, onKeyboard;
  final String? mood;

  /// The microphone is open: it turns pink.
  final bool listening;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    if (hf.tv) return const SizedBox.shrink();
    Widget round({
      required double diameter,
      required Color color,
      required Widget child,
      required String label,
      VoidCallback? onTap,
      double lift = 4,
    }) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: hf.sp(diameter),
            height: hf.sp(diameter),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: HfColors.ink, width: hf.sp(3)),
              boxShadow: [
                BoxShadow(color: HfColors.ink, offset: Offset(0, hf.sp(lift))),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
    // A desktop keeps the dock short so the list above has the room.
    final k = hf.phone ? 1.0 : .82;
    final gap = SizedBox(width: hf.sp(hf.phone ? 28 : 20));
    return SizedBox(
      height: hf.sp(76 * k),
      child: Row(
        mainAxisAlignment: hf.phone
            ? MainAxisAlignment.center
            : MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: hf.sp(10 * k)),
            child: round(
              diameter: 52 * k,
              color: HfColors.card,
              label: '键盘',
              onTap: onKeyboard,
              child: Icon(
                Icons.keyboard_alt_outlined,
                size: hf.sp(26),
                color: HfColors.ink,
              ),
            ),
          ),
          gap,
          round(
            diameter: 68 * k,
            color: listening ? HfColors.mention : HfColors.sticker,
            label: '麦克风',
            lift: 5,
            onTap: onMic,
            child: Icon(
              Icons.mic_rounded,
              size: hf.sp(38 * k),
              color: HfColors.ink,
            ),
          ),
          gap,
          Padding(
            padding: EdgeInsets.only(top: hf.sp(10 * k)),
            child: mood == null
                ? SizedBox(width: hf.sp(52 * k), height: hf.sp(52 * k))
                : HfMood(mood!, diameter: 52 * k),
          ),
        ],
      ),
    );
  }
}
