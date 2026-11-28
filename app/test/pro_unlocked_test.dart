// The Pro unlock moment must play through and fit on every screen size.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warrantra/features/settings/presentation/pro_unlocked.dart';

void main() {
  for (final (name, size) in [('phone', Size(412, 915)), ('small', Size(320, 640)), ('landscape', Size(915, 412)), ('tablet', Size(800, 1280))]) {
    testWidgets('plays and fits on $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var done = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(
          onPressed: () async { await showProUnlocked(context, period: 'annual'); done = true; },
          child: const Text('go'))))),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      for (var i = 0; i < 40; i++) { await tester.pump(const Duration(milliseconds: 100)); }
      expect(find.text('PRO UNLOCKED'), findsOneWidget);
      expect(find.text('500 items'), findsOneWidget);
      await tester.ensureVisible(find.text('Start using Pro'));
      await tester.pump();
      await tester.tap(find.text('Start using Pro'));
      for (var i = 0; i < 5; i++) { await tester.pump(const Duration(milliseconds: 100)); }
      expect(done, isTrue);
    });
  }
}
