import 'close_registry_dialogs.dart';
import 'close_registry_panels.dart';
import 'close_registry_popups.dart';
import 'close_registry_viewers.dart';
import 'close_surface.dart';

/// Every closable surface, across the four family registries.
List<CloseSurface> get allCloseSurfaces => [
  ...panelSurfaces,
  ...dialogSurfaces,
  ...popupSurfaces,
  ...viewerSurfaces,
];

/// Files that contain a surface API call but are not a surface themselves.
/// Each entry says why; a new entry needs a reviewer's agreement.
const closeScanExempt = <String, String>{
  // 'lib/features/x.dart': 'reason',
};
