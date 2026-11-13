import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/tokens.dart';

enum WTagKind { accent, neutral, outline, urgent, danger }

/// Small status pill (`.tag-*`). Color is never the only signal: tags carry text and usually an icon.
class WTag extends StatelessWidget {
  const WTag(this.label, {super.key, this.kind = WTagKind.neutral, this.icon});
  final String label;
  final WTagKind kind;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final (bg, fg, border) = switch (kind) {
      WTagKind.accent => (c.accentSoft, c.accentSoftText, Colors.transparent),
      WTagKind.neutral => (c.surfaceRaised, c.textMuted, Colors.transparent),
      WTagKind.outline => (Colors.transparent, c.textMuted, c.divider),
      WTagKind.urgent => (c.urgentSoft, c.urgent, Colors.transparent),
      WTagKind.danger => (c.dangerSoft, c.danger, Colors.transparent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(WRadius.pill), border: Border.all(color: border)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: fg), const SizedBox(width: 4)],
        Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: fg)),
      ]),
    );
  }
}

/// Certainty labels from the spec: verified / confirmed / estimated / unknown.
class CertBadge extends StatelessWidget {
  const CertBadge(this.certainty, {super.key, this.long = false});
  final String? certainty;
  final bool long;

  static (String, String, IconData, WTagKind) describe(String? c) => switch (c) {
        'document_verified' => ('Verified', 'Verified from document', PhosphorIconsRegular.sealCheck, WTagKind.accent),
        'user_confirmed' => ('Confirmed', 'You confirmed', PhosphorIconsRegular.userCheck, WTagKind.neutral),
        'estimated' => ('Estimated', 'Estimated', PhosphorIconsRegular.circleDashed, WTagKind.outline),
        _ => ('Unknown', 'Unknown', PhosphorIconsRegular.question, WTagKind.neutral),
      };

  @override
  Widget build(BuildContext context) {
    final (short, longLabel, icon, kind) = describe(certainty);
    return WTag(long ? longLabel : short, kind: kind, icon: icon);
  }
}

/// Surface card.
class WCard extends StatelessWidget {
  const WCard({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.onTap, this.color, this.border = true});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Material(
      color: color ?? c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WRadius.lg),
        side: border ? BorderSide(color: c.divider) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
    );
  }
}

/// A tappable row with a leading icon tile, title, subtitle and trailing caret.
class WListRow extends StatelessWidget {
  const WListRow({super.key, required this.title, this.subtitle, this.icon, this.leading, this.trailing, this.onTap, this.caret = true, this.dense = false, this.titleColor});
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool caret;
  final bool dense;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(WRadius.md),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: dense ? 8 : 11, horizontal: 2),
        child: Row(children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)]
          else if (icon != null) ...[IconTile(icon!), const SizedBox(width: 12)],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: titleColor ?? c.text)),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subtitle!, style: TextStyle(fontSize: 13, height: 1.35, color: c.textMuted)),
              ],
            ]),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
          if (caret && onTap != null) ...[const SizedBox(width: 6), Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle)],
        ]),
      ),
    );
  }
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.size = 40, this.emphasis = false});
  final IconData icon;
  final double size;
  final bool emphasis;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: emphasis ? c.urgentSoft : c.accentSoft, borderRadius: BorderRadius.circular(WRadius.md)),
      child: Icon(icon, size: size * 0.5, color: emphasis ? c.urgent : c.accentSoftText),
    );
  }
}

/// Uppercase section label with an optional trailing action (prototype "Coverage  + Add").
class WSectionHeader extends StatelessWidget {
  const WSectionHeader(this.label, {super.key, this.action, this.onAction, this.actionIcon});
  final String label;
  final String? action;
  final VoidCallback? onAction;
  final IconData? actionIcon;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Row(children: [
        Expanded(child: Text(label.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: 1.1, fontWeight: FontWeight.w600, color: c.textSubtle))),
        if (action != null)
          InkWell(
            onTap: onAction,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(children: [
                Icon(actionIcon ?? PhosphorIconsRegular.plus, size: 14, color: c.accent),
                const SizedBox(width: 4),
                Text(action!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: c.accent)),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Muted information box (prototype `[icon:info]` notes).
class WNote extends StatelessWidget {
  const WNote(this.text, {super.key, this.icon, this.emphasis = false});
  final String text;
  final IconData? icon;
  final bool emphasis;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: emphasis ? c.accentSoft : c.surfaceRaised, borderRadius: BorderRadius.circular(WRadius.md)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon ?? PhosphorIconsRegular.info, size: 16, color: emphasis ? c.accentSoftText : c.textMuted),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, height: 1.45, color: emphasis ? c.accentSoftText : c.textMuted))),
      ]),
    );
  }
}

/// Key/value row used in Purchase details and claim review.
class WKeyValue extends StatelessWidget {
  const WKeyValue(this.k, this.v, {super.key, this.note, this.trailing});
  final String k;
  final String v;
  final String? note;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: 13.5, color: c.textMuted))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v, style: TextStyle(fontSize: 14.5, color: c.text)),
            if (note != null) Text(note!, style: TextStyle(fontSize: 12, color: c.textSubtle)),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Coverage progress bar: share of the term already elapsed.
class WProgressBar extends StatelessWidget {
  const WProgressBar(this.value, {super.key});
  final double value;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(value: value.clamp(0, 1), minHeight: 6, backgroundColor: c.accentSoft, color: c.accent),
    );
  }
}

class WEmpty extends StatelessWidget {
  const WEmpty({super.key, required this.icon, required this.title, required this.message, this.action});
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 8),
      child: Column(children: [
        IconTile(icon, size: 56),
        const SizedBox(height: 14),
        Text(title, textAlign: TextAlign.center, style: context.t.titleLarge),
        const SizedBox(height: 6),
        Text(message, textAlign: TextAlign.center, style: TextStyle(fontSize: 14.5, height: 1.5, color: c.textMuted)),
        if (action != null) ...[const SizedBox(height: 18), action!],
      ]),
    );
  }
}

class WAvatar extends StatelessWidget {
  const WAvatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;
  String get initials {
    final parts = name.trim().split(RegExp(r'[\s@._-]+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts[1][0] : '')).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: c.accentSoft, shape: BoxShape.circle, border: Border.all(color: c.accentRing)),
      child: Text(initials, style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w600, color: c.accentSoftText)),
    );
  }
}

/// The Warrantra logo (transparent PNG generated from the brand mark).
class WLogo extends StatelessWidget {
  const WLogo({super.key, this.size = 56});
  final double size;
  @override
  Widget build(BuildContext context) => Image.asset('assets/brand/logo.png', width: size, height: size, semanticLabel: 'Warrantra');
}
