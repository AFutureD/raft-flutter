# AppImage tooling and host library policy

The tools lock records the latest official release assets reviewed on 2026-10-12.
Downloads must match the recorded SHA-256. AppImageKit's obsolete appimagetool is
not used. The current type2-runtime has static FUSE 3 and extract-and-run support.

`excludelist` is vendored unchanged from
https://github.com/AppImage/pkg2appimage/blob/19e30b276ffedf4d3b4b56bc6320f463625a74f8/excludelist.
Its rationale comments are retained. This keeps libc/device/display/font libraries
on the host and bundles the remaining GTK and media dependencies together.

The shipped runtime's MIT license and source snapshot metadata accompany the
payload. All copied distribution libraries and PDF commands carry their own
copyright notices, source package versions and digests in data/notices/raft-media.
