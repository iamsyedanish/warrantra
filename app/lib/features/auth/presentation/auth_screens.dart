import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const WLogo(size: 72),
            const SizedBox(height: 16),
            Text('Warrantra', style: context.t.displaySmall),
            const SizedBox(height: 8),
            Text(_tagline, style: TextStyle(fontSize: 16, height: 1.5, color: c.textMuted)),
            const SizedBox(height: 28),
            Row(
              children: [
                SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: c.accent)),
                const SizedBox(width: 10),
                Flexible(
                  child: Text('Restoring your session', style: TextStyle(fontSize: 13, color: c.textSubtle)),
                ),
              ],
            ),
          ],
        ),
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
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final pages = [
      // 1 · Capture
      _ObPage(
        step: 'Capture',
        title: 'Snap it once.\nWe do the typing.',
        body: 'Add a purchase in seconds from a photo, a PDF or a receipt shared from your email.',
        fragment: _Fragment(
          children: [
            Row(children: [
              Icon(PhosphorIconsRegular.sparkle, size: 14, color: c.accent),
              const SizedBox(width: 6),
              Flexible(child: Text('Read from your receipt. Check, then save.', style: TextStyle(fontSize: 12, color: c.textSubtle))),
            ]),
            const SizedBox(height: 8),
            const _Field('Store', 'Best Buy'),
            const _Field('Date', 'Nov 2, 2026'),
            const _Field('Total', r'$1,249.98'),
            const SizedBox(height: 8),
            const Wrap(spacing: 6, runSpacing: 6, children: [
              WTag('Sony 65" TV', icon: PhosphorIconsRegular.television, kind: WTagKind.accent),
              WTag('Wall mount', icon: PhosphorIconsRegular.wrench, kind: WTagKind.accent),
            ]),
          ],
        ),
        points: const [
          _Point(PhosphorIconsRegular.camera, 'Photo, PDF or share-in', 'Originals are kept, so the proof is always there'),
          _Point(PhosphorIconsRegular.checkCircle, 'You confirm every field', 'Anything unclear is left empty, never guessed'),
          _Point(PhosphorIconsRegular.stack, 'One receipt, many items', 'Track the TV and the mount separately'),
        ],
      ),
      // 2 · Deadlines
      _ObPage(
        step: 'Deadlines',
        title: 'Never miss a return\nor warranty date.',
        body: 'Every item gets its dates worked out, and you get a nudge before each one passes.',
        fragment: _Fragment(
          children: [
            _ObRow('Return to Best Buy', 'Closes Nov 17', const WTag('5 days left', kind: WTagKind.urgent, icon: PhosphorIconsRegular.clock)),
            _ObRow('Sony warranty', 'Until Nov 2, 2027', const CertBadge('estimated')),
            _ObRow('Register the TV', 'Unlocks the extra year', const CertBadge('user_confirmed')),
            _ObRow('Mount coverage', 'No terms found yet', const CertBadge('unknown')),
          ],
        ),
        points: const [
          _Point(PhosphorIconsRegular.bell, 'Reminders before each date', 'At the time you pick, in your time zone'),
          _Point(PhosphorIconsRegular.sealCheck, 'Confirmed, estimated or unknown', "We never assume a 30-day return policy"),
          _Point(PhosphorIconsRegular.calendarCheck, 'A monthly digest', "What's ending soon and what's still missing"),
        ],
      ),
      // 3 · Claims
      _ObPage(
        step: 'Claims',
        title: 'Something broke?\nYou are ready.',
        body: 'Turn what you saved into a claim pack you can send to the store or the maker.',
        fragment: _Fragment(
          children: [
            Text('Claim pack', style: TextStyle(fontSize: 12, color: c.textSubtle)),
            const SizedBox(height: 4),
            Text('Sony 65" TV · screen flicker', style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
            const SizedBox(height: 8),
            for (final l in ['Model, serial and purchase date', 'Receipt and warranty terms', 'Your photos and what happened'])
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  Icon(PhosphorIconsBold.check, size: 14, color: c.accent),
                  const SizedBox(width: 6),
                  Flexible(child: Text(l, style: TextStyle(color: c.textMuted, fontSize: 13.5))),
                ]),
              ),
          ],
        ),
        points: const [
          _Point(PhosphorIconsRegular.firstAidKit, 'Claim pack in a tap', 'All the proof in one PDF; you review and send it'),
          _Point(PhosphorIconsRegular.chatCircleText, 'Track every claim', 'Who you contacted, what they said, what happened'),
          _Point(PhosphorIconsRegular.trophy, 'See what you got back', 'Refunds, repairs and replacements add up in Outcomes'),
        ],
        note: "Warrantra isn't insurance and can't guarantee a claim.",
      ),
      // 4 · Privacy & plans
      _ObPage(
        step: 'Your data',
        title: 'Private, and free\nto start.',
        body: 'Your receipts stay in your account. Upgrade only if you need more.',
        fragment: _Fragment(
          children: [
            const _Plan('Free', '10 items · 100 MB · reminders · export · 3 AI receipt reads to try'),
            Divider(height: 18, color: c.divider),
            const _Plan('Pro', '500 items · 1 GB · 20 AI reads a month · full claim packs', accent: true),
          ],
        ),
        points: const [
          _Point(PhosphorIconsRegular.lockSimple, 'Private to your account', 'Documents are never shared or sold'),
          _Point(PhosphorIconsRegular.shieldCheck, 'AI only with your OK', 'Turn receipt reading on or off in Settings'),
          _Point(PhosphorIconsRegular.export, 'Export any time, free', 'Take your items and files with you'),
        ],
      ),
    ];
    final last = _i == pages.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
              child: Row(children: [
                const WLogo(size: 26),
                const SizedBox(width: 8),
                Text('Warrantra', style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                const Spacer(),
                if (!last) WButton.ghost('Skip', onPressed: _finish),
                if (last) const SizedBox(height: 44),
              ]),
            ),
            Expanded(
              child: PageView(controller: _page, onPageChanged: (i) => setState(() => _i = i), children: pages),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var d = 0; d < pages.length; d++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: d == _i ? 20 : 6,
                    height: 6,
                    decoration: BoxDecoration(color: d == _i ? c.accent : c.divider, borderRadius: BorderRadius.circular(3)),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: WButton(
                last ? 'Get started, free' : 'Next',
                onPressed: () => last ? _finish() : _page.nextPage(duration: const Duration(milliseconds: 280), curve: Curves.easeOut),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ObPage extends StatelessWidget {
  const _ObPage({required this.step, required this.title, required this.body, required this.fragment, required this.points, this.note});
  final String step, title, body;
  final String? note;
  final Widget fragment;
  final List<_Point> points;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(step.toUpperCase(), style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: c.accent)),
              const SizedBox(height: 6),
              Text(title, style: context.t.headlineMedium),
              const SizedBox(height: 8),
              Text(body, style: TextStyle(fontSize: 15, height: 1.45, color: c.textMuted)),
              const SizedBox(height: 18),
              fragment,
              const SizedBox(height: 18),
              ...points,
              if (note != null) Text(note!, style: TextStyle(fontSize: 12, color: c.textSubtle)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Point extends StatelessWidget {
  const _Point(this.icon, this.title, this.sub);
  final IconData icon;
  final String title, sub;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(icon, size: 34),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
            const SizedBox(height: 1),
            Text(sub, style: TextStyle(fontSize: 13, height: 1.35, color: c.textMuted)),
          ]),
        ),
      ]),
    );
  }
}

class _Fragment extends StatelessWidget {
  const _Fragment({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => WCard(
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
  );
}

/// A read-from-receipt field with its "found" check.
class _Field extends StatelessWidget {
  const _Field(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 56, child: Text(label, style: TextStyle(fontSize: 13, color: c.textSubtle))),
        Expanded(child: Text(value, style: TextStyle(fontWeight: FontWeight.w500, color: c.text))),
        Icon(PhosphorIconsBold.check, size: 14, color: c.accent),
      ]),
    );
  }
}

class _Plan extends StatelessWidget {
  const _Plan(this.name, this.detail, {this.accent = false});
  final String name, detail;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 52, child: WTag(name, kind: accent ? WTagKind.accent : WTagKind.outline)),
      const SizedBox(width: 10),
      Expanded(child: Text(detail, style: TextStyle(fontSize: 13, height: 1.4, color: c.textMuted))),
    ]);
  }
}

class _ObRow extends StatelessWidget {
  const _ObRow(this.title, this.sub, this.badge);
  final String title, sub;
  final Widget badge;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w500, color: context.w.text)),
              Text(sub, style: TextStyle(fontSize: 12.5, color: context.w.textMuted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        badge,
      ],
    ),
  );
}

// ---------------------------------------------------------------------------- sign in
bool get _appleAvailable => AppConfig.appleSignInEnabled && defaultTargetPlatform == TargetPlatform.iOS;
bool get _googleAvailable => AppConfig.googleServerClientId.isNotEmpty;

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
      // Closing the Google account picker isn't an error.
      if (mounted && !(e is Failure && e.code == 'cancelled')) showFailure(context, e);
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
        // Apple sign-in is native on iOS only; Google needs its client ID in env/dev.json.
        if (_appleAvailable) ...[
          WButton.secondary(
            'Continue with Apple',
            icon: PhosphorIconsFill.appleLogo,
            loading: _busy == 'apple',
            onPressed: _busy != null ? null : () => _run('apple', () => repo.signInWithProvider(SocialProvider.apple)),
          ),
          const SizedBox(height: 10),
        ],
        if (_googleAvailable)
          WButton.secondary(
            'Continue with Google',
            icon: PhosphorIconsBold.googleLogo,
            loading: _busy == 'google',
            onPressed: _busy != null ? null : () => _run('google', () => repo.signInWithProvider(SocialProvider.google)),
          ),
        if (_appleAvailable || _googleAvailable)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Row(
              children: [
                Expanded(child: Divider(color: c.divider)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('or with email', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
                ),
                Expanded(child: Divider(color: c.divider)),
              ],
            ),
          ),
        AutofillGroup(
          child: Column(
            children: [
              WField(
                label: 'Email',
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                textInputAction: TextInputAction.next,
              ),
              WField(label: 'Password', controller: _password, obscure: true, autofillHints: const [AutofillHints.password]),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: WButton.ghost('Forgot password?', onPressed: () => context.push('/forgot')),
        ),
        const SizedBox(height: 8),
        WButton(
          'Sign in',
          loading: _busy == 'email',
          onPressed: _busy != null
              ? null
              : () {
                  if (_email.text.trim().isEmpty || _password.text.isEmpty) {
                    showToast(context, 'Enter your email and password.');
                    return;
                  }
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim())) {
                    showToast(context, 'Enter a valid email address.');
                    return;
                  }
                  _run('email', () => repo.signIn(email: _email.text.trim(), password: _password.text));
                },
        ),
        const SizedBox(height: 14),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('New to Warrantra?', style: TextStyle(color: c.textMuted)),
            WButton.ghost('Create account', onPressed: () => context.push('/signup')),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Accounts are never merged just because two sign-in methods share an email.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: c.textSubtle),
        ),
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
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim()) || !_passwordOk) {
      showToast(context, 'Enter a valid email and a password of at least 10 characters.');
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await ref.read(authRepositoryProvider).signUp(email: _email.text.trim(), password: _password.text, displayName: _name.text.trim());
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
      return WScreen(
        children: [
          const SizedBox(height: 40),
          WEmpty(
            icon: PhosphorIconsRegular.envelopeSimple,
            title: 'Confirm your email',
            message: 'We sent a confirmation link to ${_email.text.trim()}. Open it, then sign in.',
            action: WButton.secondary('Back to sign in', onPressed: () => context.go('/signin'), expand: false),
          ),
        ],
      );
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
      return WScreen(
        children: [
          const SizedBox(height: 40),
          WEmpty(
            icon: PhosphorIconsRegular.envelopeSimple,
            title: 'Check your email',
            message: 'If an account uses ${_email.text.trim()}, a reset link is on its way. It expires in 1 hour.',
            action: WButton.secondary('Back to sign in', onPressed: () => context.go('/signin'), expand: false),
          ),
        ],
      );
    }
    return WScreen(
      children: [
        const WHeading('Reset password', subtitle: "We'll email a link to set a new password."),
        WField(label: 'Email', controller: _email, keyboardType: TextInputType.emailAddress),
        WButton(
          'Send reset link',
          loading: _busy,
          onPressed: () async {
            if (!_email.text.contains('@')) return showToast(context, 'Enter your email address.');
            setState(() => _busy = true);
            try {
              await ref.read(authRepositoryProvider).sendPasswordReset(_email.text.trim());
            } on Failure catch (f) {
              if (f.isOffline && mounted) return showFailure(context, f);
            } finally {
              if (mounted) setState(() => _busy = false);
            }
            if (mounted) setState(() => _sent = true);
          },
        ),
      ],
    );
  }
}

/// Link out helper for Terms/Privacy references.
const legalLinks = (terms: AppConfig.termsUrl, privacy: AppConfig.privacyUrl);
