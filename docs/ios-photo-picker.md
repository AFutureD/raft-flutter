# iOS permissionless photo selection

The composer media button, account and agent avatars, connected-app logos and
Feedback image attachments use Flutter's official `image_picker` 1.2.4 on iOS.
The mixed-media composer keeps images and videos; image-only controls retain an
image-only picker. Every gallery call explicitly sets `requestFullMetadata:
false`. Multi-selection has no additional iOS-only count limit; the existing
feature-level attachment validation remains authoritative. Cancellation returns no files.

On iOS 14+, the plugin uses Apple's PHPicker. The app already requires iOS 15,
so this change does not raise the deployment minimum. The app receives only the
items the person selects; the gallery flow does not request unrestricted photo
library access. `NSPhotoLibraryUsageDescription` is included as required by the
plugin's publishing guidance; its presence does not initiate a permission prompt.
No camera or microphone feature/permission is added.

The file button continues using the document picker. Other hosts retain their
existing document media and image selectors. Filtered groups now also supply
`uniformTypeIdentifiers`, which the iOS file-selector implementation requires.
Missing those identifiers caused the original immediate argument/format error.

Selections remain XFiles and retain the existing upload, account/permission
fences and pre-read file-size checks. The reviewed iOS image-picker implementation
copies selected files to private temporary storage; it converts unsupported image
representations, including HEIC, to JPEG and retains supported PNG/GIF formats.
The app does not add a second byte buffer for the selected batch.

Tests cover gallery-only calls, mixed/image-only filtering, disabled full metadata,
nine-item capacity and cancellation, alongside avatar and connected-app regression
coverage. Native compilation must verify plugin registration and Photos framework
linking. Actual Photos sheet presentation, limited-library behavior, iCloud
selection and device cancellation need physical-device acceptance.

Sources: [Flutter plugin](https://pub.dev/packages/image_picker),
[permissionless option history](https://pub.dev/packages/image_picker_ios/changelog),
[mixed media API](https://pub.dev/documentation/image_picker/latest/image_picker/ImagePicker/pickMultipleMedia.html).
