// Text-scale / tall-font audit harness for widget tests.
//
// Pumps a surface under several text scales and font sets and reports text
// that stops fitting. Intended use: a regression guard ("this surface must
// stay clean at 1.3x / 2x / tall CJK metrics") and a survey ("which surfaces
// break"), both from the same detector.
//
// What is detected (all by inspecting the laid-out render tree, no goldens):
//
//   overflow   RenderFlex/other "overflowed by" errors raised while pumping.
//   inkClipped The glyph ink of a paragraph (measured by rasterising a replica
//              of it, not by font metrics) extends past a clip that applies to
//              it: an ancestor clip (ClipRect, Stack/Container clip, ...) or
//              the paragraph's own overflow clip (maxLines/ellipsis, or a
//              tight parent box shorter than the text).
//   escapes    A paragraph's line box sticks out of a tight-height ancestor
//              (fixed SizedBox/Container height) without being clipped, i.e.
//              it paints over its neighbours.
//   truncated  A paragraph that fits at scale 1.0 now exceeds maxLines
//              (informational: an ellipsis is a legitimate answer to a larger
//              font; clip overflow without an ellipsis is reported as
//              `hardCut`).
//
// Scrolling clips (viewports, slivers) are ignored: text beyond a viewport is
// normal. Paragraphs containing inline widgets are measured by line metrics
// instead of a raster replica.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:raft_ui/raft_ui.dart' show RaftTextScaling;

import 'system_fonts.dart';

/// One way of presenting a surface.
class AuditMode {
  const AuditMode(this.name, {this.textScale = 1.0, this.locale});
  final String name;
  final double textScale;

  /// UI locale; `null` keeps the app default (en).
  final Locale? locale;

  static const base = AuditMode('1.0x');
  static const x13 = AuditMode('1.3x', textScale: 1.3);
  static const x2 = AuditMode('2.0x', textScale: 2.0);

  /// iOS Accessibility 5: body 17pt becomes 53pt (3.12x).
  static const x31 = AuditMode('3.1x', textScale: 3.1);
  static const standard = [base, x13, x2, x31];
}

/// Font set the process loads. Fonts cannot be unloaded, so a test file picks
/// one set (the tall set is exercised from its own file).
enum AuditFonts {
  /// Bundled design fonts, Noto Sans CJK as the CJK fallback.
  real,

  /// Every design family is replaced by Noto Sans CJK, so even Latin text gets
  /// the tall CJK fallback metrics (ascent 1.16, descent 0.288).
  tall,
}

bool _fontsLoaded = false;
final _trace = Platform.environment['RAFT_AUDIT_TRACE'] == '1';
void _t(String m) {
  if (_trace) stdout.writeln('[audit] $m');
}

Future<void> loadAuditFonts(WidgetTester t, AuditFonts fonts) => _fontsLoaded
    ? Future.value()
    : t.runAsync(() async {
        _fontsLoaded = true;
        final cjk = [
          for (final f in cjkTestFonts())
            if (f.existsSync()) ByteData.sublistView(f.readAsBytesSync()),
        ];
        for (final family in ['HankenGrotesk', 'Inter', 'Geist', 'GeistMono']) {
          ByteData bytes;
          if (fonts == AuditFonts.tall && cjk.isNotEmpty) {
            bytes = cjk.first;
          } else {
            try {
              bytes = await rootBundle.load(
                'packages/raft_ui/assets/fonts/$family.ttf',
              );
            } on FlutterError {
              bytes = await rootBundle.load('assets/fonts/$family.ttf');
            }
          }
          await (FontLoader(
            'packages/raft_ui/$family',
          )..addFont(Future.value(bytes))).load();
        }
        final sdk =
            Platform.environment['FLUTTER_ROOT'] ??
            '/home/kevinzhow/flutter-sdks/versions/3.47.6';
        final icons = File(
          '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (icons.existsSync()) {
          await (FontLoader('MaterialIcons')..addFont(
                Future.value(ByteData.sublistView(icons.readAsBytesSync())),
              ))
              .load();
        }
        if (cjk.isNotEmpty) {
          for (final family in [
            'Noto Sans CJK SC',
            'Noto Sans CJK TC',
            'Noto Sans CJK JP',
            'Noto Sans CJK KR',
            'sans-serif',
          ]) {
            final loader = FontLoader(family);
            for (final d in cjk) {
              loader.addFont(Future.value(d));
            }
            await loader.load();
          }
        }
      });

/// Delegates that give any locale (the harness uses zh) the English Material
/// and Widgets localizations, so only the surface's own strings change.
class _AnyLocale<T> extends LocalizationsDelegate<T> {
  const _AnyLocale(this.fallback);
  final Future<T> Function(Locale) fallback;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<T> load(Locale locale) => fallback(locale);
  @override
  bool shouldReload(covariant LocalizationsDelegate<T> old) => false;
}

final _delegates = <LocalizationsDelegate<dynamic>>[
  _AnyLocale<MaterialLocalizations>(
    (l) => DefaultMaterialLocalizations.delegate.load(const Locale('en')),
  ),
  _AnyLocale<WidgetsLocalizations>(
    (l) => DefaultWidgetsLocalizations.delegate.load(const Locale('en')),
  ),
];

/// A single finding.
class AuditFinding {
  AuditFinding(this.kind, this.text, this.detail, {this.rect, this.where = ''});
  final String kind;
  final String text;
  final String detail;
  final Rect? rect;
  final String where;
  Map<String, Object?> toJson() => {
    'kind': kind,
    'text': text,
    'detail': detail,
    'where': where,
    if (rect != null)
      'rect': [rect!.left, rect!.top, rect!.right, rect!.bottom],
  };
  @override
  String toString() =>
      '$kind "$text" $detail ${where.isEmpty ? '' : '@ $where'}';
}

class AuditReport {
  AuditReport(this.surface, this.mode);
  final String surface;
  final AuditMode mode;
  final overflow = <AuditFinding>[];
  final inkClipped = <AuditFinding>[];
  final escapes = <AuditFinding>[];
  final truncated = <AuditFinding>[];
  final hardCut = <AuditFinding>[];
  final errors = <AuditFinding>[];
  int paragraphs = 0;

  /// Findings that fail the surface (truncation with an ellipsis does not).
  List<AuditFinding> get failures => [
    ...overflow,
    ...inkClipped,
    ...escapes,
    ...hardCut,
    ...errors,
  ];
  bool get ok => failures.isEmpty;
  Set<String> get kinds => {
    if (overflow.isNotEmpty) 'overflow',
    if (inkClipped.isNotEmpty) 'inkClipped',
    if (escapes.isNotEmpty) 'escapes',
    if (hardCut.isNotEmpty) 'hardCut',
    if (errors.isNotEmpty) 'error',
  };
  Map<String, Object?> toJson() => {
    'surface': surface,
    'mode': mode.name,
    'ok': ok,
    'paragraphs': paragraphs,
    for (final (k, l) in [
      ('overflow', overflow),
      ('inkClipped', inkClipped),
      ('escapes', escapes),
      ('hardCut', hardCut),
      ('truncated', truncated),
      ('errors', errors),
    ])
      k: [for (final f in l) f.toJson()],
  };
}

/// The marks drawn over a captured surface.
class _Marks extends CustomPainter {
  _Marks(this.marks) : super(repaint: marks);
  final ValueNotifier<List<(Rect, Color)>> marks;
  @override
  void paint(Canvas canvas, Size size) {
    for (final (r, c) in marks.value) {
      canvas.drawRect(
        r.inflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = c,
      );
    }
  }

  @override
  bool shouldRepaint(_Marks old) => false;
}

bool _isIconFont(InlineSpan s) {
  final f = s.style?.fontFamily ?? '';
  return f.contains('Icons') || f.contains('Symbols');
}

class _Collected {
  _Collected(this.render, this.text);
  final RenderBox render; // RenderParagraph or RenderEditable
  final String text;
}

void _collect(RenderObject r, List<_Collected> out) {
  if (r is RenderOffstage && r.offstage) return;
  if (r is RenderParagraph) {
    final text = r.text.toPlainText(includePlaceholders: false).trim();
    if (text.isNotEmpty && !_isIconFont(r.text) && r.hasSize) {
      out.add(_Collected(r, text));
    }
  } else if (r is RenderEditable) {
    final t = r.text;
    final text = t?.toPlainText(includePlaceholders: false).trim() ?? '';
    if (text.isNotEmpty && r.hasSize) out.add(_Collected(r, text));
  }
  r.visitChildren((c) => _collect(c, out));
}

String _where(RenderObject r) {
  final dc = r.debugCreator;
  if (dc is! DebugCreator) return '';
  final locs = <String>[];
  String? loc(Widget w) {
    try {
      final json = w.toDiagnosticsNode().toJsonMap(
        InspectorSerializationDelegate(
          service: WidgetInspectorService.instance,
          includeProperties: false,
          subtreeDepth: 0,
        ),
      );
      final c = json['creationLocation'];
      if (c is Map) {
        final file = '${c['file']}'.split('/lib/').last;
        return '$file:${c['line']}';
      }
    } catch (_) {}
    return null;
  }

  final first = loc(dc.element.widget);
  if (first != null) locs.add('${dc.element.widget.runtimeType}=$first');
  dc.element.visitAncestorElements((e) {
    final l = loc(e.widget);
    if (l != null && !locs.any((x) => x.endsWith(l))) {
      locs.add('${e.widget.runtimeType}=$l');
    }
    return locs.length < 4;
  });
  return locs.join(' < ');
}

bool _isScrollBoundary(RenderObject r) =>
    r is RenderAbstractViewport || r is RenderSliver;

/// Runs the detector on whatever is currently pumped.
///
/// [base] is the report of the same surface at 1.0x (for `truncated`).
Future<void> inspectPumped(
  WidgetTester t,
  AuditReport report, {
  AuditReport? base,
  Map<String, bool>? truncatedBase,
  required ValueNotifier<List<(Rect, Color)>> marks,
  double tolerance = 0.75,
}) async {
  final root = t.binding.renderViews.first;
  final all = <_Collected>[];
  _collect(root, all);
  report.paragraphs = all.length;
  final newMarks = <(Rect, Color)>[];
  final seen = <String, int>{};
  for (final c in all) {
    final box = c.render;
    final xf = box.getTransformTo(null);
    final rect = MatrixUtils.transformRect(xf, Offset.zero & box.size);
    final n = seen[c.text] = (seen[c.text] ?? 0) + 1;
    final key = '${c.text}#$n';
    final (
      InlineSpan span,
      TextScaler scaler,
      int? maxLines,
      TextOverflow overflow,
      bool didExceed,
      bool softWrap,
      ui.TextDirection dir,
      Locale? locale,
      StrutStyle? strut,
      TextWidthBasis basis,
      ui.TextHeightBehavior? thb,
      TextAlign align,
    ) = box is RenderParagraph
        ? (
            box.text,
            box.textScaler,
            box.maxLines,
            box.overflow,
            box.didExceedMaxLines,
            box.softWrap,
            box.textDirection,
            box.locale,
            box.strutStyle,
            box.textWidthBasis,
            box.textHeightBehavior,
            box.textAlign,
          )
        : (
            (box as RenderEditable).text!,
            box.textScaler,
            box.maxLines,
            TextOverflow.clip,
            false,
            true,
            box.textDirection,
            box.locale,
            box.strutStyle,
            TextWidthBasis.parent,
            box.textHeightBehavior,
            box.textAlign,
          );

    // Truncation bookkeeping.
    if (report.mode.name == '1.0x') {
      (truncatedBase ?? {})[key] = didExceed;
    } else if (didExceed &&
        truncatedBase != null &&
        truncatedBase[key] == false) {
      report.truncated.add(
        AuditFinding(
          'truncated',
          c.text,
          'maxLines=$maxLines overflow=$overflow',
          rect: rect,
          where: _where(box),
        ),
      );
      if (overflow == TextOverflow.clip) {
        report.hardCut.add(
          AuditFinding(
            'hardCut',
            c.text,
            'exceeds maxLines=$maxLines with overflow: clip (no ellipsis)',
            rect: rect,
            where: _where(box),
          ),
        );
        newMarks.add((rect, const Color(0xFFFF8800)));
      }
    }

    // ---- clips that apply to this paragraph ------------------------------
    final clips = <(Rect, String)>[];
    var selfClip = false;
    if (box is RenderParagraph) {
      final natural = box.getMaxIntrinsicHeight(box.size.width);
      selfClip =
          didExceed ||
          box.size.height + 0.01 < natural ||
          (!softWrap &&
              box.size.width + 0.01 <
                  box.getMaxIntrinsicWidth(double.infinity));
      if (overflow == TextOverflow.visible) selfClip = false;
      if (selfClip)
        clips.add((
          rect,
          'own overflow clip (${box.size.height.toStringAsFixed(1)}px box)',
        ));
    } else {
      // RenderEditable clips to its own size.
      clips.add((rect, 'RenderEditable'));
    }
    RenderObject child = box;
    for (var a = box.parent; a != null; child = a, a = a.parent) {
      if (_isScrollBoundary(a)) break;
      if (a is RenderBox) {
        Rect? clip;
        try {
          clip = a.describeApproximatePaintClip(child);
        } catch (_) {}
        // The long-message collapse ("Show more") hides content on purpose and
        // offers the toggle; it is not text cut by accident.
        if (clip != null &&
            a is! RenderEditable &&
            !(a is RenderClipRect &&
                _where(a).contains('src/collapsible.dart'))) {
          clips.add((
            MatrixUtils.transformRect(a.getTransformTo(null), clip),
            a.runtimeType.toString(),
          ));
        }
      }
    }

    // ---- ink -------------------------------------------------------------
    Rect? ink;
    if (clips.isNotEmpty) {
      ink = await _inkRect(
        t,
        box,
        span,
        scaler,
        maxLines,
        overflow,
        softWrap,
        dir,
        locale,
        strut,
        basis,
        thb,
        align,
        xf,
      );
    }
    if (ink != null) {
      for (final (clip, who) in clips) {
        final top = clip.top - ink.top;
        final bottom = ink.bottom - clip.bottom;
        final left = clip.left - ink.left;
        final right = ink.right - clip.right;
        // Vertical cut; horizontal cuts of ellipsised/clipped single lines are
        // the point of the clip, so only report them for non-paragraph clips.
        final horizontal = who != 'RenderEditable' && !who.startsWith('own');
        final cut = <String>[
          if (top > tolerance) 'top ${top.toStringAsFixed(1)}px',
          if (bottom > tolerance) 'bottom ${bottom.toStringAsFixed(1)}px',
          if (horizontal && left > tolerance)
            'left ${left.toStringAsFixed(1)}px',
          if (horizontal && right > tolerance)
            'right ${right.toStringAsFixed(1)}px',
        ];
        if (cut.isNotEmpty) {
          report.inkClipped.add(
            AuditFinding(
              'inkClipped',
              c.text,
              '${cut.join(', ')} cut by $who',
              rect: ink,
              where: _where(box),
            ),
          );
          newMarks.add((ink, const Color(0xFFFF0000)));
          break;
        }
      }
    }

    // ---- escapes a tight-height ancestor ----------------------------------
    if (box is RenderParagraph) {
      for (var a = box.parent; a != null; a = a.parent) {
        if (_isScrollBoundary(a)) break;
        if (a is! RenderBox || !a.hasSize) continue;
        if (a.parent == null || a.parent is RenderView) break;
        final cs = a.constraints;
        if (!cs.hasTightHeight || a.size.height <= 0) continue;
        final r = MatrixUtils.transformRect(
          box.getTransformTo(a),
          Offset.zero & box.size,
        );
        final over = math.max(r.bottom - a.size.height, -r.top);
        if (over > tolerance) {
          // Only a problem when the ancestor does not clip it away
          // (clipped text is reported as inkClipped) or hide it.
          report.escapes.add(
            AuditFinding(
              'escapes',
              c.text,
              'line box ${r.height.toStringAsFixed(1)}px sticks out ${over.toStringAsFixed(1)}px of a ${a.size.height.toStringAsFixed(1)}px-tall ${a.runtimeType}',
              rect: rect,
              where: _where(a),
            ),
          );
          newMarks.add((rect, const Color(0xFFFF00FF)));
          break;
        }
        // Stop at the first tight ancestor that contains it.
        break;
      }
    }
  }
  marks.value = [...marks.value, ...newMarks];
}

Future<Rect?> _inkRect(
  WidgetTester t,
  RenderBox box,
  InlineSpan span,
  TextScaler scaler,
  int? maxLines,
  TextOverflow overflow,
  bool softWrap,
  ui.TextDirection dir,
  Locale? locale,
  StrutStyle? strut,
  TextWidthBasis basis,
  ui.TextHeightBehavior? thb,
  TextAlign align,
  Matrix4 xf,
) async {
  var hasPlaceholder = false;
  span.visitChildren((s) {
    if (s is PlaceholderSpan) hasPlaceholder = true;
    return true;
  });
  final constraintsMax = box.constraints.maxWidth;
  if (hasPlaceholder) {
    // Line-metric bounds (font ascent/descent) of the whole paragraph.
    return MatrixUtils.transformRect(xf, Offset.zero & box.size);
  }
  final painter = TextPainter(
    text: span,
    textDirection: dir,
    textScaler: scaler,
    maxLines: maxLines,
    ellipsis: overflow == TextOverflow.ellipsis ? '…' : null,
    locale: locale,
    strutStyle: strut,
    textWidthBasis: basis,
    textHeightBehavior: thb,
    textAlign: align,
  );
  if (softWrap) {
    painter.layout(
      maxWidth: constraintsMax.isFinite ? constraintsMax : box.size.width,
    );
  } else {
    painter.layout();
  }
  _t('ink ${span.toPlainText()}');
  const ratio = 2.0;
  final margin =
      (painter.height + painter.width.clamp(0, 400)) * 0 +
      4 * painter.preferredLineHeight;
  final w = painter.width + 2 * margin;
  final h = painter.height + 2 * margin;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(ratio);
  painter.paint(canvas, Offset(margin, margin));
  final picture = recorder.endRecording();
  final ui.Image? image = await t.runAsync(
    () => picture.toImage((w * ratio).ceil(), (h * ratio).ceil()),
  );
  picture.dispose();
  if (image == null) return null;
  final data = await t.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  final iw = image.width, ih = image.height;
  image.dispose();
  painter.dispose();
  if (data == null) return null;
  var top = ih, bottom = -1, left = iw, right = -1;
  final bytes = data.buffer.asUint8List();
  for (var y = 0; y < ih; y++) {
    for (var x = 0; x < iw; x++) {
      if (bytes[(y * iw + x) * 4 + 3] > 24) {
        if (y < top) top = y;
        if (y > bottom) bottom = y;
        if (x < left) left = x;
        if (x > right) right = x;
      }
    }
  }
  if (bottom < 0) return null;
  // Ink bbox in paragraph-local logical px (origin = paragraph top-left).
  final local = Rect.fromLTRB(
    left / ratio - margin,
    top / ratio - margin,
    (right + 1) / ratio - margin,
    (bottom + 1) / ratio - margin,
  );
  // The paragraph itself is positioned by its parent; x offset is irrelevant
  // for vertical checks, and horizontal alignment inside the box is replicated
  // by the replica's own alignment within `painter.width`.
  return MatrixUtils.transformRect(xf, local);
}

/// Pumps [build] under [mode] and returns the report.
///
/// [truncationBaseline] collects/uses the per-paragraph "exceeds maxLines" map
/// of the 1.0x run; pass the same map for all modes of one surface, 1.0x first.
Future<AuditReport> auditSurface(
  WidgetTester t, {
  required String surface,
  required Widget Function() build,
  required ThemeData theme,
  required AuditMode mode,
  Size size = const Size(390, 844),
  double devicePixelRatio = 1,
  required Map<String, bool> truncationBaseline,
  String? screenshotDir,
  TargetPlatform? platform,
  Duration settle = const Duration(milliseconds: 600),

  /// Interaction that opens the state under audit (runs after the first settle).
  Future<void> Function(WidgetTester t)? after,
}) async {
  final report = AuditReport(surface, mode);
  _t('start $surface ${mode.name}');
  // Reset in a tear-down: the root layer a reset creates must not be owned by
  // the test body, or leak tracking reports it as never disposed.
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  t.view.physicalSize = size * devicePixelRatio;
  t.view.devicePixelRatio = devicePixelRatio;
  t.platformDispatcher.textScaleFactorTestValue = mode.textScale;
  final marks = ValueNotifier<List<(Rect, Color)>>(const []);
  final capture = GlobalKey();
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = errors.add;
  try {
    // Fresh render objects: RenderFlex reports an overflow once per object.
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: platform == null ? theme : theme.copyWith(platform: platform),
        locale: mode.locale,
        supportedLocales: [mode.locale ?? const Locale('en')],
        localizationsDelegates: _delegates,
        builder: (context, child) => RaftTextScaling(
          child: RepaintBoundary(
            key: capture,
            child: Stack(
              fit: StackFit.expand,
              children: [
                child!,
                IgnorePointer(
                  child: CustomPaint(foregroundPainter: _Marks(marks)),
                ),
              ],
            ),
          ),
        ),
        home: Scaffold(body: build()),
      ),
    );
    await t.pump();
    await t.pump(settle);
    if (after != null) await after(t);
    await t.pump(const Duration(milliseconds: 50));
  } catch (e) {
    // A throw while pumping is a finding of the surface, not a harness error.
    report.errors.add(
      AuditFinding('error', 'thrown: ${'$e'.split('\n').first}', ''),
    );
  }
  try {
    await inspectPumped(
      t,
      report,
      truncatedBase: truncationBaseline,
      marks: marks,
    );
    await t.pump();
  } catch (e) {
    report.errors.add(
      AuditFinding('error', 'thrown: ${'$e'.split('\n').first}', ''),
    );
  }
  FlutterError.onError = previous;
  _t(
    'pumped, ${errors.length} errors, view ${t.view.physicalSize} scale ${t.platformDispatcher.textScaleFactor}',
  );
  for (final e in errors) {
    _t(e.exceptionAsString().split('\n').first);
  }
  for (final e in errors) {
    final msg = e.exceptionAsString();
    final first = msg.split('\n').first;
    if (msg.contains('overflowed by')) {
      final where = e.informationCollector == null
          ? ''
          : (e.informationCollector!()
                .map((n) => n.toString())
                .join(' ')
                .replaceAll('\n', ' '));
      report.overflow.add(
        AuditFinding(
          'overflow',
          first,
          where.length > 240 ? where.substring(0, 240) : where,
        ),
      );
    } else if (first.startsWith("Warning: This application's locale")) {
      // The harness app has no Cupertino localizations for zh; not a finding.
    } else {
      report.errors.add(AuditFinding('error', first, e.library ?? ''));
    }
  }
  _t('inspected ${report.paragraphs} paragraphs');
  if (screenshotDir != null) {
    final slug = surface.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '-');
    final boundary =
        capture.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    await t.runAsync(() async {
      await Directory(screenshotDir).create(recursive: true);
      if (boundary != null) {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (bytes != null) {
          await File(
            '$screenshotDir/$slug.${mode.name}${report.ok ? '' : '.FAIL'}.png',
          ).writeAsBytes(bytes.buffer.asUint8List());
        }
      }
      await File('$screenshotDir/$slug.${mode.name}.json').writeAsString(
        const JsonEncoder.withIndent(' ').convert(report.toJson()),
      );
    });
  }
  t.platformDispatcher.clearTextScaleFactorTestValue();
  // Unmount first so the painter drops its listener, then free the notifier.
  await t.pumpWidget(const SizedBox());
  marks.dispose();
  return report;
}

/// One line per (surface, mode) for a summary table.
String summaryLine(AuditReport r) =>
    '${r.surface}\t${r.mode.name}\t${r.ok ? 'pass' : 'FAIL'}\t'
    'paragraphs=${r.paragraphs}\toverflow=${r.overflow.length}\t'
    'inkClipped=${r.inkClipped.length}\tescapes=${r.escapes.length}\t'
    'hardCut=${r.hardCut.length}\ttruncated=${r.truncated.length}';
