import 'package:flutter/material.dart';

import 'previews.dart';
import 'raft_ui.dart';

@RaftPreviews('Announcement modal', size: Size(900, 640))
Widget announcementModalPreview() => RaftAnnouncementModal(
  title: "What's new in Raft",
  pages: const [
    RaftAnnouncementPage(
      title: 'Server mode',
      body:
          'Open channels, threads and tasks side by side. Press `Cmd K` to '
          'jump anywhere.\n\n'
          '- Drag tabs between editor groups\n'
          '- Threads open next to their channel\n\n'
          '[Read the release notes](https://raft.build)',
    ),
    RaftAnnouncementPage(body: 'That is all for now. Thanks for using Raft!'),
  ],
  onClose: () {},
  onConfirm: () {},
);
