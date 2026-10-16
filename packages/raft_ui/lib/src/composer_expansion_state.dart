part of 'components.dart';

/// The expanded editor of [RaftComposer]: opens a larger editor over the same
/// draft. The expanded text field uses the composer's own controller, undo
/// history, mention map and suggestion state, so there is one draft whichever
/// view is showing. Desktop opens a centered dialog; a narrow screen opens a
/// full-screen page.
extension _RaftComposerExpansion on _RaftComposerState {
  /// Runs a Markdown edit on the draft (toolbar buttons, format shortcuts).
  void applyFormat(TextEditingValue Function(TextEditingValue) op) {
    controller.value = op(controller.value);
  }

  void toggleExpanded() => expanded ? closeExpanded() : openExpanded();

  /// Whether Send is available now; shared by the inline and expanded rows.
  bool get submitReady =>
      widget.enabled &&
      widget.canSend &&
      !sending &&
      !widget.submitBusy &&
      !composing &&
      (controller.text.trim().isNotEmpty || widget.hasAttachments);

  void openExpanded() {
    // An IME composition lives in the inline field's input connection; moving
    // it mid-composition would drop or commit the marked text.
    if (expanded ||
        !presentationActive ||
        !widget.enabled ||
        composing ||
        sending ||
        widget.submitBusy) {
      return;
    }
    final phone =
        MediaQuery.sizeOf(context).width < RaftLayoutMetrics.desktopBreakpoint;
    final navigator = Navigator.of(context, rootNavigator: true);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    Widget content(BuildContext routeContext) => themes.wrap(
      Material(
        type: MaterialType.transparency,
        child: _expandedContent(phone: phone),
      ),
    );
    final route = phone
        ? MaterialPageRoute<void>(
            fullscreenDialog: true,
            builder: (c) => RaftDismissScope(child: content(c)),
          )
        : RaftDialogRoute<void>(
            capturedThemes: themes,
            label: raftText(context, 'Collapse editor'),
            builder: (c) => RaftComposerExpandedDialog(child: content(c)),
          );
    expandedRoute = route;
    controller.styled = true;
    expansion = navigator.push(route).whenComplete(_expandedClosed);
    // The expanded field's popup portal mounts with the route: switch the
    // popup over once it is built.
    updateSuggestionPortal(defer: true);
  }

  Widget _expandedContent({required bool phone}) => ListenableBuilder(
    listenable: Listenable.merge([controller, expandedChanges]),
    builder: (context, _) {
      final t = RaftTokens.of(context);
      final recipe = RaftComposerRecipe(t, desktop: !phone, bottomSafeInset: 0);
      final mac = switch (Theme.of(context).platform) {
        TargetPlatform.macOS || TargetPlatform.iOS => true,
        _ => false,
      };
      return RaftComposerExpandedView(
        phone: phone,
        title: widget.hint,
        controller: controller,
        onCollapse: closeExpanded,
        attachments: widget.attachments,
        previewBuilder: widget.previewBuilder,
        editor: LayoutBuilder(
          builder: (context, box) => OverlayPortal(
            controller: expandedPortal,
            overlayChildBuilder: (_) =>
                suggestionPopup(recipe, box.maxWidth, link: expandedLink),
            child: CompositedTransformTarget(
              link: expandedLink,
              child: buildEditorField(context, recipe, expanded: true),
            ),
          ),
        ),
        footer: (recipe) => RaftComposerActionRow(
          recipe: recipe,
          enabled: widget.enabled,
          busy: sending || widget.submitBusy,
          onImagePick: widget.onImagePick,
          onAttach: widget.onAttach,
          taskAction: widget.taskAction,
          submitTooltip: widget.submitTooltip,
          spinner: widget.submitSpinner,
          submitEnabled: submitReady,
          onSend: send,
          hint: phone
              ? null
              : raftText(
                  context,
                  mac
                      ? 'Enter adds a line · Cmd+Enter sends'
                      : 'Enter adds a line · Ctrl+Enter sends',
                ),
        ),
      );
    },
  );

  /// Collapses the editor; the draft stays as it is.
  void closeExpanded() {
    final route = expandedRoute;
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      route.navigator?.pop();
    } else {
      route.navigator?.removeRoute(route);
    }
  }

  void _expandedClosed() {
    expansion = null;
    expandedRoute = null;
    if (!mounted) return;
    controller.styled = false;
    updateSuggestionPortal();
    if (presentationActive && widget.enabled) focus.requestFocus();
  }

  /// The composer is leaving the tree while its editor is open: the route goes
  /// with it, once the tree is no longer locked.
  void closeExpandedAfterDispose() {
    final route = expandedRoute;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (route.isActive) route.navigator?.removeRoute(route);
    });
  }

  /// The expanded view follows state the composer holds (busy, enabled,
  /// attachments); it rebuilds after the composer does.
  void queueExpandedRefresh() {
    if (expandedRefreshQueued) return;
    expandedRefreshQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      expandedRefreshQueued = false;
      if (mounted && expanded) expandedChanges.value++;
    });
  }
}
