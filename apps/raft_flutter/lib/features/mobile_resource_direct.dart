import 'package:flutter/widgets.dart';

import '../data/workspace_controller.dart';
import 'mobile_workspace_pages.dart';

/// Whether this phone route's body reads the outer workspace.
/// Each route has its own controller, so one page cannot overwrite another.
final mobilePageDirect = Expando<bool>();

/// Previous active bit for a phone route, without a new State field.
final mobileRouteWasActive = Expando<bool>();

/// Principal and page. Messages and presence are not inputs.
Object mobileResourceInputs(WorkspaceController controller, String section) =>
    (
      controller.client.generation,
      controller.client.user?.id,
      controller.server?.id,
      controller.server?.string('role'),
      section,
    );

/// Phone tasks and saved. Off builds [buildList] on the shadow controller.
/// On keeps one list for the active page, and only while its inputs change.
Widget mobileResourceBody({
  required String route,
  required WorkspaceController page,
  required WorkspaceController? outer,
  required Widget Function(WorkspaceController owner) buildList,
}) {
  final direct =
      (route == 'tasks' || route == 'saved') && mobilePageDirect[page] == true;
  if (!direct || outer == null) return buildList(page);
  return MobileResourceDirectPage(
    inputs: mobileResourceInputs(outer, route),
    active: () =>
        mobilePageIdentity(page.location) == mobilePageIdentity(outer.location),
    buildList: () => buildList(outer),
  );
}

/// The active phone list. A covered route returns nothing, so it does not
/// keep a second list on the outer workspace.
class MobileResourceDirectPage extends StatefulWidget {
  const MobileResourceDirectPage({
    super.key,
    required this.inputs,
    required this.active,
    required this.buildList,
  });

  final Object? inputs;
  final bool Function() active;
  final Widget Function() buildList;
  static int builds = 0;

  @override
  State<MobileResourceDirectPage> createState() =>
      _MobileResourceDirectPageState();
}

class _MobileResourceDirectPageState extends State<MobileResourceDirectPage> {
  Widget? _leaf;
  Object? _inputs;

  @override
  Widget build(BuildContext context) {
    if (!widget.active()) {
      _leaf = null;
      _inputs = null;
      return const SizedBox.shrink();
    }
    if (_leaf != null && widget.inputs == _inputs) return _leaf!;
    _inputs = widget.inputs;
    _leaf = widget.buildList();
    MobileResourceDirectPage.builds++;
    return _leaf!;
  }
}
