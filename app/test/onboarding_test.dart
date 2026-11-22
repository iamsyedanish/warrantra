// Walks every onboarding page in light, dark and large text at phone size and
// fails on any overflow or exception. With SHOTS=1 it also writes PNGs to
// build/onboarding_shots/ for a visual check.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warrantra/core/storage/secure_store.dart';
import 'package:warrantra/core/theme/app_theme.dart';
import 'package:warrantra/features/auth/presentation/auth_screens.dart';

Future<void> _font(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  final shots = Platform.environment['SHOTS'] == '1';
  setUpAll(() async {
    await _font('Inter', 'assets/fonts/Inter.ttf');
    for (final (f, a) in [('Regular', 'Phosphor.ttf'), ('Fill', 'Phosphor-Fill.ttf'), ('Bold', 'Phosphor-Bold.ttf')]) {
      await _font('packages/phosphor_flutter/Phosphor$f', 'packages/phosphor_flutter/lib/fonts/$a');
    }
  });

  // Small Android phone (360x740) and a large one.
  for (final (name, size) in [('small', const Size(1080, 2220)), ('large', const Size(1206, 2622))]) {
    for (final (mode, scale) in [(ThemeMode.light, 1.0), (ThemeMode.dark, 1.0), (ThemeMode.dark, 1.3)]) {
      testWidgets('onboarding $name ${mode.name}${scale == 1 ? '' : ' large-text'}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 3;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.toString().split('\n').where((l) => l.contains('overflowed') || l.contains('lib/')).take(4).join('\n'));
        SharedPreferences.setMockInitialValues({});
        final prefs = await SharedPreferences.getInstance();
        final key = GlobalKey();
        await tester.pumpWidget(ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(theme: AppTheme.light(), darkTheme: AppTheme.dark(), themeMode: mode, home: const OnboardingScreen()),
          ),
        ));
        await tester.pumpAndSettle();
        for (var page = 1; page <= 4; page++) {
          if (shots && scale == 1 && (name == 'small' || mode == ThemeMode.light)) {
            await tester.runAsync(() async {
              final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 1);
              final png = await image.toByteData(format: ui.ImageByteFormat.png);
              final f = File('build/onboarding_shots/${name}_${mode.name}_$page.png')..createSync(recursive: true);
              f.writeAsBytesSync(png!.buffer.asUint8List());
            });
          }
          if (page < 4) {
            await tester.tap(find.text('Next'));
            await tester.pumpAndSettle();
          }
        }
        FlutterError.onError = previous;
        expect(errors, isEmpty, reason: errors.join('\n---\n'));
        expect(tester.takeException(), isNull);
        expect(find.text('Get started, free'), findsOneWidget);
      });
    }
  }
}
