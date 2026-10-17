import 'package:flutter/material.dart';

import 'design_primitives.dart';
import 'icons.dart';
import 'dialog_card.dart'
    show RaftCloseButton, RaftTextSteps, raftCssTextStyle, showRaftModal;
import 'presentation.dart';
import 'settings_layout.dart' show RaftSpace;
import 'sheet.dart';
import 'theme.dart';

// A form is a window with inputs and a submit button (create a channel, edit a
// profile, rename). It is shown with `RaftPresentationPolicy.form`: a bottom
// sheet below 768 and a centered dialog from 768. One route carries both, so
// the window keeps its text, focus and caret when it crosses the breakpoint.
//
// The route knows the form; the form's scaffold (a dialog card, a form dialog)
// has to draw it. [RaftFormFrame] tells the scaffold which form it is in:
// outside any frame (a preview, a test that opens a plain dialog) a scaffold
// draws its dialog card as it always did.

/// Which form the window around this scaffold currently has.
class RaftFormFrame extends InheritedWidget {
  const RaftFormFrame({super.key, required this.form, required super.child});
  final RaftSurfaceForm form;

  /// The form of the enclosing presented window, or null when the scaffold is
  /// not in one.
  static RaftSurfaceForm? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RaftFormFrame>()?.form;

  /// Whether the scaffold is drawn as a bottom sheet.
  static bool sheetOf(BuildContext context) =>
      maybeOf(context) == RaftSurfaceForm.sheet;

  /// Whether the scaffold sits in a presented window (sheet or dialog) that
  /// already draws the scrim and centers its content.
  static bool framedOf(BuildContext context) => maybeOf(context) != null;

  @override
  bool updateShouldNotify(RaftFormFrame oldWidget) => form != oldWidget.form;
}

Widget _formContent(WidgetBuilder builder, RaftSurfaceForm form) => Material(
  type: MaterialType.transparency,
  child: RaftFormFrame(
    form: form,
    child: Builder(builder: builder),
  ),
);

/// The route [showRaftForm] pushes, for hosts that keep it (to close it when
/// their authority changes).
RaftPresentedRoute<T> raftFormRoute<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  RaftPresentationPolicy policy = RaftPresentationPolicy.form,
  RouteSettings? routeSettings,
  bool dismissible = false,
  String? label,
  double dialogMaxWidth = 560,
  double sheetInitialSize = RaftSheetMetrics.largeDetent,
}) => raftPresentedRoute<T>(
  context,
  policy: policy,
  content: (_, form) => _formContent(builder, form),
  routeSettings: routeSettings,
  dismissible: dismissible,
  label: label,
  dialogMaxWidth: dialogMaxWidth,
  sheetInitialSize: sheetInitialSize,
);

/// Opens a form. The sheet opens at the large detent: a form with inputs gets
/// the keyboard at once, and the sheet is then only as tall as the window
/// above it. [builder] builds the form's scaffold once; the scaffold draws
/// itself as a sheet or a dialog from [RaftFormFrame]. A scrim press does not
/// close a form (unsaved input would be lost); Esc, Back and the close button
/// do. [policy] is [RaftPresentationPolicy.confirm] for a form without inputs
/// (a question with two buttons), which stays a dialog on every width.
Future<T?> showRaftForm<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  RaftPresentationPolicy policy = RaftPresentationPolicy.form,
  RouteSettings? routeSettings,
  bool dismissible = false,
  String? label,
  double dialogMaxWidth = 560,
  double sheetInitialSize = RaftSheetMetrics.largeDetent,
}) => Navigator.of(context, rootNavigator: true).push(
  raftFormRoute<T>(
    context,
    builder: builder,
    policy: policy,
    routeSettings: routeSettings,
    dismissible: dismissible,
    label: label,
    dialogMaxWidth: dialogMaxWidth,
    sheetInitialSize: sheetInitialSize,
  ),
);

/// Opens [builder] in a window that does not close on a scrim press: a form
/// with inputs ([form]: a bottom sheet below 768, a dialog from 768), a Web
/// `Modal` ([modal]) or a dialog. For a host that decides at run time which of
/// the three a page needs.
Future<V?> showRaftWindow<V>(
  BuildContext context,
  WidgetBuilder builder, {
  bool modal = false,
  bool form = false,
}) => form
    ? showRaftForm<V>(context, builder: builder)
    : modal
    ? showRaftModal<V>(context, builder: builder)
    : showDialog<V>(
        context: context,
        // Web `DialogCard` / `ConfirmDialog`: no scrim close.
        barrierDismissible: false,
        builder: builder,
      );

/// A form drawn as a bottom sheet: the handle and a pinned title row with the
/// close button, the fields scrolling in between and the actions pinned at
/// the bottom (above the keyboard).
class RaftFormSheet extends StatelessWidget {
  const RaftFormSheet({
    super.key,
    required this.title,
    required this.onClose,
    required this.body,
    this.footer,
    this.uppercase = true,
    this.titleGlyph,
    this.closeButton,
  });

  /// The title as it is shown (already localized).
  final String title;
  final VoidCallback? onClose;
  final Widget body;

  /// The action row; stays in view while [body] scrolls.
  final Widget? footer;
  final bool uppercase;

  /// A leading icon in the title row.
  final RaftGlyph? titleGlyph;

  /// The scaffold's own close button; defaults to [RaftCloseButton].
  final Widget? closeButton;

  static const _closeFace = RaftMetrics.buttonSm;
  static const _titleLines = 2, _glyph = 18.0;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final style = raftCssTextStyle(
      family: t.headingFont,
      step: RaftTextSteps.lg,
      weight: FontWeight.w700,
      color: t.ink,
    );
    final text = uppercase ? title.toUpperCase() : title;
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        // The pinned header has one fixed height: as tall as the title needs,
        // up to two lines.
        final painter =
            TextPainter(
              text: TextSpan(text: text, style: style),
              textDirection: Directionality.of(context),
              textScaler: scaler,
              maxLines: _titleLines,
            )..layout(
              maxWidth:
                  box.maxWidth -
                  RaftSpace.x4 * 3 -
                  _closeFace -
                  (titleGlyph == null ? 0 : _glyph + RaftSpace.x4),
            );
        final textHeight = painter.height;
        painter.dispose();
        final extent =
            (textHeight > _closeFace ? textHeight : _closeFace) +
            RaftSpace.x2 * 2;
        return RaftSheet(
          header: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: RaftSpace.x4,
              vertical: RaftSpace.x2,
            ),
            child: Row(
              spacing: RaftSpace.x4,
              children: [
                if (titleGlyph != null)
                  RaftIcon(titleGlyph!, size: _glyph, color: t.ink),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      text,
                      maxLines: _titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
                ),
                closeButton ?? RaftCloseButton(onPressed: onClose),
              ],
            ),
          ),
          headerExtent: extent,
          padding: const EdgeInsets.fromLTRB(
            RaftSpace.x4,
            0,
            RaftSpace.x4,
            RaftSpace.x4,
          ),
          body: body,
          footer: footer == null
              ? null
              : Padding(
                  padding: const EdgeInsets.fromLTRB(
                    RaftSpace.x4,
                    RaftSpace.x2,
                    RaftSpace.x4,
                    RaftSpace.x2,
                  ),
                  child: footer,
                ),
        );
      },
    );
  }
}
