import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../../../core/storage/secure_store.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../domain/auth_repository.dart';
import 'session_controller.dart';

const _tagline = 'Keep the proof. Know the deadline. Be ready when something goes wrong.';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: RadialGradient(center: const Alignment(-1, -0.2), radius: 1.2, colors: [c.accentSoft, c.bg]),
        ),
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 80),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const WLogo(size: 72),
          const SizedBox(height: 16),
          Text('Warrantra', style: context.t.displaySmall),
          const SizedBox(height: 8),
          Text(_tagline, style: TextStyle(fontSize: 16, height: 1.5, color: c.textMuted)),
          const SizedBox(height: 28),
          Row(children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
            const SizedBox(width: 10),
            Text('Restoring your session', style: TextStyle(fontSize: 13, color: c.textSubtle)),
          ]),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------- onboarding
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});
  static const seenKey = 'onboarding_seen';
  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingState();
}

class _OnboardingState extends ConsumerState<OnboardingScreen> {
  final _page = PageController();
  int _i = 0;

  Future<void> _finish() async {
    await ref.read(sharedPrefsProvider).setBool(OnboardingScreen.seenKey, true);
    if (mounted) context.go('/signin');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final pages = [
      _ObPage(
        title: 'Keep the proof.',
        body: 'Receipts, warranty cards and order PDFs in one private vault. One receipt can cover several things you bought.',
        fragment: _Fragment(children: [
          Text('One receipt · two items', style: TextStyle(fontSize: 12, color: c.textSubtle)),
          const SizedBox(height: 8),
          WListRow(icon: PhosphorIconsRegular.receipt, title: 'Home Depot order H8829-114', subtitle: 'PDF · 2 pages · stored once', caret: false, dense: true),
          Row(children: [
            WTag('LG washer', icon: PhosphorIconsRegular.washingMachine, kind: WTagKind.accent),
            const SizedBox(width: 6),
            WTag('LG dryer', icon: PhosphorIconsRegular.wind, kind: WTagKind.accent),
          ]),
        ]),
      ),
      _ObPage(
        title: 'Know the deadline.',
        body: 'Returns, registrations and coverage dates, each marked verified, estimated or unknown. Unknown stays unknown.',
        fragment: _Fragment(children: [
          _ObRow('Return · Sat, Nov 7', 'From Best Buy receipt', const CertBadge('user_confirmed', long: true)),
          _ObRow('Warranty · Oct 23, 2027', '12 months from purchase', const CertBadge('estimated')),
          _ObRow('Washer coverage', 'No terms found yet', const CertBadge('unknown')),
        ]),
      ),
      _ObPage(
        title: 'Be ready when something goes wrong.',
        body: "Turn saved facts and proof into a claim pack. Warrantra isn't an insurer and can't guarantee a claim.",
        fragment: _Fragment(children: [
          Text('Claim pack', style: TextStyle(fontSize: 12, color: c.textSubtle)),
          const SizedBox(height: 4),
          Text('Samsung 65" QN90D · backlight flicker', style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
          const SizedBox(height: 8),
          for (final l in ['Product, model and serial', 'Receipt and coverage terms', 'Your photos and description'])
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(children: [Icon(PhosphorIconsBold.check, size: 14, color: c.accent), const SizedBox(width: 6), Text(l, style: TextStyle(color: c.textMuted, fontSize: 13.5))]),
            ),
          const SizedBox(height: 4),
          Text('You review it and send it to the provider.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
        ]),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.all(8), child: WButton.ghost('Skip', onPressed: _finish))),
          Expanded(
            child: PageView(controller: _page, onPageChanged: (i) => setState(() => _i = i), children: pages),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var d = 0; d < pages.length; d++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: d == _i ? 20 : 6,
                height: 6,
                decoration: BoxDecoration(color: d == _i ? c.accent : c.divider, borderRadius: BorderRadius.circular(3)),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: WButton(_i == pages.length - 1 ? 'Start tracking purchases' : 'Next',
                onPressed: () => _i == pages.length - 1 ? _finish() : _page.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut)),
          ),
        ]),
      ),
    );
  }
}

class _ObPage extends StatelessWidget {
  const _ObPage({required this.title, required this.body, required this.fragment});
  final String title, body;
  final Widget fragment;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        fragment,
        const SizedBox(height: 32),
        Text(title, style: context.t.headlineMedium),
        const SizedBox(height: 10),
        Text(body, style: TextStyle(fontSize: 16, height: 1.5, color: context.w.textMuted)),
      ]),
    );
  }
}

class _Fragment extends StatelessWidget {
  const _Fragment({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => WCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children));
}

class _ObRow extends StatelessWidget {
  const _ObRow(this.title, this.sub, this.badge);
  final String title, sub;
  final Widget badge;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w500, color: context.w.text)),
              Text(sub, style: TextStyle(fontSize: 12.5, color: context.w.textMuted)),
            ]),
          ),
          badge,
        ]),
      );
}

// ---------------------------------------------------------------------------- sign in
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInState();
}

class _SignInState extends ConsumerState<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _busy;

  Future<void> _run(String key, Future<void> Function() action) async {
    setState(() => _busy = key);
    try {
      await action();
      ref.read(sessionProvider.notifier).markSignedIn();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final repo = ref.read(authRepositoryProvider);
    return WScreen(
      showBack: false,
      children: [
        const SizedBox(height: 20),
        const Align(alignment: Alignment.centerLeft, child: WLogo(size: 48)),
        const WHeading('Sign in', subtitle: 'Your purchases and documents stay private to your account.', large: true),
        WButton.secondary('Continue with Apple', icon: PhosphorIconsFill.appleLogo, loading: _busy == 'apple',
            onPressed: _busy != null ? null : () => _run('apple', () => repo.signInWithProvider(SocialProvider.apple))),
        const SizedBox(height: 10),
        WButton.secondary('Continue with Google', icon: PhosphorIconsBold.googleLogo, loading: _busy == 'google',
            onPressed: _busy != null ? null : () => _run('google', () => repo.signInWithProvider(SocialProvider.google))),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(children: [
            Expanded(child: Divider(color: c.divider)),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text('or with email', style: TextStyle(fontSize: 12.5, color: c.textSubtle))),
            Expanded(child: Divider(color: c.divider)),
          ]),
        ),
        AutofillGroup(
          child: Column(children: [
            WField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email], textInputAction: TextInputAction.next),
            WField(label: 'Password', controller: _password, obscure: true, autofillHints: const [AutofillHints.password]),
          ]),
        ),
        Align(alignment: Alignment.centerRight, child: WButton.ghost('Forgot password?', onPressed: () => context.push('/forgot'))),
        const SizedBox(height: 8),
        WButton('Sign in', loading: _busy == 'email', onPressed: _busy != null
            ? null
            : () {
                if (_email.text.trim().isEmpty || _password.text.isEmpty) {
                  showToast(context, 'Enter your email and password.');
                  return;
                }
                _run('email', () => repo.signIn(email: _email.text, password: _password.text));
              }),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Text('New to Warrantra?', style: TextStyle(color: c.textMuted)),
          WButton.ghost('Create account', onPressed: () => context.push('/signup')),
        ]),
        const SizedBox(height: 10),
        Text('Accounts are never merged just because two sign-in methods share an email.',
            textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.textSubtle)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------- sign up
class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});
  @override
  ConsumerState<SignUpScreen> createState() => _SignUpState();
}

class _SignUpState extends ConsumerState<SignUpScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _checkEmail = false;

  bool get _passwordOk => _password.text.length >= 10;

  Future<void> _submit() async {
    if (!_email.text.contains('@') || !_passwordOk) {
      showToast(context, 'Enter a valid email and a password of at least 10 characters.');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await ref.read(authRepositoryProvider).signUp(email: _email.text, password: _password.text, displayName: _name.text.trim());
      if (r.signedIn) {
        ref.read(sessionProvider.notifier).markSignedIn();
      } else {
        setState(() => _checkEmail = true);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    if (_checkEmail) {
      return WScreen(children: [
        const SizedBox(height: 40),
        WEmpty(
          icon: PhosphorIconsRegular.envelopeSimple,
          title: 'Confirm your email',
          message: 'We sent a confirmation link to ${_email.text.trim()}. Open it, then sign in.',
          action: WButton.secondary('Back to sign in', onPressed: () => context.go('/signin'), expand: false),
        ),
      ]);
    }
    return WScreen(
      children: [
        const WHeading('Create your account', subtitle: 'Free includes 10 items, reminders, original files and export.'),
        WField(label: 'Name (optional)', controller: _name, autofillHints: const [AutofillHints.name]),
        WField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email]),
        WField(
          label: 'Password',
          controller: _password,
          obscure: true,
          onChanged: (_) => setState(() {}),
          autofillHints: const [AutofillHints.newPassword],
          helper: _passwordOk ? '✓ 10+ characters' : 'At least 10 characters',
        ),
        const SizedBox(height: 6),
        WButton('Create account', loading: _busy, onPressed: _busy ? null : _submit),
        const SizedBox(height: 14),
        Text(
          "By continuing you agree to the Terms and Privacy Policy. Warrantra stores proof and dates; it isn't insurance and doesn't guarantee claims.",
          style: TextStyle(fontSize: 12, height: 1.45, color: c.textSubtle),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------- forgot password
class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotState();
}

class _ForgotState extends ConsumerState<ForgotPasswordScreen> {
  final _email = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return WScreen(children: [
        const SizedBox(height: 40),
        WEmpty(
          icon: PhosphorIconsRegular.envelopeSimple,
          title: 'Check your email',
          message: 'If an account uses ${_email.text.trim()}, a reset link is on its way. It expires in 1 hour.',
          action: WButton.secondary('Back to sign in', onPressed: () => context.go('/signin'), expand: false),
        ),
      ]);
    }
    return WScreen(children: [
      const WHeading('Reset password', subtitle: "We'll email a link to set a new password."),
      WField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress),
      WButton('Send reset link', loading: _busy, onPressed: () async {
        if (!_email.text.contains('@')) return showToast(context, 'Enter your email address.');
        setState(() => _busy = true);
        try {
          await ref.read(authRepositoryProvider).sendPasswordReset(_email.text);
        } on Failure catch (f) {
          if (f.isOffline && mounted) return showFailure(context, f);
        } finally {
          if (mounted) setState(() => _busy = false);
        }
        if (mounted) setState(() => _sent = true);
      }),
    ]);
  }
}

/// Link out helper for Terms/Privacy references.
const legalLinks = (terms: AppConfig.termsUrl, privacy: AppConfig.privacyUrl);
