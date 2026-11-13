// Opens every screen with demo data, in dark and light, at iPhone size,
// and fails on any exception, overflow or layout error.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warrantra/core/router/app_router.dart';
import 'package:warrantra/core/storage/secure_store.dart';
import 'package:warrantra/demo/demo_mode.dart';
import 'package:warrantra/main.dart';

const routes = [
  '/home', '/items', '/vault', '/settings',
  '/items/airpods', '/items/tv', '/items/washer', '/items/airpods/edit',
  '/items/airpods/coverage/new', '/items/airpods/coverage/w-airpods',
  '/items/airpods/return/r1', '/items/airpods/return/r1/edit', '/items/airpods/return/new',
  '/items/dyson/registration/g1', '/items/dyson/registration/new',
  '/capture/manual', '/capture/ai-consent', '/capture/ai-limit', '/capture/ai-limit?reason=ai_suspended',
  '/capture/upload-issue', '/capture/failed?code=not_a_receipt', '/capture/failed',
  '/capture/review/scan1', '/capture/product/label1', '/capture/coverage', '/drafts',
  '/vault/doc-airpods', '/vault/doc-w',
  '/claims', '/claims/new?item=tv', '/claims/c1', '/claims/c1/pack', '/outcomes', '/outcomes/new?claim=c1', '/outcomes/new?return=r1',
  '/settings/plan', '/settings/paywall', '/settings/reminders', '/settings/region', '/settings/privacy',
  '/settings/export', '/settings/delete-account', '/settings/annual', '/settings/digest', '/settings/support',
  '/settings/switch-account', '/settings/email-forwarding',
  '/household', '/household?share=airpods', '/portfolio', '/maintenance?item=washer', '/cards',
];

Future<void> openRoute(WidgetTester tester, String route, Brightness brightness, {double textScale = 1}) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

  SharedPreferences.setMockInitialValues({'onboarding_seen': true});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs), ...demoOverrides],
    child: const WarrantraApp(),
  ));
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final container = ProviderScope.containerOf(tester.element(find.byType(WarrantraApp)));
  container.read(routerProvider).go(route);
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> loadFont(String family, String asset) async {
  final loader = FontLoader(family)..addFont(rootBundle.load(asset));
  await loader.load();
}

void main() {
  // Real fonts, so overflow checks match the phone (the default test font is wider).
  setUpAll(() async {
    await loadFont('Inter', 'assets/fonts/Inter.ttf');
    for (final (f, a) in [('Regular', 'Phosphor.ttf'), ('Fill', 'Phosphor-Fill.ttf'), ('Bold', 'Phosphor-Bold.ttf')]) {
      await loadFont('packages/phosphor_flutter/Phosphor$f', 'packages/phosphor_flutter/lib/fonts/$a');
    }
  });
  for (final (b, scale) in [(Brightness.dark, 1.0), (Brightness.light, 1.0), (Brightness.dark, 1.35)]) {
    for (final r in routes) {
      testWidgets('${b.name}${scale == 1 ? '' : ' large-text'} $r', (tester) async {
        final errors = <String>[];
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.toString().split('\n').where((l) => l.contains('overflowed') || l.contains('lib/') || l.contains('Exception') || l.contains('Error')).take(6).join('\n'));
        await openRoute(tester, r, b, textScale: scale);
        FlutterError.onError = previous;
        expect(errors, isEmpty, reason: 'errors on $r:\n${errors.join('\n---\n')}');
        expect(tester.takeException(), isNull, reason: 'exception on $r');
        expect(find.byType(ErrorWidget), findsNothing, reason: 'error widget on $r');
        // Unmount so periodic timers (polling screens) are cancelled.
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      });
    }
  }
}
