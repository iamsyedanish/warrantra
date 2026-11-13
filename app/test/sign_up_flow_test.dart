// Sign-up flow against a fake auth repository (nothing is sent to the API).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:warrantra/core/router/app_router.dart';
import 'package:warrantra/core/storage/secure_store.dart';
import 'package:warrantra/demo/demo_mode.dart';
import 'package:warrantra/features/auth/domain/auth_repository.dart';
import 'package:warrantra/features/auth/presentation/session_controller.dart';
import 'package:warrantra/main.dart';

class FakeAuth implements AuthRepository {
  FakeAuth({this.confirmEmail = false});
  final bool confirmEmail;
  final calls = <String>[];
  bool signedIn = false;
  @override
  Future<bool> hasSession() async => signedIn;
  @override
  Future<SignUpResult> signUp({required String email, required String password, String? displayName}) async {
    calls.add('signUp:$email');
    signedIn = !confirmEmail;
    return SignUpResult(signedIn: !confirmEmail, emailConfirmationRequired: confirmEmail);
  }
  @override
  Future<void> signIn({required String email, required String password}) async => calls.add('signIn:$email');
  @override
  Future<void> signInWithProvider(SocialProvider provider) async {}
  @override
  Future<void> sendPasswordReset(String email) async => calls.add('reset:$email');
  @override
  Future<void> signOut() async {}
}

Future<ProviderContainer> boot(WidgetTester tester, FakeAuth auth) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({'onboarding_seen': true});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(ProviderScope(
    // Demo repositories stand in for the API once signed in; auth is the fake under test.
    overrides: [sharedPrefsProvider.overrideWithValue(prefs), ...demoOverrides.skip(1), authRepositoryProvider.overrideWithValue(auth)],
    child: const WarrantraApp(),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  final c = ProviderScope.containerOf(tester.element(find.byType(WarrantraApp)));
  c.read(routerProvider).go('/signup');
  await tester.pump(const Duration(milliseconds: 600));
  return c;
}

Finder field(String label) => find.descendant(of: find.ancestor(of: find.text(label), matching: find.byType(Column)).first, matching: find.byType(TextField));

Future<void> fill(WidgetTester tester, {String name = '', required String email, required String password}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), name);
  await tester.enterText(fields.at(1), email);
  await tester.enterText(fields.at(2), password);
  await tester.pump();
}

Future<void> tapCreate(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(InkWell, 'Create account').last, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(() async {
    final inter = FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/Inter.ttf'));
    await inter.load();
  });
  testWidgets('signed out, the app lands on sign-in', (tester) async {
    final auth = FakeAuth();
    await boot(tester, auth);
    expect(find.text('Create your account'), findsOneWidget);
    final c = ProviderScope.containerOf(tester.element(find.byType(WarrantraApp)));
    expect(c.read(sessionProvider), SessionStatus.signedOut);
  });

  testWidgets('empty form is refused without calling the server', (tester) async {
    final auth = FakeAuth();
    await boot(tester, auth);
    await tapCreate(tester);
    expect(auth.calls, isEmpty);
    expect(find.textContaining('valid email'), findsOneWidget);
  });

  testWidgets('bad email and short password are refused', (tester) async {
    final auth = FakeAuth();
    await boot(tester, auth);
    await fill(tester, email: 'alex@', password: 'longenough1');
    await tapCreate(tester);
    await fill(tester, email: 'alex@example.com', password: 'short');
    expect(find.text('At least 10 characters'), findsOneWidget);
    await tapCreate(tester);
    expect(auth.calls, isEmpty);
  });

  testWidgets('valid sign-up trims the email and asks to confirm it', (tester) async {
    final auth = FakeAuth(confirmEmail: true);
    await boot(tester, auth);
    await fill(tester, name: 'Alex', email: '  alex@example.com ', password: 'a-strong-pass-123');
    expect(find.text('✓ 10+ characters'), findsOneWidget);
    await tapCreate(tester);
    expect(auth.calls, ['signUp:alex@example.com']);
    expect(find.text('Confirm your email'), findsOneWidget);
  });

  testWidgets('sign-up without email confirmation goes straight to the Action Center', (tester) async {
    final auth = FakeAuth();
    final c = await boot(tester, auth);
    await fill(tester, email: 'alex@example.com', password: 'a-strong-pass-123');
    await tapCreate(tester);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(c.read(sessionProvider), SessionStatus.signedIn);
    expect(find.text('Action Center'), findsOneWidget);
  });
}
