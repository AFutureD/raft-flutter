// Web auth/onboarding page pieces (packages/web/src/components/brand/
// AuthBrandShell.tsx, components/auth/*). Presentation only: the app owns
// state, validation and requests and passes fields/callbacks in.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'banner.dart';
import 'brand.dart';
import 'components.dart';
import 'css_pixel_snap.dart';
import 'design_primitives.dart';
import 'icons.dart';
import 'localization.dart';
import 'onboarding_previews.dart';
import 'recipes/button_variants.g.dart';
import 'recipes/checkbox.g.dart';
import 'recipes/field.g.dart' as field_recipe;
import 'recipes/recipe_runtime.dart';
import 'recipes/token_binding.dart';
import 'theme.dart' hide RaftFieldRecipe;
import 'tokens/tokens.dart';
import 'recipe_surface.dart' show RaftCssBoxDecoration;

/// RaftAuthShell (packages/web/src/components/brand/RaftAuthShell.tsx):
/// `bg-layer-canvas font-display safe-top safe-bottom`, brand top bar, then
/// `flex min-h-0 flex-1 items-center justify-center px-5 pb-10 pt-10`, content
/// `w-full max-w-md`. With a bounded height the stack is `min-h-full` (content
/// centred); in an unbounded host it shrink-wraps like CSS `min-h-full` of an
/// auto-height parent.
class RaftAuthShell extends StatelessWidget {
  const RaftAuthShell({
    super.key,
    required this.child,
    this.server,
    this.onServer,
    this.padding,
    this.formPanel = false,
    this.overlayLink,
  });

  /// OnboardingCreateShell's narrow form panel: `px-6 py-10 sm:px-10`.
  final bool formPanel;
  final Widget child;

  /// Native-only affordance pinned over the bottom of the page without taking
  /// part in the layout, so the centred Web composition keeps its geometry.
  final Widget? overlayLink;
  final String? server;
  final VoidCallback? onServer;

  /// `px-5 pb-10 pt-10 sm:px-8 sm:pb-14 sm:pt-14` (AUTH_BRAND_CONTENT_CLASS,
  /// the default); OnboardingCreateShell's form panel is `px-6 py-10
  /// sm:px-10`.
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final safe = MediaQuery.paddingOf(context);
    final wide = MediaQuery.sizeOf(context).width >= 640; // Tailwind `sm`
    final content = Padding(
      padding:
          padding ??
          (formPanel
              ? EdgeInsets.symmetric(horizontal: wide ? 40 : 24, vertical: 40)
              : wide
              ? const EdgeInsets.fromLTRB(32, 56, 32, 56)
              : const EdgeInsets.fromLTRB(20, 40, 20, 40)),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 448), // max-w-md
          child: child,
        ),
      ),
    );
    final page = Material(
      color: t.canvas,
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontFamily: t.headingFont,
          color: t.semantic.foreground,
        ),
        child: Padding(
          // `safe-top`; `safe-bottom` = inset + 1rem (index.css .safe-bottom).
          padding: EdgeInsets.only(top: safe.top, bottom: safe.bottom + 16),
          child: LayoutBuilder(
            builder: (context, box) {
              final bar = RaftAuthTopBar(server: server, onServer: onServer);
              if (!box.hasBoundedHeight) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [bar, content],
                );
              }
              const barHeight = RaftAuthTopBar.height;
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    bar,
                    // `flex-1 items-center justify-center` under `min-h-full`.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: (box.maxHeight - barHeight).clamp(
                          0.0,
                          double.infinity,
                        ),
                      ),
                      child: Align(child: content),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    if (overlayLink == null) return page;
    return Stack(
      children: [
        Positioned.fill(child: page),
        Positioned(
          left: 0,
          right: 0,
          bottom: safe.bottom + 24,
          child: Center(child: overlayLink),
        ),
      ],
    );
  }
}

/// AUTH_BRAND_TOP_BAR_CLASS: `h-panel-header border-b border-line-hairline
/// bg-layer-panel px-4 theme-brutal:border-b-2 theme-brutal:border-black
/// theme-brutal:bg-soft-signal`, RaftBrandLockup `h-5 w-auto`.
class RaftAuthTopBar extends StatelessWidget {
  const RaftAuthTopBar({super.key, this.server, this.onServer});

  /// Native-only server origin control; null hides it (onboarding pages).
  final String? server;
  final VoidCallback? onServer;

  /// `h-panel-header` outside the app shell: `--shell-header-height` is only
  /// set on `[data-slot="app-shell-root"]`, so the auth pages fall back to
  /// 62px in every theme (border-box).
  static const double height = 62;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    return Container(
      height: height,
      // `px-4 sm:px-6 md:px-8`.
      padding: EdgeInsets.symmetric(
        horizontal: width >= 768 ? 32 : (width >= 640 ? 24 : 16),
      ),
      decoration: BoxDecoration(
        color: t.brutal ? t.product.softSignal : t.panel,
        border: Border(
          bottom: t.brutal
              ? const BorderSide(color: Color(0xFF000000), width: 2)
              : BorderSide(color: t.semantic.lineHairline),
        ),
      ),
      child: Row(
        children: [
          const RaftBrandMark(RaftBrandMarkKind.logo, height: 20),
          const Spacer(),
          // Native-only server origin control (see _AuthState.editServer).
          if (server != null)
            Semantics(
              button: true,
              label: raftText(context, 'Server URL'),
              child: RaftAuthTextLink(
                key: const Key('login-server'),
                label: server!,
                onTap: onServer,
                small: true,
              ),
            ),
        ],
      ),
    );
  }
}

/// AuthBrandIntro: `mb-5 text-center`; icon `mx-auto mb-4 size-9`; h1
/// `text-xl font-bold`; description `mt-2 text-sm text-foreground-muted`.
class RaftAuthIntro extends StatelessWidget {
  const RaftAuthIntro({
    super.key,
    required this.title,
    this.description,
    this.descriptionSpan,
    this.children = const [],
  });
  final String title;
  final String? description;

  /// Rich description (`<strong>` runs); wins over [description].
  final InlineSpan? descriptionSpan;

  /// AuthBrandIntro `children`: rendered after the description.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final descriptionStyle = RaftTypography.heading(
      t,
      size: 14,
      line: 20,
      weight: FontWeight.w400,
    ).copyWith(color: t.muted);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        children: [
          RaftBrandMark(
            RaftBrandMarkKind.icon,
            height: 36,
            width: 36,
            invert: t.dark,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: RaftTypography.heading(
              t,
              size: 20,
              line: 28,
            ).copyWith(color: t.semantic.foreground),
          ),
          if (descriptionSpan != null) ...[
            const SizedBox(height: 8),
            Text.rich(
              descriptionSpan!,
              textAlign: TextAlign.center,
              style: descriptionStyle,
            ),
          ] else if (description != null) ...[
            const SizedBox(height: 8),
            Text(
              description!,
              textAlign: TextAlign.center,
              style: descriptionStyle,
            ),
          ],
          ...children,
        ],
      ),
    );
  }
}

/// FormField labelStyle="plain" over raft-ui Field: label `mb-1 block text-sm`
/// (field label recipe: 14/20, 700 brutal / 500 elegant, foreground), Field
/// `gap-1` before the control.
class RaftAuthField extends StatelessWidget {
  const RaftAuthField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.helperHint = false,
    this.helperRecipe = false,
    this.error,
    this.surface = true,
  });
  final String label;
  final Widget child;

  /// Helper `<p className="mt-1 text-xs …">` rendered after the control;
  /// muted, or `text-foreground-hint` when [helperHint].
  final String? helper;
  final bool helperHint;

  /// `FormField hint`: the raft-ui `FieldDescription` recipe text (no `text-xs`
  /// override), e.g. the ServerSelector first-server form.
  final bool helperRecipe;

  /// FieldError `mt-1` (field recipe error slot).
  final String? error;

  /// Wrap [child] in the shared field frame (false when the child draws its
  /// own frame, e.g. an input group).
  final bool surface;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final tokens = RaftRecipeTokens(t);
    final style = field_recipe.RaftFieldRecipe.resolve(
      theme: t.brutal ? RaftRecipeTheme.brutal : RaftRecipeTheme.elegant,
      tokens: tokens,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: style.label.textStyle(tokens)),
        SizedBox(height: 4 + (style.root.rowGap ?? 0)),
        surface ? RaftFieldSurface(child: child) : child,
        // Field `gap` separates every direct child of the field.
        if (helper != null) ...[
          SizedBox(height: (style.root.rowGap ?? 0) + 4), // gap-1 + mt-1
          Text(
            helper!,
            style: helperRecipe
                ? style.description.textStyle(tokens)
                : _helper(t, helperHint ? t.semantic.foregroundHint : t.muted),
          ),
        ],
        if (error != null) ...[
          SizedBox(height: (style.root.rowGap ?? 0) + 4),
          Semantics(
            liveRegion: true,
            child: Text(error!, style: style.error.textStyle(tokens)),
          ),
        ],
      ],
    );
  }
}

/// `<Button type="submit" size="lg" variant="accent" className="w-full">`.
class RaftAuthSubmit extends StatelessWidget {
  const RaftAuthSubmit({super.key, required this.label, this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => RaftAuthWideButton(
    onPressed: onPressed,
    variant: RaftControlVariant.accent,
    label: label,
  );
}

/// `size="lg" className="w-full"` raft-ui Button. The layout box is the CSS
/// box (lg height), as on Web; the loading state is the disabled label
/// ("Signing in…"), not a spinner.
class RaftAuthWideButton extends StatelessWidget {
  const RaftAuthWideButton({
    super.key,
    required this.label,
    required this.variant,
    this.onPressed,
    this.leading,
    this.gap,
  });
  final String label;
  final RaftControlVariant variant;
  final VoidCallback? onPressed;
  final Widget? leading;
  final double? gap;

  @override
  Widget build(BuildContext context) => RaftButton(
    label: label,
    variant: variant,
    size: RaftButtonRecipeSize.lg,
    expand: true,
    onPressed: onPressed,
    leading: leading,
    gap: gap,
  );
}

/// `my-4 flex items-center gap-3`; rules `h-0.5 flex-1 bg-line-strong
/// theme-brutal:bg-black`; label `text-xs font-bold uppercase tracking-widest
/// text-foreground-muted theme-brutal:text-black/45`.
class RaftAuthOrDivider extends StatelessWidget {
  const RaftAuthOrDivider({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final rule = Expanded(
      child: Container(
        height: 2,
        color: t.brutal ? const Color(0xFF000000) : t.semantic.lineStrong,
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          rule,
          const SizedBox(width: 12),
          Text(
            label.toUpperCase(),
            style: RaftTypography.heading(t, size: 12, line: 16).copyWith(
              letterSpacing: 12 * .1,
              color: t.brutal ? const Color(0x73000000) : t.muted,
            ),
          ),
          const SizedBox(width: 12),
          rule,
        ],
      ),
    );
  }
}

/// SocialProviderButton: `<Button variant="outline" size="lg" className="w-full
/// gap-3">` with the provider logo (`size-5`) and "Continue with {provider}".
class RaftAuthSocialButton extends StatelessWidget {
  const RaftAuthSocialButton({
    super.key,
    required this.provider,
    required this.label,
    this.onPressed,
  });
  final String provider, label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final mark = switch (provider) {
      'google' => RaftBrandMarkKind.google,
      'github' => RaftBrandMarkKind.github,
      _ => RaftBrandMarkKind.apple,
    };
    return RaftAuthWideButton(
      onPressed: onPressed,
      variant: RaftControlVariant.outline,
      label: label,
      gap: 12, // gap-3
      leading: RaftBrandMark(
        mark,
        height: 20,
        width: 20,
        invert: t.dark && mark != RaftBrandMarkKind.google,
      ),
    );
  }
}

/// LegalAcceptanceCheckbox: `flex items-start gap-2.5 text-sm`, Checkbox
/// size md `mt-0.5`, copy `leading-5 text-foreground-muted`, links `font-bold
/// text-foreground-strong underline`.
class RaftAuthLegalCheckbox extends StatefulWidget {
  const RaftAuthLegalCheckbox({
    super.key,
    required this.checked,
    required this.onChanged,
    required this.onTerms,
    required this.onPrivacy,
  });
  final bool checked;
  final ValueChanged<bool>? onChanged;
  final VoidCallback onTerms, onPrivacy;
  @override
  State<RaftAuthLegalCheckbox> createState() => _RaftAuthLegalCheckboxState();
}

class _RaftAuthLegalCheckboxState extends State<RaftAuthLegalCheckbox> {
  late final terms = TapGestureRecognizer()..onTap = widget.onTerms;
  late final privacy = TapGestureRecognizer()..onTap = widget.onPrivacy;

  @override
  void dispose() {
    terms.dispose();
    privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    String tr(String s) => raftText(context, s);
    final base = RaftTypography.heading(
      t,
      size: 14,
      line: 20,
      weight: FontWeight.w400,
    ).copyWith(color: t.muted);
    final link = base.copyWith(
      fontWeight: FontWeight.w700,
      color: t.strong,
      decoration: TextDecoration.underline,
    );
    final size = RaftCheckboxRecipe.resolve(
      theme: t.brutal ? RaftRecipeTheme.brutal : RaftRecipeTheme.elegant,
      size: RaftCheckboxRecipeSize.md,
    ).root.width!;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2), // mt-0.5
          child: SizedBox.square(
            dimension: size,
            child: Checkbox(
              key: const Key('register-legal'),
              value: widget.checked,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              onChanged: widget.onChanged == null
                  ? null
                  : (v) => widget.onChanged!(v == true),
            ),
          ),
        ),
        const SizedBox(width: 10), // gap-2.5
        Expanded(
          child: Text.rich(
            TextSpan(
              style: base,
              children: [
                TextSpan(text: '${tr('I agree to the')} '),
                TextSpan(
                  text: tr('Terms of Service'),
                  style: link,
                  recognizer: terms,
                ),
                TextSpan(text: ' ${tr('and acknowledge the')} '),
                TextSpan(
                  text: tr('Privacy Policy'),
                  style: link,
                  recognizer: privacy,
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// pages.login.legalAgreement: `mt-4 text-center text-xs leading-5
/// text-foreground-muted theme-brutal:text-black/60`, links `underline`.
class RaftAuthLegalNotice extends StatefulWidget {
  const RaftAuthLegalNotice({
    super.key,
    required this.onTerms,
    required this.onPrivacy,
  });
  final VoidCallback onTerms, onPrivacy;
  @override
  State<RaftAuthLegalNotice> createState() => _RaftAuthLegalNoticeState();
}

class _RaftAuthLegalNoticeState extends State<RaftAuthLegalNotice> {
  late final terms = TapGestureRecognizer()..onTap = widget.onTerms;
  late final privacy = TapGestureRecognizer()..onTap = widget.onPrivacy;

  @override
  void dispose() {
    terms.dispose();
    privacy.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    String tr(String s) => raftText(context, s);
    final base = RaftTypography.heading(
      t,
      size: 12,
      line: 20,
      weight: FontWeight.w400,
    ).copyWith(color: t.brutal ? const Color(0x99000000) : t.muted);
    final link = base.copyWith(decoration: TextDecoration.underline);
    return Text.rich(
      textAlign: TextAlign.center,
      TextSpan(
        style: base,
        children: [
          TextSpan(text: '${tr('By continuing, you agree to the')} '),
          TextSpan(
            text: tr('Terms of Service'),
            style: link,
            recognizer: terms,
          ),
          TextSpan(text: ' ${tr('and')} '),
          TextSpan(
            text: tr('Privacy Policy'),
            style: link,
            recognizer: privacy,
          ),
          const TextSpan(text: '.'),
        ],
      ),
    );
  }
}

/// TextLink (packages/web/src/components/ui/TextLink.tsx): `muted` =
/// `text-foreground-muted underline`, `primary` = `font-bold text-accent-strong
/// underline theme-brutal:text-brutal-pink`; `disabled:opacity-50`. Used in
/// `text-sm` paragraphs.
class RaftAuthTextLink extends StatelessWidget {
  const RaftAuthTextLink({
    super.key,
    required this.label,
    this.onTap,
    this.small = false,
    this.primary = false,
    this.bold = false,
    this.centeredLine = false,
  });
  final String label;

  /// `<div className="text-center"><button …>` in a `text-base` block: the
  /// link is centred in a 24px line box.
  final bool centeredLine;
  final VoidCallback? onTap;
  final bool small;

  /// Muted link with `font-bold` (ServerSelector "Log out": `text-sm
  /// font-bold` over the muted variant).
  final bool bold;

  /// `font-bold text-accent-strong underline theme-brutal:text-brutal-pink`.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final link = Opacity(
      opacity: onTap == null ? .5 : 1,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Text(
          label,
          style: _linkStyle(
            t,
            primary: primary,
            bold: bold,
            size: small ? 12 : 14,
          ),
        ),
      ),
    );
    if (!centeredLine) return link;
    return SizedBox(height: 24, child: Center(child: link));
  }
}

TextStyle _linkStyle(
  RaftTokens t, {
  bool primary = false,
  bool bold = false,
  double size = 14,
}) =>
    RaftTypography.heading(
      t,
      size: size,
      line: size == 14 ? 20 : 16,
      weight: primary || bold ? FontWeight.w700 : FontWeight.w400,
    ).copyWith(
      color: primary
          ? (t.brutal ? t.product.brutalPink : t.semantic.accentStrong)
          : t.muted,
      decoration: TextDecoration.underline,
      decorationColor: primary
          ? (t.brutal ? t.product.brutalPink : t.semantic.accentStrong)
          : t.muted,
    );

/// `<p className="mt-4 text-center text-sm">` prompt + primary TextLink.
class RaftAuthPrompt extends StatefulWidget {
  const RaftAuthPrompt({
    super.key,
    required this.prefix,
    required this.link,
    this.onTap,
  });
  final String prefix, link;
  final VoidCallback? onTap;
  @override
  State<RaftAuthPrompt> createState() => _RaftAuthPromptState();
}

class _RaftAuthPromptState extends State<RaftAuthPrompt> {
  final tap = TapGestureRecognizer();

  @override
  void dispose() {
    tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    tap.onTap = widget.onTap;
    return Text.rich(
      textAlign: TextAlign.center,
      TextSpan(
        style: RaftTypography.heading(
          t,
          size: 14,
          line: 20,
          weight: FontWeight.w400,
        ).copyWith(color: t.semantic.foreground),
        children: [
          TextSpan(text: '${widget.prefix} '),
          TextSpan(
            text: widget.link,
            style: _linkStyle(t, primary: true),
            recognizer: tap,
          ),
        ],
      ),
    );
  }
}

/// `<Banner intent="warning" className="mb-4 font-bold">` (raft-ui banner).
class RaftAuthBanner extends StatelessWidget {
  const RaftAuthBanner({
    super.key,
    required this.text,
    this.info = false,
    this.success = false,
  });
  final String text;
  final bool info, success;

  @override
  Widget build(BuildContext context) => RaftBanner(
    description: text,
    status: success
        ? RaftBannerRecipeStatus.success
        : info
        ? RaftBannerRecipeStatus.info
        : RaftBannerRecipeStatus.warning,
  );
}

List<Widget> _gap16(List<Widget> children) => [
  for (final (i, child) in children.indexed) ...[
    if (i > 0) const SizedBox(height: 16),
    child,
  ],
];

/// `mt-1 text-xs` helper paragraph.
TextStyle _helper(RaftTokens t, Color color) => RaftTypography.heading(
  t,
  size: 12,
  line: 16,
  weight: FontWeight.w400,
).copyWith(color: color);

/// AccountIdentitySetupPage username group: `flex items-stretch
/// overflow-hidden rounded-md border border-line-field bg-layer-panel
/// theme-brutal:rounded-none theme-brutal:border-2 theme-brutal:border-black
/// theme-brutal:bg-white theme-brutal:shadow-brutal-sm`, "@" addon `border-r
/// border-line-hairline bg-soft-signal px-3 font-mono text-base font-bold
/// text-foreground-muted theme-brutal:border-r-2 theme-brutal:border-black
/// theme-brutal:text-black/60`.
class RaftAuthHandleGroup extends StatelessWidget {
  const RaftAuthHandleGroup({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    final border = t.brutal
        ? const BorderSide(color: Color(0xFF000000), width: 2)
        : BorderSide(color: t.semantic.lineField);
    return Container(
      decoration: BoxDecoration(
        color: t.brutal ? const Color(0xFFFFFFFF) : t.panel,
        border: Border.fromBorderSide(border),
        borderRadius: t.brutal ? null : BorderRadius.circular(6),
        boxShadow: t.brutal ? RaftProductShadows.shadowBrutalSm.outer : null,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: t.product.softSignal,
                border: Border(
                  right: t.brutal
                      ? border
                      : BorderSide(color: t.semantic.lineHairline),
                ),
              ),
              child: Text(
                '@',
                style: RaftTypography.mono(
                  t,
                  size: 16,
                  line: 24,
                  color: t.brutal ? const Color(0x99000000) : t.muted,
                ).copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

/// "Profile picture" block: label `mb-1 text-sm font-bold
/// text-foreground-strong`; `flex items-center gap-3` with the 56px avatar
/// tile (`theme-brutal:shadow-brutal-sm`) and an sm outline "Upload" button
/// (Camera 15, `gap-1.5`) over `mt-1 text-xs text-foreground-hint` helper.
class RaftAuthAvatarField extends StatelessWidget {
  const RaftAuthAvatarField({
    super.key,
    required this.name,
    this.imageUrl,
    required this.onUpload,
  });
  final String name;
  final String? imageUrl;
  final VoidCallback? onUpload;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    String tr(String s) => raftText(context, s);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('Profile picture'),
          style: RaftTypography.heading(t, size: 14, line: 20),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            DecoratedBox(
              decoration: RaftCssBoxDecoration(
                boxShadow: t.brutal
                    ? RaftProductShadows.shadowBrutalSm.outer
                    : null,
              ),
              child: RaftAvatar(name: name, size: 56, imageUrl: imageUrl),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  RaftTextButton(
                    label: tr('Upload'),
                    // AccountIdentitySetupPage: <Camera size={15} />.
                    glyph: RaftGlyph.camera,
                    visualHeight: RaftMetrics.buttonSm,
                    minimumTargetSize: RaftMetrics.buttonSm,
                    onPressed: onUpload,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('A default is picked for you.'),
                    style: _helper(t, t.semantic.foregroundHint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// OnboardingSessionFooter: `text-center text-sm text-foreground-muted`,
/// "Signed in as {name}. " + muted TextLink "Log out".
class RaftAuthSessionFooter extends StatelessWidget {
  const RaftAuthSessionFooter({super.key, required this.name, this.onSignOut});
  final String name;
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Wrap(
      alignment: WrapAlignment.center,
      children: [
        Text(
          '${raftText(context, 'Signed in as')} $name. ',
          style: RaftTypography.heading(
            t,
            size: 14,
            line: 20,
            weight: FontWeight.w400,
          ).copyWith(color: t.muted),
        ),
        RaftAuthTextLink(label: raftText(context, 'Log out'), onTap: onSignOut),
      ],
    );
  }
}

/// Signed-out page modes (LoginPage, RegisterPage, ForgotPasswordPage,
/// ResetPasswordPage).
enum RaftAuthMode { login, register, forgot, reset }

/// One enabled social provider (`/auth/providers`).
@immutable
class RaftAuthProviderEntry {
  const RaftAuthProviderEntry(this.id, this.label);
  final String id, label;
}

/// The Web sign-in/register/forgot/reset page composition inside
/// [RaftAuthShell]. Fields are passed in so the app keeps controllers; the
/// per-field `*Error` strings are the FormField error slot under each control.
class RaftAuthPage extends StatelessWidget {
  const RaftAuthPage({
    super.key,
    required this.mode,
    required this.busy,
    this.emailField,
    this.tokenField,
    this.passwordField,
    this.confirmField,
    this.emailError,
    this.tokenError,
    this.passwordError,
    this.confirmError,
    this.banner,
    this.notice,
    this.accepted = false,
    this.onAccepted,
    this.onSubmit,
    this.submitKey,
    this.providers = const [],
    this.onProvider,
    this.onCancelBrowser,
    required this.onMode,
    required this.onTerms,
    required this.onPrivacy,
    this.server,
    this.onServer,
  });
  final RaftAuthMode mode;
  final bool busy, accepted;
  final Widget? emailField, tokenField, passwordField, confirmField;
  final String? emailError, tokenError, passwordError, confirmError;
  final String? banner, notice;
  final ValueChanged<bool>? onAccepted;
  final VoidCallback? onSubmit;
  final Key? submitKey;
  final List<RaftAuthProviderEntry> providers;
  final ValueChanged<String>? onProvider;
  final VoidCallback? onCancelBrowser;
  final ValueChanged<RaftAuthMode> onMode;
  final VoidCallback onTerms, onPrivacy;
  final String? server;
  final VoidCallback? onServer;

  // Web copy (en.ts pages.login/register/forgotPassword/resetPassword).
  String get _title => switch (mode) {
    RaftAuthMode.register => 'Create your account',
    RaftAuthMode.forgot => 'Reset Password',
    RaftAuthMode.reset => 'Set New Password',
    RaftAuthMode.login => 'Sign In',
  };
  String get _submit => switch (mode) {
    RaftAuthMode.register => busy ? 'Creating account…' : 'Continue',
    RaftAuthMode.forgot => busy ? 'Sending…' : 'Send Reset Link',
    RaftAuthMode.reset => busy ? 'Resetting…' : 'Reset Password',
    RaftAuthMode.login => busy ? 'Signing in…' : 'Sign In',
  };

  @override
  Widget build(BuildContext context) {
    String tr(String s) => raftText(context, s);
    final social = mode == RaftAuthMode.login || mode == RaftAuthMode.register;
    return RaftAuthShell(
      server: server,
      onServer: onServer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RaftAuthIntro(
            title: tr(_title),
            description: mode == RaftAuthMode.forgot
                ? tr(
                    "Enter your email and we'll send you a link to reset your password.",
                  )
                : null,
          ),
          if (banner != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16), // mb-4
              child: RaftAuthBanner(text: banner!),
            ),
          if (notice != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: RaftAuthBanner(text: tr(notice!), info: true),
            ),
          // <form className="space-y-4">
          if (emailField != null)
            RaftAuthField(
              label: tr('Email'),
              surface: false,
              error: emailError,
              child: emailField!,
            ),
          if (tokenField != null)
            RaftAuthField(
              label: tr('Password reset link or code'),
              surface: false,
              error: tokenError,
              child: tokenField!,
            ),
          if (passwordField != null) ...[
            if (emailField != null || tokenField != null)
              const SizedBox(height: 16),
            RaftAuthField(
              label: tr(
                mode == RaftAuthMode.reset ? 'New password' : 'Password',
              ),
              surface: false,
              error: passwordError,
              child: passwordField!,
            ),
          ],
          if (confirmField != null) ...[
            const SizedBox(height: 16),
            RaftAuthField(
              label: tr('Confirm password'),
              surface: false,
              error: confirmError,
              child: confirmField!,
            ),
          ],
          if (mode == RaftAuthMode.register) ...[
            const SizedBox(height: 16),
            RaftAuthLegalCheckbox(
              checked: accepted,
              onChanged: busy ? null : onAccepted,
              onTerms: onTerms,
              onPrivacy: onPrivacy,
            ),
          ],
          const SizedBox(height: 16),
          RaftAuthSubmit(
            key: submitKey,
            label: tr(_submit),
            onPressed: onSubmit,
          ),
          if (providers.isNotEmpty && social) ...[
            RaftAuthOrDivider(label: tr('or')),
            Column(
              key: const ValueKey('auth-social-buttons'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, provider) in providers.indexed) ...[
                  if (i > 0) const SizedBox(height: 8), // space-y-2
                  RaftAuthSocialButton(
                    key: ValueKey('auth-social-${provider.id}'),
                    provider: provider.id,
                    label: tr('Continue with ${provider.label}'),
                    // Web only disables the submit button while loading.
                    onPressed: onProvider == null
                        ? null
                        : () => onProvider!(provider.id),
                  ),
                ],
              ],
            ),
            if (onCancelBrowser != null) ...[
              const SizedBox(height: 8),
              Center(
                child: RaftAuthTextLink(
                  label: tr('Cancel browser sign-in'),
                  onTap: onCancelBrowser,
                ),
              ),
            ],
          ],
          if (mode == RaftAuthMode.login) ...[
            const SizedBox(height: 16), // mt-4
            RaftAuthLegalNotice(onTerms: onTerms, onPrivacy: onPrivacy),
            const SizedBox(height: 12), // mt-3
            Center(
              child: RaftAuthTextLink(
                label: tr('Forgot password?'),
                onTap: () => onMode(RaftAuthMode.forgot),
              ),
            ),
            const SizedBox(height: 8), // mt-2
            RaftAuthPrompt(
              prefix: tr('No account?'),
              link: tr('Create one'),
              onTap: () => onMode(RaftAuthMode.register),
            ),
          ] else if (mode == RaftAuthMode.register) ...[
            const SizedBox(height: 16), // mt-4
            RaftAuthPrompt(
              prefix: tr('Already have an account?'),
              link: tr('Sign in'),
              onTap: () => onMode(RaftAuthMode.login),
            ),
          ] else ...[
            // `<p className="mt-4 text-center text-sm"><button font-bold
            // underline accent>Back to sign in</button></p>`
            const SizedBox(height: 16),
            Center(
              child: RaftAuthTextLink(
                label: tr('Back to sign in'),
                primary: true,
                onTap: busy ? null : () => onMode(RaftAuthMode.login),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The result pages of the auth flow (forgot "Check your email", reset
/// "Password reset", email "Email verified"): [RaftAuthIntro] followed by one
/// full-width accent button, optionally led by an icon (`<ArrowLeft size=16/>`,
/// `gap-2`).
class RaftAuthResultPage extends StatelessWidget {
  const RaftAuthResultPage({
    super.key,
    required this.title,
    this.description,
    this.descriptionSpan,
    required this.buttonLabel,
    this.buttonIcon,
    this.onButton,
    this.gapBeforeButton = 0,
    this.below = const [],
    this.overlayLink,
    this.buttonKey,
  });
  final String title;
  final String? description;
  final InlineSpan? descriptionSpan;
  final String buttonLabel;
  final RaftGlyph? buttonIcon;
  final VoidCallback? onButton;

  /// `<div className="mb-6" />` between the intro and the button.
  final double gapBeforeButton;
  final List<Widget> below;

  /// See [RaftAuthShell.overlayLink].
  final Widget? overlayLink;
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) => RaftAuthShell(
    overlayLink: overlayLink,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RaftAuthIntro(
          title: title,
          description: description,
          descriptionSpan: descriptionSpan,
        ),
        if (gapBeforeButton > 0) SizedBox(height: gapBeforeButton),
        RaftButton(
          key: buttonKey,
          label: buttonLabel,
          glyph: buttonIcon,
          variant: RaftControlVariant.accent,
          size: RaftButtonRecipeSize.lg,
          expand: true,
          onPressed: onButton,
        ),
        ...below,
      ],
    ),
  );
}

/// EmailVerificationPage (CenteredCardFrame): "Check your email" intro with
/// the address, banners, then the `space-y-3` action column (Resend accent,
/// "Enter code manually" toggle, optional code form, outline Log out).
class RaftAuthVerifyPage extends StatelessWidget {
  const RaftAuthVerifyPage({
    super.key,
    required this.email,
    required this.resending,
    required this.verifying,
    required this.manualOpen,
    required this.tokenField,
    required this.canVerify,
    this.error,
    this.resent = false,
    this.onResend,
    this.onToggleManual,
    this.onVerify,
    this.onLogOut,
  });
  final String email;
  final bool resending, verifying, manualOpen, canVerify, resent;
  final Widget tokenField;
  final String? error;
  final VoidCallback? onResend, onToggleManual, onVerify, onLogOut;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    String tr(String s) => raftText(context, s);
    final muted14 = RaftTypography.heading(
      t,
      size: 14,
      line: 20,
      weight: FontWeight.w400,
    ).copyWith(color: t.muted);
    final mono14 = TextStyle(
      fontFamily: t.monoFont,
      fontSize: 14,
      height: 20 / 14,
      fontWeight: FontWeight.w700,
      color: t.semantic.foreground,
    );
    return RaftAuthShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RaftAuthIntro(
            title: tr('Check your email'),
            children: [
              const SizedBox(height: 8),
              Text(
                tr('We sent a verification link to'),
                textAlign: TextAlign.center,
                style: muted14,
              ),
              const SizedBox(height: 4),
              Text(email, textAlign: TextAlign.center, style: mono14),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: RaftAuthBanner(text: error!),
            ),
          if (resent)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: RaftAuthBanner(
                text: tr('Verification email resent! Check your inbox.'),
                success: true,
              ),
            ),
          if (verifying)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                tr('Verifying...'),
                textAlign: TextAlign.center,
                style: muted14,
              ),
            ),
          RaftButton(
            key: const Key('verify-resend'),
            label: resending ? tr('Sending…') : tr('Resend Verification Email'),
            glyph: RaftGlyph.refreshCw,
            variant: RaftControlVariant.accent,
            size: RaftButtonRecipeSize.lg,
            expand: true,
            onPressed: resending ? null : onResend,
          ),
          const SizedBox(height: 12), // space-y-3
          // `<div className="text-center"><button …>`: the inline button sits
          // in a 24px line (the block's `text-base` strut).
          SizedBox(
            height: 24,
            child: Center(
              child: GestureDetector(
                key: const Key('verify-manual-toggle'),
                onTap: onToggleManual,
                behavior: HitTestBehavior.opaque,
                child: Text.rich(
                  TextSpan(
                    style: _linkStyle(t),
                    children: [
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: RaftIcon(
                            RaftGlyph.keyRound,
                            size: 12,
                            color: t.muted,
                          ),
                        ),
                      ),
                      TextSpan(
                        text: manualOpen
                            ? tr('Hide manual entry')
                            : tr('Enter code manually'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (manualOpen) ...[
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: tokenField),
                const SizedBox(width: 8), // gap-2
                RaftButton(
                  key: const Key('verify-submit'),
                  label: verifying ? '…' : tr('Verify'),
                  tone: RaftButtonRecipeVariant.success,
                  size: RaftButtonRecipeSize.sm,
                  onPressed: verifying || !canVerify ? null : onVerify,
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          RaftButton(
            key: const Key('verify-logout'),
            label: tr('Log out'),
            glyph: RaftGlyph.logOut,
            variant: RaftControlVariant.outline,
            size: RaftButtonRecipeSize.lg,
            expand: true,
            onPressed: onLogOut,
          ),
        ],
      ),
    );
  }
}

/// ServerSelector first-server heading: `font-mono text-[10px] font-bold
/// uppercase tracking-[0.14em]` eyebrow, `mt-2 text-2xl font-bold
/// leading-tight` title, `mt-2 text-sm leading-5` description (brutal uses the
/// `black/50` and `black/65` text colours).
class RaftOnboardingHeading extends StatelessWidget {
  const RaftOnboardingHeading({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.description,
  });
  final String eyebrow, title, description;

  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          eyebrow.toUpperCase(),
          style: TextStyle(
            fontFamily: t.monoFont,
            fontSize: 10,
            height: 1.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 10 * .14,
            color: t.brutal ? const Color(0x80000000) : t.muted,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: RaftTypography.heading(t, size: 24, line: 30).copyWith(
            color: t.brutal ? Colors.black : t.strong,
            leadingDistribution: TextLeadingDistribution.even,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style:
              RaftTypography.heading(
                t,
                size: 14,
                line: 20,
                weight: FontWeight.w400,
              ).copyWith(
                color: t.brutal ? const Color(0xA6000000) : t.muted,
                leadingDistribution: TextLeadingDistribution.even,
              ),
        ),
      ],
    );
  }
}

/// OnboardingCreateShell: below the `lg` breakpoint (1024) the narrow layout (brand bar, form panel
/// `px-6 py-10` in [RaftAuthShell]); from `lg` up a `[minmax(320px,2fr) 3fr]` grid with the form panel
/// (brand mark top-left, `border-r-2` in Brutal, content `max-w-md` centred) beside the dot pane holding
/// [preview]. Without a [preview] it is always the narrow layout.
class RaftOnboardingShell extends StatelessWidget {
  const RaftOnboardingShell({
    super.key,
    required this.child,
    this.preview,
    this.narrowPadding,
  });
  final Widget child;
  final Widget? preview;

  /// Padding of the narrow form panel (null: [RaftAuthShell]'s `formPanel` default).
  final EdgeInsets? narrowPadding;

  /// Tailwind `lg`.
  static const breakpoint = 1024.0;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= breakpoint;
    if (preview == null || !wide) {
      return RaftAuthShell(
        padding: narrowPadding,
        formPanel: narrowPadding == null,
        child: child,
      );
    }
    final t = RaftTokens.of(context);
    final safe = MediaQuery.paddingOf(context);
    const brutalBorder = BorderSide(color: Color(0xFF000000), width: 2);
    final divider = t.brutal
        ? brutalBorder
        : BorderSide(color: t.semantic.lineHairline);
    return Material(
      color: t.canvas,
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontFamily: t.headingFont,
          color: t.semantic.foreground,
        ),
        child: Padding(
          // `safe-top`; `safe-bottom` = inset + 1rem.
          padding: EdgeInsets.only(top: safe.top, bottom: safe.bottom + 16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 2,
                // Container (not DecoratedBox): the border-box `border-r` narrows the content box.
                child: Container(
                  decoration: BoxDecoration(
                    color: t.canvas,
                    border: Border(right: divider),
                  ),
                  child: Stack(
                    children: [
                      LayoutBuilder(
                        builder: (context, box) => SingleChildScrollView(
                          padding: const EdgeInsets.all(40),
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              minHeight: math.max(0, box.maxHeight - 80),
                            ),
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 448,
                                ),
                                // The centred column lands on a half pixel (`justify-center`); Blink
                                // snaps its box edges when painting.
                                child: RaftCssPixelSnap(child: child),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Positioned(
                        left: 40,
                        top: 32,
                        child: RaftBrandMark(
                          RaftBrandMarkKind.logo,
                          height: 20,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(flex: 3, child: RaftOnboardingDotPane(child: preview!)),
            ],
          ),
        ),
      ),
    );
  }
}

/// OnboardingCreateShell form column: `AuthPageIntro`, banners and the form rows in a `max-w-md flex-col
/// gap-4` column, optional session footer (see [RaftOnboardingShell] for the layouts).
class RaftOnboardingPage extends StatelessWidget {
  const RaftOnboardingPage({
    super.key,
    required this.title,
    required this.children,
    this.banner,
    this.notice,
    this.footer,
    this.preview,
  });
  final String title;
  final String? banner, notice;
  final List<Widget> children;
  final Widget? footer;

  /// The desktop dot-pane preview (null: narrow layout at every width).
  final Widget? preview;

  @override
  Widget build(BuildContext context) => RaftOnboardingShell(
    preview: preview,
    narrowPadding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: _gap16([
        RaftAuthIntro(title: title),
        if (banner != null) RaftAuthBanner(text: banner!),
        if (notice != null) RaftAuthBanner(text: notice!, info: true),
        ...children,
        ?footer,
      ]),
    ),
  );
}

/// A `gap-4` column of onboarding form rows.
class RaftAuthFormColumn extends StatelessWidget {
  const RaftAuthFormColumn({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: _gap16(children),
  );
}

/// Muted body paragraph (`text-sm text-foreground-muted`).
class RaftAuthNote extends StatelessWidget {
  const RaftAuthNote(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final t = RaftTokens.of(context);
    return Text(
      text,
      style: RaftTypography.heading(
        t,
        size: 14,
        line: 20,
        weight: FontWeight.w400,
      ).copyWith(color: t.muted),
    );
  }
}

/// InputDecoration for an input inside [RaftAuthHandleGroup]: `border-0
/// bg-transparent shadow-none`, input recipe padding (py-2 px-3).
InputDecoration raftAuthGroupedInputDecoration({String? hintText}) =>
    InputDecoration(
      hintText: hintText,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      filled: false,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
    );

/// SignedInAs: `{prefix} <strong>{email}</strong>` (the description of the
/// choose-server page).
InlineSpan raftAuthSignedInAsSpan(BuildContext context, String email) =>
    TextSpan(
      children: [
        TextSpan(text: '${raftText(context, 'Signed in as')} '),
        TextSpan(
          text: email,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ],
    );

/// `<strong className="font-mono text-sm">{text}</strong>` inside a muted
/// description (the address of "Check your email").
InlineSpan raftAuthMonoStrongSpan(BuildContext context, String text) =>
    TextSpan(
      text: text,
      style: TextStyle(
        fontFamily: RaftTokens.of(context).monoFont,
        fontWeight: FontWeight.w700,
        fontSize: 14,
      ),
    );
