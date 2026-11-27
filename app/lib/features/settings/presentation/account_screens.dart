import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../../core/errors/failure.dart';
import '../../account/presentation/account_providers.dart';
import '../../capture/presentation/add_sheet.dart';
import '../../auth/domain/auth_repository.dart';
import '../../auth/presentation/session_controller.dart';
import '../../home/domain/action_center.dart';
import '../../home/presentation/home_providers.dart';
import '../domain/settings.dart';
import 'settings_providers.dart';
import 'settings_screen.dart';

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});
  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  Timer? _poll;
  bool busy = false;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      ref.invalidate(exportsProvider);
      final list = await ref.read(exportsProvider.future);
      if (list.isEmpty || !list.first.busy) _poll?.cancel();
    });
  }

  Future<void> _start() async {
    setState(() => busy = true);
    try {
      await ref.read(settingsRepositoryProvider).requestExport();
      ref.invalidate(exportsProvider);
      _watch();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _download(ExportJob j) async {
    try {
      final links = await ref.read(settingsRepositoryProvider).exportLinks(j.id);
      if (links.dataUrl != null) await launchUrl(Uri.parse(links.dataUrl!), mode: LaunchMode.externalApplication);
      if (links.manifestUrl != null && mounted) {
        final more = await confirmDialog(context, title: 'Original files', message: 'Also open the list of links to your original documents? Those links expire.', confirm: 'Open');
        if (more) await launchUrl(Uri.parse(links.manifestUrl!), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final jobs = ref.watch(exportsProvider).value ?? const <ExportJob>[];
    final me = ref.watch(meProvider).value;
    final latest = jobs.isEmpty ? null : jobs.first;
    if (latest?.busy ?? false) {
      if (_poll == null || !_poll!.isActive) _watch();
    }
    Widget row(IconData i, Color tint, String t, String s) => Row(children: [
          WTintIcon(i, tint, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
              Text(s, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            ]),
          ),
          Icon(PhosphorIconsBold.check, size: 16, color: WTint.green),
        ]);
    return WScreen(
      title: 'Export your data',
      bottom: latest?.busy ?? false
          ? const WButton('Preparing your export…', loading: true)
          : latest?.ready ?? false
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  WButton('Download', icon: PhosphorIconsRegular.downloadSimple, onPressed: () => _download(latest!)),
                  const SizedBox(height: 6),
                  WButton.ghost('Prepare a new export', onPressed: _start),
                ])
              : WButton('Prepare export', loading: busy, onPressed: _start),
      children: [
        WHeroCard(
          eyebrow: 'Your data',
          title: 'Yours on every plan',
          icon: PhosphorIconsFill.export,
          children: [
            const SizedBox(height: 6),
            Text('Export works without paying, and still works after you cancel.', style: WHeroCard.muted()),
          ],
        ),
        const SizedBox(height: 22),
        const WSectionHeader("What's included"),
        WCard(
          child: Column(children: [
            row(PhosphorIconsRegular.fileText, WTint.violet, 'Items & coverage', 'Every item, warranty, return and registration · JSON'),
            Divider(height: 24, color: c.divider),
            row(PhosphorIconsRegular.fileZip, WTint.blue, 'Original documents', 'Download links · ${fmtBytes(me?.usage.storageUsed)}'),
            Divider(height: 24, color: c.divider),
            row(PhosphorIconsRegular.chatCircleText, WTint.coral, 'Claims & outcomes', 'Included in the JSON file'),
          ]),
        ),
        const SizedBox(height: 14),
        if (latest?.ready ?? false)
          WNote('Export ready${latest!.itemCount == null ? '' : ' · ${latest.itemCount} items, ${latest.fileCount ?? 0} files'}. Download links expire ${fmtDate(latest.expiresAt)}.', icon: PhosphorIconsRegular.checkCircle),
        if (latest?.state == 'failed') const WNote("The last export didn't finish. Try again; if it keeps failing, contact support.", icon: PhosphorIconsRegular.warningCircle),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Delete account
// ---------------------------------------------------------------------------
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  int step = 0;
  final typed = TextEditingController();
  bool busy = false;

  Future<void> _go() async {
    setState(() => busy = true);
    final repo = ref.read(settingsRepositoryProvider);
    Future<void> attempt() async {
      if (step == 0) {
        await repo.requestDeletion();
        setState(() => step = 1);
      } else if (step == 1) {
        await repo.confirmDeletion();
        setState(() => step = 2);
        ref.invalidate(deletionStatusProvider);
      }
    }

    try {
      try {
        await attempt();
      } on Failure catch (e) {
        // The server wants proof of a recent sign-in (spec §6). Ask for the
        // password, sign in again, then retry once.
        if (e.code != 'reauthentication_required' || !mounted) rethrow;
        if (!await _reauthenticate()) return;
        await attempt();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// Re-enter the password for the signed-in email. Returns true on success.
  Future<bool> _reauthenticate() async {
    final email = ref.read(meProvider).value?.profile.email ?? '';
    final pw = TextEditingController();
    final ok = await showWSheet<bool>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Confirm it’s you', style: ctx.t.titleLarge),
          const SizedBox(height: 6),
          Text('For your security, enter your password for $email to delete this account. '
              'If you use Apple or Google sign-in, sign out and sign back in instead.',
              style: TextStyle(fontSize: 14, height: 1.4, color: ctx.w.textMuted)),
          const SizedBox(height: 10),
          WField(label: 'Password', controller: pw, obscure: true),
          WButton('Continue', onPressed: () => Navigator.pop(ctx, true)),
        ]));
    if (ok != true || pw.text.isEmpty || !mounted) return false;
    try {
      await ref.read(authRepositoryProvider).signIn(email: email, password: pw.text);
      return true;
    } catch (e) {
      if (mounted) showFailure(context, e);
      return false;
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(settingsRepositoryProvider).cancelDeletion();
      ref.invalidate(meProvider);
      if (mounted) {
        showToast(context, 'Deletion cancelled. Your account is active again.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final status = ref.watch(deletionStatusProvider).value;
    final open = status?.where((s) => s.pending || s.running).firstOrNull;
    if (open != null && step == 0) step = open.pending ? 1 : 2;
    final me = ref.watch(meProvider).value;
    return WScreen(
      title: 'Delete account',
      bottom: switch (step) {
        0 => WButton.danger('Continue to delete', loading: busy, onPressed: _go),
        1 => Column(mainAxisSize: MainAxisSize.min, children: [
            WButton.danger('Delete my account', loading: busy, onPressed: typed.text.trim() == 'DELETE' ? _go : null),
            const SizedBox(height: 6),
            WButton.ghost('Keep my account', onPressed: _cancel),
          ]),
        _ => WButton.secondary('Sign out', onPressed: () => signOutEverywhere(context, ref)),
      },
      children: [
        if (step == 0) ...[
          Text('This deletes everything', style: context.t.titleLarge),
          const SizedBox(height: 6),
          Text("Items, coverage, reminders, claims, outcomes and every original file. It can't be undone.", style: TextStyle(color: c.textMuted, height: 1.45)),
          const SizedBox(height: 14),
          WListRow(icon: PhosphorIconsRegular.export, title: 'Export first', subtitle: 'Keep a copy of your receipts and records', onTap: () => context.push('/settings/export')),
          const SizedBox(height: 8),
          WNote("Deleting your account doesn't cancel an App Store or Play subscription. Cancel it in your store account.", icon: PhosphorIconsRegular.info),
        ],
        if (step == 1) ...[
          Text('Type DELETE to confirm', style: context.t.titleLarge),
          const SizedBox(height: 10),
          WField(label: 'Confirmation', controller: typed, hint: 'DELETE', onChanged: (_) => setState(() {})),
          Text('New uploads and scans have stopped. Cleanup runs until every file is verified gone.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
        ],
        if (step == 2) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text("We're deleting your account", textAlign: TextAlign.center, style: context.t.titleLarge),
          const SizedBox(height: 6),
          Text(
              "This keeps retrying until every file and record is removed. We'll email ${me?.profile.email ?? 'you'} when cleanup is verified. Restored backups won't bring it back.",
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, height: 1.45)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Annual summary
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Sign-in methods (link Google to an email account)
// ---------------------------------------------------------------------------
final _identitiesProvider = FutureProvider.autoDispose<List<String>>((ref) => ref.read(authRepositoryProvider).identities());

class SignInMethodsScreen extends ConsumerStatefulWidget {
  const SignInMethodsScreen({super.key});
  @override
  ConsumerState<SignInMethodsScreen> createState() => _SignInMethodsScreenState();
}

class _SignInMethodsScreenState extends ConsumerState<SignInMethodsScreen> {
  bool busy = false;

  Future<void> _addGoogle() async {
    final email = ref.read(meProvider).value?.profile.email ?? '';
    final repo = ref.read(authRepositoryProvider);
    setState(() => busy = true);
    try {
      try {
        await repo.linkProvider(SocialProvider.google, accountEmail: email);
      } on Failure catch (e) {
        // Adding a sign-in method needs a recent sign-in: confirm the password, retry once.
        if (e.code != 'reauthentication_required' || !mounted) rethrow;
        if (!await _confirmPassword(email)) return;
        await repo.linkProvider(SocialProvider.google, accountEmail: email);
      }
      ref.invalidate(_identitiesProvider);
      if (mounted) showToast(context, 'Google added. You can now sign in with either.');
    } on Failure catch (e) {
      if (e.code != 'cancelled' && mounted) showFailure(context, e);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> _confirmPassword(String email) async {
    final pw = TextEditingController();
    final ok = await showWSheet<bool>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Confirm it’s you', style: ctx.t.titleLarge),
          const SizedBox(height: 6),
          Text('Enter your password for $email to add a sign-in method.', style: TextStyle(fontSize: 14, height: 1.4, color: ctx.w.textMuted)),
          const SizedBox(height: 10),
          WField(label: 'Password', controller: pw, obscure: true),
          WButton('Continue', onPressed: () => Navigator.pop(ctx, true)),
        ]));
    if (ok != true || pw.text.isEmpty || !mounted) return false;
    try {
      await ref.read(authRepositoryProvider).signIn(email: email, password: pw.text);
      return true;
    } catch (e) {
      if (mounted) showFailure(context, e);
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final ids = ref.watch(_identitiesProvider);
    final email = ref.watch(meProvider).value?.profile.email ?? '';
    return WScreen(
      title: 'Sign-in methods',
      children: [
        Text('Ways to sign in to $email. Each one opens the same account.', style: TextStyle(color: c.textMuted, height: 1.45)),
        const SizedBox(height: 14),
        AsyncBody<List<String>>(
          value: ids,
          onRetry: () => ref.invalidate(_identitiesProvider),
          data: (list) => WGroup(children: [
            if (list.contains('email'))
              WListRow(icon: PhosphorIconsRegular.envelopeSimple, title: 'Email and password', caret: false, trailing: const WTag('Connected', kind: WTagKind.accent)),
            WListRow(
              icon: PhosphorIconsRegular.googleLogo,
              title: 'Google',
              subtitle: list.contains('google') ? null : 'Use the Google account for $email',
              caret: false,
              trailing: list.contains('google')
                  ? const WTag('Connected', kind: WTagKind.accent)
                  : AppConfig.googleServerClientId.isEmpty
                      ? const WTag('Not available', kind: WTagKind.outline)
                      : WButton.secondary('Add', expand: false, compact: true, loading: busy, onPressed: _addGoogle),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        const WNote('Accounts are never merged just because two sign-in methods share an email. Add Google here first, then "Continue with Google" opens this account.',
            icon: PhosphorIconsRegular.shieldCheck),
      ],
    );
  }
}

class AnnualScreen extends ConsumerWidget {
  const AnnualScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final year = DateTime.now().year;
    final s = ref.watch(annualProvider(year));
    return WScreen(title: 'Your $year', children: [
      AsyncBody<AnnualSummary>(
        value: s,
        onRetry: () => ref.invalidate(annualProvider(year)),
        data: (a) => _AnnualBody(year: year, a: a),
      ),
    ]);
  }
}

class _AnnualBody extends StatelessWidget {
  const _AnnualBody({required this.year, required this.a});
  final int year;
  final AnnualSummary a;

  static String _money(Map<String, num> m) => m.entries.map((e) => fmtMoney(e.value, currency: e.key)).join(' + ');

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final purchases = a.n('purchases_tracked');
    final value = a.money('purchase_value_tracked');
    final refunds = a.money('refunds_reported');
    final outcomes = a.outcomesByType;
    final stats = [
      (PhosphorIconsRegular.package, a.n('purchases_tracked'), 'purchase tracked', 'purchases tracked', const Color(0xFF7C6CE0)),
      (PhosphorIconsRegular.receipt, a.n('receipts_stored'), 'receipt kept', 'receipts kept', const Color(0xFF3FA7D6)),
      (PhosphorIconsRegular.arrowUUpLeft, a.n('returns_completed_before_deadline'), 'return on time', 'returns on time', const Color(0xFF2FB38A)),
      (PhosphorIconsRegular.clipboardText, a.n('registrations_completed'), 'registration done', 'registrations done', const Color(0xFFE0A33B)),
      (PhosphorIconsRegular.chatCircleText, a.n('claims_started'), 'claim started', 'claims started', const Color(0xFFE0716C)),
      (PhosphorIconsRegular.trophy, a.outcomesCount, 'outcome recorded', 'outcomes recorded', const Color(0xFFB36CE0)),
    ];
    final empty = stats.every((s) => s.$2 == 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Hero
      Container(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 22),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF7B67E3), Color(0xFF4B3CA8)]),
          boxShadow: [BoxShadow(color: const Color(0xFF4B3CA8).withValues(alpha: 0.35), blurRadius: 24, offset: const Offset(0, 10))],
        ),
        child: Stack(children: [
          Positioned(
            right: -6,
            top: -10,
            child: Text('$year', style: TextStyle(fontSize: 64, fontWeight: FontWeight.w800, height: 1, color: Colors.white.withValues(alpha: 0.12), letterSpacing: -2)),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(20)),
              child: Text('YEAR IN REVIEW', style: TextStyle(fontSize: 10.5, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: Colors.white.withValues(alpha: 0.95))),
            ),
            const SizedBox(height: 14),
            Text(empty ? 'Your $year starts here' : 'A year of keeping the proof',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: Colors.white, height: 1.2)),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$purchases', style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, color: Colors.white, height: 1)),
              const SizedBox(width: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(purchases == 1 ? 'purchase\nkept safe' : 'purchases\nkept safe',
                      style: TextStyle(fontSize: 13.5, height: 1.25, color: Colors.white.withValues(alpha: 0.85))),
                ),
              ),
            ]),
            if (value.isNotEmpty) ...[
              const SizedBox(height: 14),
              Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
              const SizedBox(height: 12),
              Row(children: [
                Icon(PhosphorIconsRegular.shieldCheck, size: 18, color: Colors.white.withValues(alpha: 0.9)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    TextSpan(text: _money(value), style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white)),
                    TextSpan(text: ' of purchases tracked', style: TextStyle(color: Colors.white.withValues(alpha: 0.8))),
                  ]), style: const TextStyle(fontSize: 14)),
                ),
              ]),
            ],
          ]),
        ]),
      ),
      const SizedBox(height: 22),

      if (empty) ...[
        WEmpty(
          icon: PhosphorIconsRegular.sparkle,
          title: 'Nothing tracked yet this year',
          message: 'Add a purchase and your returns, warranties and claims will start adding up here.',
          action: WButton('Add purchase', icon: PhosphorIconsRegular.plus, expand: false, onPressed: () => showAddSheet(context)),
        ),
      ] else ...[
        const WSectionHeader('Highlights'),
        // Rows of two that grow with the text (a fixed-ratio grid clips large text).
        for (var i = 0; i < stats.length; i += 2) ...[
          if (i > 0) const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (j, (icon, n, one, many, tint)) in stats.sublist(i, i + 2).indexed) ...[
                if (j > 0) const SizedBox(width: 10),
                Expanded(child: _StatTile(icon: icon, n: n, label: n == 1 ? one : many, tint: tint)),
              ],
            ]),
          ),
        ],
        const SizedBox(height: 22),
        const WSectionHeader('Outcomes'),
        WCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: const Color(0xFF2FB38A).withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
                child: const Icon(PhosphorIconsRegular.currencyCircleDollar, color: Color(0xFF2FB38A), size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(refunds.isEmpty ? 'No refunds recorded' : _money(refunds),
                      style: TextStyle(fontSize: refunds.isEmpty ? 15 : 22, fontWeight: FontWeight.w700, color: c.text)),
                  Text(refunds.isEmpty ? 'Record a refund when a return pays out' : 'Refunds you reported', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                ]),
              ),
            ]),
            if (outcomes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in outcomes.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: c.surfaceRaised, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.divider)),
                    child: Text('${e.value} · ${_outcomeName(e.key)}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: c.text)),
                  ),
              ]),
            ],
          ]),
        ),
      ],
      const SizedBox(height: 14),
      const WNote("Counts only what you recorded. Purchase value is what you tracked, not money saved.", icon: PhosphorIconsRegular.info),
    ]);
  }

  static String _outcomeName(String t) => switch (t) {
        'refund_received' => 'Refunded',
        'repair_completed' => 'Repaired',
        'replacement_received' => 'Replaced',
        'denied' => 'Denied',
        'withdrawn' => 'Withdrawn',
        _ => titleCase(t.replaceAll('_', ' ')),
      };
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.icon, required this.n, required this.label, required this.tint});
  final IconData icon;
  final int n;
  final String label;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final zero = n == 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.divider)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: tint.withValues(alpha: zero ? 0.08 : 0.16), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 18, color: zero ? tint.withValues(alpha: 0.5) : tint),
        ),
        const SizedBox(height: 14),
        Text(zero ? '–' : '$n', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.1, color: zero ? c.textSubtle : c.text)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Monthly digest (built from the Action Center)
// ---------------------------------------------------------------------------
class DigestScreen extends ConsumerWidget {
  const DigestScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final ac = ref.watch(actionCenterProvider);
    return WScreen(title: 'Monthly digest', children: [
      AsyncBody<ActionCenter>(
        value: ac,
        data: (a) {
          // Calendar order (the Action Center sorts by urgency instead).
          int byDate(ActionItem x, ActionItem y) => (x.dueDate ?? '9999').compareTo(y.dueDate ?? '9999');
          final month = a.actions.where((x) => (x.daysLeft ?? 999) <= 30).toList()..sort(byDate);
          final later = a.actions.where((x) => (x.daysLeft ?? 999) > 30 && (x.daysLeft ?? 999) <= 90).toList()..sort(byDate);
          Widget row(ActionItem x) {
            final d = parseDate(x.dueDate);
            final soon = (x.daysLeft ?? 999) <= 7;
            final tint = soon ? WTint.coral : WTint.violet;
            return WListRow(
              leading: Container(
                width: 46,
                constraints: const BoxConstraints(minHeight: 46),
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                child: Column(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text(d == null ? '' : const ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'][d.month - 1],
                      style: TextStyle(fontSize: 9.5, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: tint)),
                  Text(d == null ? '–' : '${d.day}', style: TextStyle(fontSize: 17, height: 1.1, fontWeight: FontWeight.w700, color: c.text)),
                ]),
              ),
              title: x.title,
              subtitle: x.itemName,
              onTap: x.itemId == null ? null : () => context.push('/items/${x.itemId}'),
            );
          }

          Widget count(String n, String label) => Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                  child: Column(children: [
                    Text(n, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                    Text(label, style: WHeroCard.muted(11.5)),
                  ]),
                ),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            WHeroCard(
              eyebrow: 'Monthly digest',
              title: month.isEmpty ? 'A quiet ${DateFormatName.month()}' : 'Your ${DateFormatName.month()}',
              watermark: DateFormatName.month().substring(0, 3).toUpperCase(),
              children: [
                const SizedBox(height: 14),
                Row(children: [
                  count('${month.length}', 'this month'),
                  const SizedBox(width: 8),
                  count('${later.length}', 'next 90 days'),
                  const SizedBox(width: 8),
                  count('${a.missing.length}', a.missing.length == 1 ? 'gap to fill' : 'gaps to fill'),
                ]),
              ],
            ),
            const SizedBox(height: 22),
            const WSectionHeader('This month'),
            if (month.isEmpty)
              const WNote('Nothing due in the next 30 days.', icon: PhosphorIconsRegular.checkCircle)
            else
              WGroup(children: month.map(row).toList()),
            if (later.isNotEmpty) ...[const SizedBox(height: 10), const WSectionHeader('Next 90 days'), WGroup(children: later.map(row).toList())],
            if (a.missing.isNotEmpty) ...[
              const SizedBox(height: 10),
              const WSectionHeader('Gaps to fill'),
              WGroup(children: [
                for (final m in a.missing)
                  WListRow(
                    leading: const WTintIcon(PhosphorIconsRegular.question, WTint.amber, size: 44),
                    title: m.title,
                    subtitle: m.itemName,
                    onTap: m.itemId == null ? null : () => context.push('/items/${m.itemId}'),
                  ),
              ]),
            ],
            const SizedBox(height: 12),
            Text('Once a month, nothing else. Turn it on or off in Reminders.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          ]);
        },
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});
  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  String topic = 'general';
  final message = TextEditingController();
  bool diag = true, busy = false;
  SupportTicket? sent;

  Future<String> _diagnostics() async {
    final p = await PackageInfo.fromPlatform();
    final d = DeviceInfoPlugin();
    String device = Platform.operatingSystem;
    if (Platform.isIOS) {
      final i = await d.iosInfo;
      device = '${i.utsname.machine} iOS ${i.systemVersion}';
    } else if (Platform.isAndroid) {
      final a = await d.androidInfo;
      device = '${a.model} Android ${a.version.release}';
    }
    return '\n\n— Diagnostics: app ${p.version} (${p.buildNumber}), $device';
  }

  Future<void> _send() async {
    if (message.text.trim().isEmpty) return showToast(context, 'Tell us what happened.');
    setState(() => busy = true);
    try {
      final body = message.text.trim() + (diag ? await _diagnostics() : '');
      final t = await ref.read(settingsRepositoryProvider).openTicket(subject: message.text.trim().split('\n').first.characters.take(80).toString(), category: topic, message: body);
      ref.invalidate(ticketsProvider);
      setState(() => sent = t);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    final tickets = ref.watch(ticketsProvider).value ?? const <SupportTicket>[];
    if (sent != null) {
      return WScreen(title: 'Help & support', bottom: WButton.secondary('Done', onPressed: () => context.pop()), children: [
        const SizedBox(height: 30),
        Center(child: Icon(PhosphorIconsFill.checkCircle, size: 56, color: c.accent)),
        const SizedBox(height: 12),
        Text('Message sent', textAlign: TextAlign.center, style: context.t.headlineSmall),
        const SizedBox(height: 6),
        Text("We'll reply to ${me?.profile.email ?? 'your email'}, usually within 2 business days.", textAlign: TextAlign.center, style: TextStyle(color: c.textMuted)),
      ]);
    }
    return WScreen(
      title: 'Help & support',
      bottom: WButton('Send to support', loading: busy, onPressed: _send),
      children: [
        Text('How can we help?', style: context.t.titleLarge),
        const SizedBox(height: 10),
        WChoiceChips<String>(
          options: const [('general', 'Question'), ('bug', 'Something broke'), ('reminders', 'Reminders'), ('billing', 'Billing'), ('claims', 'Claims'), ('privacy', 'Privacy'), ('data_export', 'Export')],
          value: topic,
          onChanged: (v) => setState(() => topic = v),
        ),
        const SizedBox(height: 12),
        WField(label: 'Message', controller: message, hint: 'What happened, and what did you expect?', maxLines: 5),
        WSwitchRow(title: 'Include diagnostics', subtitle: 'App version and device. Never receipts, serial numbers or documents.', value: diag, onChanged: (v) => setState(() => diag = v)),
        Wrap(spacing: 4, children: [
          WButton.ghost('Request deletion on the web', onPressed: () => launchUrl(Uri.parse(AppConfig.webDeletionUrl), mode: LaunchMode.externalApplication)),
          WButton.ghost('Email us', onPressed: () => launchUrl(Uri(scheme: 'mailto', path: AppConfig.supportEmail))),
        ]),
        if (tickets.isNotEmpty) ...[
          const WSectionHeader('Your messages'),
          for (final t in tickets) WListRow(icon: PhosphorIconsRegular.chatText, title: t.subject, subtitle: '${_ticketState(t.status)} · ${fmtDate(t.createdAt)}', caret: false),
        ],
      ],
    );
  }
}

String _ticketState(String s) => switch (s) {
      'open' => 'Open',
      'pending_user' => 'Waiting for your reply',
      'resolved' => 'Resolved',
      'closed' => 'Closed',
      _ => titleCase(s),
    };
