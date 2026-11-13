import 'package:flutter/material.dart';

import '../theme/tokens.dart';

enum WButtonKind { primary, secondary, ghost, danger }

/// Prototype `.btn` family: primary / secondary / ghost (+ danger for destructive).
class WButton extends StatelessWidget {
  const WButton(
    this.label, {
    super.key,
    this.onPressed,
    this.kind = WButtonKind.primary,
    this.icon,
    this.loading = false,
    this.expand = true,
    this.compact = false,
  });

  const WButton.secondary(this.label, {super.key, this.onPressed, this.icon, this.loading = false, this.expand = true, this.compact = false})
    : kind = WButtonKind.secondary;
  const WButton.ghost(this.label, {super.key, this.onPressed, this.icon, this.loading = false, this.expand = false, this.compact = true})
    : kind = WButtonKind.ghost;
  const WButton.danger(this.label, {super.key, this.onPressed, this.icon, this.loading = false, this.expand = true, this.compact = false})
    : kind = WButtonKind.danger;

  final String label;
  final VoidCallback? onPressed;
  final WButtonKind kind;
  final IconData? icon;
  final bool loading;
  final bool expand;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final enabled = onPressed != null && !loading;
    final (bg, fg, border) = switch (kind) {
      WButtonKind.primary => (c.accent, c.onAccent, Colors.transparent),
      WButtonKind.secondary => (c.surface, c.text, c.divider),
      WButtonKind.ghost => (Colors.transparent, c.accent, Colors.transparent),
      WButtonKind.danger => (c.dangerSoft, c.danger, Colors.transparent),
    };
    final child = Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (loading)
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
        else if (icon != null)
          Icon(icon, size: 18, color: fg),
        if (loading || icon != null) const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 14 : 15, fontWeight: FontWeight.w500, color: fg),
          ),
        ),
      ],
    );
    return Opacity(
      opacity: enabled || loading ? 1 : 0.45,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(WRadius.md),
          side: BorderSide(color: border),
        ),
        child: InkWell(
          onTap: enabled ? onPressed : null,
          borderRadius: BorderRadius.circular(WRadius.md),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: compact ? 8 : 13),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Round icon button used in screen top bars (`.btn-icon`).
class WIconButton extends StatelessWidget {
  const WIconButton(this.icon, {super.key, this.onPressed, this.tooltip, this.size = 40});
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final btn = Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: 22, color: c.text),
        ),
      ),
    );
    return tooltip == null
        ? btn
        : Tooltip(
            message: tooltip!,
            child: Semantics(button: true, label: tooltip, child: btn),
          );
  }
}
