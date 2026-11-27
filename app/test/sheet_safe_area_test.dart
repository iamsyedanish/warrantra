// Bottom sheets must sit above the system navigation bar (3-button or gesture)
// and above the keyboard; Flutter's useSafeArea only protects the top and sides.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:warrantra/core/widgets/scaffold.dart';

Future<double> sheetGap(WidgetTester tester, {double navBar = 0, double keyboard = 0}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  tester.view.viewPadding = FakeViewPadding(bottom: navBar * 3);
  tester.view.padding = FakeViewPadding(bottom: navBar * 3);
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => showWSheet<void>(context, builder: (_) => const SizedBox(key: Key('sheet-content'), height: 100)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  final screenHeight = tester.view.physicalSize.height / tester.view.devicePixelRatio;
  return screenHeight - tester.getBottomLeft(find.byKey(const Key('sheet-content'))).dy;
}

void main() {
  testWidgets('sheet content clears the navigation bar', (tester) async {
    final gap = await sheetGap(tester, navBar: 48);
    expect(gap, greaterThanOrEqualTo(48 + 20)); // bar + the sheet's own 20 px margin
  });

  testWidgets('sheet content clears the keyboard', (tester) async {
    final gap = await sheetGap(tester, navBar: 48, keyboard: 300);
    expect(gap, greaterThanOrEqualTo(300 + 20));
  });

  testWidgets('no extra space without a navigation bar', (tester) async {
    final gap = await sheetGap(tester);
    expect(gap, closeTo(20, 1));
  });
}
