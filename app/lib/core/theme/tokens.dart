import 'package:flutter/material.dart';

/// Design tokens from the Warrantra prototype (dark) plus a matching light
/// theme derived from the same OKLCH ramps and the logo's blurple.
/// Widgets read these through `context.w` — never hard-coded colors.
@immutable
class WColors extends ThemeExtension<WColors> {
  const WColors({
    required this.bg,
    required this.surface,
    required this.surfaceRaised,
    required this.text,
    required this.textMuted,
    required this.textSubtle,
    required this.divider,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.accentSoftText,
    required this.accentRing,
    required this.urgent,
    required this.urgentSoft,
    required this.success,
    required this.danger,
    required this.dangerSoft,
    required this.shadow,
  });

  final Color bg;
  final Color surface;
  final Color surfaceRaised;
  final Color text;
  final Color textMuted;
  final Color textSubtle;
  final Color divider;
  final Color accent;
  final Color onAccent;
  final Color accentSoft;
  final Color accentSoftText;
  final Color accentRing;
  final Color urgent;
  final Color urgentSoft;
  final Color success;
  final Color danger;
  final Color dangerSoft;
  final Color shadow;

  // Prototype ramps (shared lightness scale).
  static const neutral = {
    100: Color(0xFFF3F5FE), 200: Color(0xFFE4E7F5), 300: Color(0xFFCFD3E5), 400: Color(0xFFB2B6CA),
    500: Color(0xFF9397AB), 600: Color(0xFF75798C), 700: Color(0xFF595D6C), 800: Color(0xFF3F424D), 900: Color(0xFF292B31),
  };
  static const accentRamp = {
    100: Color(0xFFF5F4FF), 200: Color(0xFFE7E5FE), 300: Color(0xFFD2CEFD), 400: Color(0xFFB5ABFC),
    500: Color(0xFF968AE0), 600: Color(0xFF796CBF), 700: Color(0xFF5D5294), 800: Color(0xFF423A6A), 900: Color(0xFF2B2741),
  };

  static const dark = WColors(
    bg: Color(0xFF161826),
    surface: Color(0xFF232532),
    surfaceRaised: Color(0xFF2B2E3D),
    text: Color(0xFFE9E9ED),
    textMuted: Color(0xFFB2B6CA),
    textSubtle: Color(0xFF9397AB),
    divider: Color(0x29E9E9ED),
    accent: Color(0xFF9184D9),
    onAccent: Color(0xFF14121F),
    accentSoft: Color(0xFF2B2741),
    accentSoftText: Color(0xFFD2CEFD),
    accentRing: Color(0xFF5D5294),
    urgent: Color(0xFFD2CEFD),
    urgentSoft: Color(0xFF423A6A),
    success: Color(0xFF9FD8C0),
    danger: Color(0xFFF2A7A7),
    dangerSoft: Color(0xFF3A2328),
    shadow: Color(0x8C000000),
  );

  static const light = WColors(
    bg: Color(0xFFF6F6FC),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF0F0F9),
    text: Color(0xFF1D1E2A),
    textMuted: Color(0xFF595D6C),
    textSubtle: Color(0xFF75798C),
    divider: Color(0x1F1D1E2A),
    accent: Color(0xFF6650C6),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFEDEBFE),
    accentSoftText: Color(0xFF4A3FA0),
    accentRing: Color(0xFFB5ABFC),
    urgent: Color(0xFF4A3FA0),
    urgentSoft: Color(0xFFE7E5FE),
    success: Color(0xFF1F7A57),
    danger: Color(0xFFB3261E),
    dangerSoft: Color(0xFFFBE9E8),
    shadow: Color(0x1A1D1E2A),
  );

  @override
  WColors copyWith() => this;

  @override
  WColors lerp(ThemeExtension<WColors>? other, double t) {
    if (other is! WColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return WColors(
      bg: l(bg, other.bg), surface: l(surface, other.surface), surfaceRaised: l(surfaceRaised, other.surfaceRaised),
      text: l(text, other.text), textMuted: l(textMuted, other.textMuted), textSubtle: l(textSubtle, other.textSubtle),
      divider: l(divider, other.divider), accent: l(accent, other.accent), onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft), accentSoftText: l(accentSoftText, other.accentSoftText),
      accentRing: l(accentRing, other.accentRing), urgent: l(urgent, other.urgent), urgentSoft: l(urgentSoft, other.urgentSoft),
      success: l(success, other.success), danger: l(danger, other.danger), dangerSoft: l(dangerSoft, other.dangerSoft),
      shadow: l(shadow, other.shadow),
    );
  }
}

/// Spacing, radii and type scale from the prototype.
class WSpace {
  static const xs = 4.0, s = 8.0, m = 12.0, l = 16.0, xl = 20.0, xxl = 28.0;
}

class WRadius {
  static const sm = 6.0, md = 10.0, lg = 16.0, pill = 999.0;
}

extension WTheme on BuildContext {
  WColors get w => Theme.of(this).extension<WColors>()!;
  TextTheme get t => Theme.of(this).textTheme;
}
