import 'package:flutter/material.dart';

import 'hf_scope.dart';
import 'hf_tokens.dart';

/// "1–5 / 7  还有 2 项，说“下一批”". A phone or a desktop also gets a "下一批"
/// button. On the last page of several it says so and offers the first one.
class HfPager extends StatelessWidget {
  const HfPager({
    super.key,
    required this.from,
    required this.to,
    required this.total,
    this.onNext,
    this.nextKey,
    this.noun = '项',
  });

  /// First and last item shown, counting from 1, and how many there are.
  final int from, to, total;
  final VoidCallback? onNext;

  /// Put on the button.
  final Key? nextKey;

  /// What is counted: 项, 件.
  final String noun;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    final more = total - to;
    final paged = total > to - from + 1;
    final hint = more > 0
        ? '还有 $more $noun，说“下一批”'
        : paged
        ? '已经是最后一批，说“下一批”回到最前'
        : '';
    final range = Text(
      '$from–$to / $total',
      maxLines: 1,
      style: hf.type(HfType.body),
    );
    final hintText = hint.isEmpty
        ? null
        : Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: hf.type(HfType.meta, color: HfColors.inkSoft),
          );
    final button = hf.interactive && paged
        ? MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: nextKey,
              behavior: HitTestBehavior.opaque,
              onTap: onNext,
              child: Semantics(
                button: true,
                label: more > 0 ? '下一批' : '回到最前',
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
                      Text(
                        more > 0 ? '下一批' : '回到最前',
                        style: hf.type(HfType.body),
                      ),
                      Icon(
                        more > 0
                            ? Icons.chevron_right_rounded
                            : Icons.replay_rounded,
                        size: hf.sp(20),
                        color: HfColors.ink,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        : null;
    // With big system type the three do not fit on a line: they wrap.
    if (MediaQuery.textScalerOf(context).scale(10) > 13) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: hf.sp(12),
        runSpacing: hf.sp(6),
        children: [range, ?button, ?hintText],
      );
    }
    return Row(
      children: [
        range,
        SizedBox(width: hf.sp(12)),
        if (hintText != null) Expanded(child: hintText) else const Spacer(),
        if (button != null) ...[SizedBox(width: hf.sp(8)), button],
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
  const HfCaptionStrip({
    super.key,
    required this.caption,
    this.mood,
    this.moodWidget,
    this.who = 'AGENT',
    this.textKey,
  });
  final String caption;
  final String? mood;

  /// The mood as a widget (the badge that pops a new emoji in), instead of
  /// the plain [mood] disc.
  final Widget? moodWidget;

  /// Whose words these are: the round badge at the left (AGENT, 你).
  final String who;
  final Key? textKey;

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
                who,
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
                key: textKey,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: hf.type(HfType.headline),
              ),
            ),
            if (moodWidget != null) ...[
              SizedBox(width: hf.sp(10)),
              moodWidget!,
            ] else if (mood != null && mood!.isNotEmpty) ...[
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
/// and the agent's mood. A TV has none. Hold the microphone to talk
/// ([onMicDown], then [onMicUp] with how long), or tap it ([onMic]).
class HfDock extends StatelessWidget {
  const HfDock({
    super.key,
    this.onMic,
    this.onMicDown,
    this.onMicUp,
    this.onKeyboard,
    this.mood,
    this.moodWidget,
    this.listening = false,
    this.micIcon = Icons.mic_rounded,
    this.keyboardOpen = false,
  });
  final VoidCallback? onMic, onMicDown, onKeyboard;

  /// The finger left the microphone after this long.
  final ValueChanged<Duration>? onMicUp;
  final String? mood;

  /// The mood as a widget (see [HfCaptionStrip.moodWidget]).
  final Widget? moodWidget;

  /// The microphone is open: it turns pink.
  final bool listening;

  /// What the microphone shows: a mic, three dots while thinking, a wave
  /// while the agent speaks.
  final IconData micIcon;

  /// The keyboard is out (the button then puts it away).
  final bool keyboardOpen;

  @override
  Widget build(BuildContext context) {
    final hf = HandsFree.of(context);
    if (hf.tv) return const SizedBox.shrink();
    Widget round({
      Key? key,
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
          key: key,
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
    DateTime? down;
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
              key: const ValueKey('agent-keyboard'),
              diameter: 52 * k,
              color: HfColors.card,
              label: keyboardOpen ? '收起键盘' : '打字',
              onTap: onKeyboard,
              child: Icon(
                keyboardOpen
                    ? Icons.keyboard_hide_outlined
                    : Icons.keyboard_alt_outlined,
                size: hf.sp(26),
                color: HfColors.ink,
              ),
            ),
          ),
          gap,
          Listener(
            onPointerDown: (_) {
              down = DateTime.now();
              onMicDown?.call();
            },
            onPointerUp: (_) {
              final at = down;
              down = null;
              if (at != null) onMicUp?.call(DateTime.now().difference(at));
            },
            onPointerCancel: (_) {
              final at = down;
              down = null;
              if (at != null) onMicUp?.call(DateTime.now().difference(at));
            },
            child: round(
              key: const ValueKey('agent-orb'),
              diameter: 68 * k,
              color: listening ? HfColors.mention : HfColors.sticker,
              label: '麦克风',
              lift: 5,
              onTap: onMic,
              child: Icon(micIcon, size: hf.sp(38 * k), color: HfColors.ink),
            ),
          ),
          gap,
          Padding(
            padding: EdgeInsets.only(top: hf.sp(10 * k)),
            child:
                moodWidget ??
                (mood == null
                    ? SizedBox(width: hf.sp(52 * k), height: hf.sp(52 * k))
                    : HfMood(mood!, diameter: 52 * k)),
          ),
        ],
      ),
    );
  }
}
