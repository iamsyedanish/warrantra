import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/secure_store.dart';
import 'tokens.dart';

class AppTheme {
  static ThemeData light() => _build(WColors.light, Brightness.light);
  static ThemeData dark() => _build(WColors.dark, Brightness.dark);

  static ThemeData _build(WColors c, Brightness b) {
    final base = ThemeData(useMaterial3: true, brightness: b, fontFamily: 'Inter');
    // Headings use weight 500 with tight tracking, as in the prototype.
    TextStyle h(double size) => TextStyle(fontSize: size, fontWeight: FontWeight.w500, letterSpacing: -0.015 * size, height: 1.15, color: c.text);
    final text = base.textTheme.copyWith(
      displaySmall: h(34),
      headlineMedium: h(28),
      headlineSmall: h(24),
      titleLarge: h(20),
      titleMedium: h(16).copyWith(height: 1.3),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: c.text),
      bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: c.text),
      bodyMedium: TextStyle(fontSize: 14.5, height: 1.5, color: c.text),
      bodySmall: TextStyle(fontSize: 12.5, height: 1.45, color: c.textMuted),
      labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: c.text),
      labelMedium: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.textMuted),
      labelSmall: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 1.0, color: c.textSubtle),
    );
    final scheme = ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
      primary: c.accent, onPrimary: c.onAccent, surface: c.surface, onSurface: c.text, error: c.danger,
    );
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(WRadius.md), borderSide: BorderSide(color: c.divider));
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      textTheme: text,
      extensions: [c],
      dividerTheme: DividerThemeData(color: c.divider, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: c.bg, surfaceTintColor: Colors.transparent, elevation: 0, scrolledUnderElevation: 0,
        foregroundColor: c.text, centerTitle: true,
        titleTextStyle: TextStyle(fontFamily: 'Inter', fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
        systemOverlayStyle: b == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        hintStyle: TextStyle(color: c.textSubtle),
        border: border,
        enabledBorder: border,
        focusedBorder: border.copyWith(borderSide: BorderSide(color: c.accent, width: 1.5)),
        errorBorder: border.copyWith(borderSide: BorderSide(color: c.danger)),
        focusedErrorBorder: border.copyWith(borderSide: BorderSide(color: c.danger, width: 1.5)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface, surfaceTintColor: Colors.transparent, showDragHandle: true, dragHandleColor: c.textSubtle,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface, surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WRadius.lg)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating, backgroundColor: c.surfaceRaised,
        contentTextStyle: TextStyle(fontFamily: 'Inter', color: c.text, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(WRadius.md)),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.accentSoft),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onAccent : c.textSubtle),
        trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.accent : c.surfaceRaised),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
    );
  }
}

/// User's theme choice (System / Light / Dark), persisted locally.
class ThemeModeController extends Notifier<ThemeMode> {
  static const _key = 'theme_mode';

  @override
  ThemeMode build() {
    final v = ref.watch(sharedPrefsProvider).getString(_key);
    return ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    await ref.read(sharedPrefsProvider).setString(_key, mode.name);
  }
}

final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(ThemeModeController.new);
