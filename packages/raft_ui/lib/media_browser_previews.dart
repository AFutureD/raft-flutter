import 'package:flutter/material.dart';

import 'previews.dart';
import 'raft_ui.dart';

@RaftPreviews('Media browser phone', size: Size(390, 844))
Widget mediaBrowserPhonePreview() => const _MediaBrowserPreview();

@RaftPreviews('Media browser phone, chrome hidden', size: Size(390, 844))
Widget mediaBrowserPhoneHiddenPreview() =>
    const _MediaBrowserPreview(chrome: false);

@RaftPreviews('Media browser phone landscape', size: Size(844, 390))
Widget mediaBrowserPhoneLandscapePreview() => const _MediaBrowserPreview();

@RaftPreviews('Media browser phone without caption', size: Size(390, 844))
Widget mediaBrowserPhoneNoCaptionPreview() =>
    const _MediaBrowserPreview(caption: false);

@RaftPreviews('Media browser desktop', size: Size(1280, 800))
Widget mediaBrowserDesktopPreview() => const _MediaBrowserDesktopPreview();

const _items = [
  RaftMediaStripItem(label: 'Image 1 of 8'),
  RaftMediaStripItem(
    label: 'Video 2 of 8',
    video: true,
    duration: Duration(seconds: 19),
  ),
  RaftMediaStripItem(label: 'Image 3 of 8'),
  RaftMediaStripItem(label: 'Image 4 of 8'),
  RaftMediaStripItem(
    label: 'Video 5 of 8',
    video: true,
    duration: Duration(minutes: 1, seconds: 3),
  ),
  RaftMediaStripItem(label: 'Image 6 of 8'),
  RaftMediaStripItem(label: 'Image 7 of 8'),
  RaftMediaStripItem(label: 'Image 8 of 8'),
];

class _Scene extends StatelessWidget {
  const _Scene();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF2C14E), Color(0xFF4F9D9D), Color(0xFF2B4570)],
      ),
    ),
    child: SizedBox.expand(),
  );
}

class _MediaBrowserPreview extends StatefulWidget {
  const _MediaBrowserPreview({this.chrome = true, this.caption = true});
  final bool chrome, caption;
  @override
  State<_MediaBrowserPreview> createState() => _MediaBrowserPreviewState();
}

class _MediaBrowserPreviewState extends State<_MediaBrowserPreview> {
  late final ValueNotifier<bool> chrome = ValueNotifier(widget.chrome);
  int index = 2;
  bool closed = false;

  @override
  void dispose() {
    chrome.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => closed
      ? Center(
          child: RaftButton(
            label: 'Open media',
            onPressed: () => setState(() => closed = false),
          ),
        )
      : RaftMediaImmersiveShell(
          title: 'IMG_2041.jpg',
          subtitle: 'Alice Chen · Oct 13, 2:02 PM',
          chrome: chrome,
          onClose: () => setState(() => closed = true),
          counter: RaftLightboxCounter(index: index, count: _items.length),
          actions: [
            RaftMediaAction(
              glyph: RaftGlyph.share2,
              label: 'Share',
              onPressed: (_) {},
            ),
            RaftMediaAction(
              glyph: RaftGlyph.ellipsis,
              label: 'More',
              onPressed: (_) {},
            ),
          ],
          caption: widget.caption
              ? 'Notes from the walkthrough: the new hall, the loading dock '
                    'and the second floor staircase, all before the handover.'
              : null,
          strip: RaftMediaStrip(
            compact: true,
            items: _items,
            index: index,
            onSelect: (i) => setState(() => index = i),
          ),
          child: GestureDetector(
            onTap: () => chrome.value = !chrome.value,
            child: const _Scene(),
          ),
        );
}

class _MediaBrowserDesktopPreview extends StatefulWidget {
  const _MediaBrowserDesktopPreview();
  @override
  State<_MediaBrowserDesktopPreview> createState() =>
      _MediaBrowserDesktopPreviewState();
}

class _MediaBrowserDesktopPreviewState
    extends State<_MediaBrowserDesktopPreview> {
  int index = 1;
  @override
  Widget build(BuildContext context) => RaftAttachmentLightbox(
    title: 'hall-walkthrough.mp4',
    subtitle: 'Alice Chen · Oct 13, 2:02 PM · 1920x1080 · 12.4 MB',
    leading: const RaftIcon(RaftGlyph.video, size: 16),
    titleBold: true,
    onClose: () {},
    meta: RaftLightboxCounter(index: index, count: _items.length),
    actions: [
      RaftLightboxIconAction(
        glyph: RaftGlyph.download,
        label: 'Download',
        onPressed: () {},
      ),
    ],
    overlayInset: raftMediaDesktopStripBand,
    overlay: RaftMediaStrip(
      items: _items,
      index: index,
      onSelect: (i) => setState(() => index = i),
    ),
    child: const _Scene(),
  );
}
