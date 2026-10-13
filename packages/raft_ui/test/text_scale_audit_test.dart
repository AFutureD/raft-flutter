// Text-scale audit with the bundled design fonts (Noto Sans CJK as the CJK
// fallback): every representative surface at 1.0x, 1.3x and 2.0x, plus the
// Chinese UI locale at 1.0x. See text_scale_audit_runner.dart.
import 'package:flutter/material.dart';

import '../../../tool/testing/text_scale_audit.dart';
import 'text_scale_audit_runner.dart';

void main() {
  expectSurfaceListComplete();
  defineSurfaceAudits(
    AuditFonts.real,
    modes: const [
      AuditMode.base,
      AuditMode.x13,
      AuditMode.x2,
      AuditMode('zh-1.0x', locale: Locale('zh', 'CN')),
    ],
  );
}
