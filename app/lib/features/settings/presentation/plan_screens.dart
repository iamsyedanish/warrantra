import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../domain/billing.dart';
import 'pro_unlocked.dart';
import 'settings_providers.dart';
import '../../guide/guide_spotlight.dart';

bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

Future<void> _restore(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(billingProvider).restore();
    await ref.read(accountRepositoryProvider).restorePurchases();
    ref.invalidate(meProvider);
    if (context.mounted) showToast(context, 'Purchases checked with the store');
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}

/// What Pro adds. Numbers mirror the live plan_limits rows (free / pro).
class ProBenefit {
  const ProBenefit(this.icon, this.tint, this.title, this.body, {this.free, this.soon = false});
  final IconData icon;
  final Color tint;
  final String title, body;
  final String? free; // what Free gets, shown for comparison
  final bool soon;
}

const proBenefits = <ProBenefit>[
  ProBenefit(PhosphorIconsRegular.package, WTint.violet, '500 items', 'Track everything you own: appliances, electronics, tools, furniture.', free: 'Free: 5 items'),
  ProBenefit(PhosphorIconsRegular.sparkle, WTint.orchid, '20 AI receipt reads every month',
      'Snap or upload a receipt and Warrantra fills in the store, date, items and prices for you to check.', free: 'Free: 3 reads to try'),
  ProBenefit(PhosphorIconsRegular.hardDrives, WTint.blue, '1 GB for your originals', 'Keep receipts, manuals and warranty documents as proof, safely stored.', free: 'Free: 20 MB'),
  ProBenefit(PhosphorIconsRegular.firstAidKit, WTint.coral, 'Full claim packs',
      'Receipt, coverage, photos and a timeline gathered into one PDF you can send to the store or maker.', free: 'Free: summary only'),
  ProBenefit(PhosphorIconsRegular.pencilLine, WTint.amber, 'AI-drafted claim letters', 'A clear, polite message for the retailer or manufacturer, ready for you to review and send.'),
  ProBenefit(PhosphorIconsRegular.usersThree, WTint.green, 'Household sharing', 'Share items with up to 6 people. Everyone gets their own reminders.'),
  ProBenefit(PhosphorIconsRegular.envelopeSimple, WTint.blue, 'Email forwarding', 'Forward e-receipts to your own Warrantra address and they land in your vault.', soon: !AppConfig.emailForwardingLive),
  ProBenefit(PhosphorIconsRegular.cloudSlash, WTint.violet, 'Offline access', 'Open your items, receipts and coverage details even without a connection.', soon: true),
];

class PlanScreen extends ConsumerWidget {
  const PlanScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider);
    return WScreen(
      title: 'Plan & usage',
      children: [
        AsyncBody(
          value: me,
          onRetry: () => ref.invalidate(meProvider),
          data: (m) {
            final p = m.plan, u = m.usage;
            final lapsed = !p.isPro && p.state == 'expired';
            final status = p.isPro
                ? (p.willNotRenew
                    ? 'Renewal off. Pro access continues until ${fmtDate(p.validUntil)}. Then Free limits apply; nothing is deleted.'
                    : 'Renews ${fmtDate(p.validUntil)} · confirmed by our server')
                : lapsed
                    ? 'Pro ended ${fmtDate(p.validUntil)}. Your items, files, export and reminders stay. Adding past ${u.itemsLimit} items and AI reads are paused.'
                    : 'Manual entry, reminders, originals and export are always included.';
            double r(int a, int b) => b <= 0 ? 0 : a / b;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              WHeroCard(
                eyebrow: 'Current plan',
                title: p.name,
                icon: p.isPro ? PhosphorIconsFill.crown : PhosphorIconsFill.leaf,
                children: [
                  const SizedBox(height: 6),
                  Text(status, style: WHeroCard.muted()),
                ],
              ),
              const SizedBox(height: 22),
              const GuideTarget(id: 'plan.usage', child: WSectionHeader('Usage')),
              WCard(
                child: Column(children: [
                  _UsageMeter(
                      icon: PhosphorIconsRegular.package,
                      tint: WTint.violet,
                      title: 'Items',
                      line: '${u.itemsUsed} of ${u.itemsLimit}',
                      value: r(u.itemsUsed, u.itemsLimit),
                      note: 'Returned and archived items count.'),
                  Divider(height: 26, color: c.divider),
                  _UsageMeter(
                      icon: PhosphorIconsRegular.hardDrives,
                      tint: WTint.blue,
                      title: 'Storage',
                      line: '${fmtBytes(u.storageUsed)} of ${fmtBytes(u.storageLimit)}',
                      value: r(u.storageUsed, u.storageLimit),
                      note: 'Each file counts once, however many items use it.'),
                  Divider(height: 26, color: c.divider),
                  _UsageMeter(
                      icon: PhosphorIconsRegular.sparkle,
                      tint: WTint.orchid,
                      title: 'AI reads',
                      line: '${u.aiUsed} of ${u.aiLimit}${u.aiPeriod == 'lifetime' ? ' trial' : ' this month'}',
                      value: r(u.aiUsed, u.aiLimit),
                      note: "One read = one receipt up to 2 pages, or one claim letter. Failed reads don't count."),
                ]),
              ),
              if (!p.isPro) ...[
                const SizedBox(height: 22),
                WCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const WTintIcon(PhosphorIconsFill.crown, WTint.amber, size: 36),
                      const SizedBox(width: 12),
                      Expanded(child: Text('More room with Pro', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text))),
                    ]),
                    const SizedBox(height: 12),
                    for (final b in proBenefits.where((b) => !b.soon).take(4))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Icon(PhosphorIconsBold.check, size: 15, color: c.accent),
                          const SizedBox(width: 10),
                          Expanded(child: Text(b.title, style: TextStyle(color: c.text))),
                        ]),
                      ),
                    const SizedBox(height: 6),
                    GuideTarget(id: 'plan.pro', child: WButton('See everything in Pro', onPressed: () => context.push('/settings/paywall'))),
                  ]),
                ),
              ],
              // Only a store subscription can be managed in the store (not promotional or gifted Pro).
              if (p.isPro && (p.store == 'play_store' || p.store == 'app_store')) ...[
                const SizedBox(height: 18),
                WButton.secondary(_isIOS ? 'Manage in App Store' : 'Manage in Google Play', icon: PhosphorIconsRegular.arrowSquareOut,
                    onPressed: () => launchUrl(
                        Uri.parse(_isIOS ? 'https://apps.apple.com/account/subscriptions' : 'https://play.google.com/store/account/subscriptions'),
                        mode: LaunchMode.externalApplication)),
              ],
              const SizedBox(height: 6),
              Center(child: WButton.ghost('Restore purchases', onPressed: () => _restore(context, ref))),
            ]);
          },
        ),
      ],
    );
  }
}

class _UsageMeter extends StatelessWidget {
  const _UsageMeter({required this.icon, required this.tint, required this.title, required this.line, required this.value, required this.note});
  final IconData icon;
  final Color tint;
  final String title, line, note;
  final double value;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final v = value.clamp(0, 1).toDouble();
    // Amber when close to the limit, red at it.
    final bar = v >= 1 ? c.danger : v >= 0.8 ? WTint.amber : tint;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      WTintIcon(icon, tint, size: 36),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(flex: 2, child: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text))),
            const SizedBox(width: 8),
            // Takes its share of the row and right-aligns; wraps instead of overflowing with large text.
            Expanded(
              flex: 3,
              child: Text(line, textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w500, color: v >= 1 ? c.danger : c.textMuted)),
            ),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(children: [
              Container(height: 8, color: tint.withValues(alpha: 0.14)),
              FractionallySizedBox(widthFactor: v, child: Container(height: 8, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(6)))),
            ]),
          ),
          const SizedBox(height: 6),
          Text(note, style: TextStyle(fontSize: 12, height: 1.35, color: c.textSubtle)),
        ]),
      ),
    ]);
  }
}

final _packagesProvider = FutureProvider.autoDispose<List<StorePackage>>((ref) async {
  final me = await ref.watch(meProvider.future);
  final billing = ref.watch(billingProvider);
  await billing.identify(me.profile.id);
  final offer = await ref.watch(offerProvider.future);
  return billing.packages(offering: offer.offering);
});

class PaywallScreen extends ConsumerStatefulWidget {
  const PaywallScreen({super.key});
  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  String period = 'annual';
  bool busy = false;

  Future<void> _buy(List<StorePackage> pkgs) async {
    final billing = ref.read(billingProvider);
    final pkg = pkgs.where((p) => p.period == period).firstOrNull;
    if (!billing.available || pkg == null) {
      showToast(context, "In-app purchase isn't set up in this build yet.");
      return;
    }
    setState(() => busy = true);
    try {
      final offer = ref.read(offerProvider).value;
      final r = await billing.buy(pkg.id, offering: offer?.offering);
      if (r == PurchaseOutcome.purchased) {
        // The purchase was already verified by the server before it completed.
        ref.invalidate(meProvider);
        if (mounted) {
          final router = GoRouter.of(context);
          await showProUnlocked(context, period: period);
          if (router.canPop()) router.pop();
        }
      }
    } on Failure catch (e) {
      if (!mounted) return;
      if (e.code == 'purchase_owned_by_other_account' || e.code == 'already_subscribed') {
        await _explainAlreadySubscribed(e);
      } else {
        showFailure(context, e);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// One Google Play account can hold one Warrantra subscription, used by the
  /// Warrantra account it was bought for. Explain the ways forward.
  Future<void> _explainAlreadySubscribed(Failure e) {
    final hint = e.details?['owner_email_hint'] as String?;
    return showWSheet<void>(context, builder: (ctx) {
      final c = ctx.w;
      Widget option(IconData icon, String title, String body) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              WTintIcon(icon, WTint.violet, size: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                  const SizedBox(height: 2),
                  Text(body, style: TextStyle(fontSize: 13, height: 1.4, color: c.textMuted)),
                ]),
              ),
            ]),
          );
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Pro is already on this Google Play account', style: ctx.t.titleLarge),
        const SizedBox(height: 8),
        Text(
          hint != null
              ? 'Your Google Play account already pays for Warrantra Pro, and it’s linked to $hint. A subscription can only be used by one Warrantra account.'
              : 'Your Google Play account already has a Warrantra subscription, linked to a different Warrantra account. A subscription can only be used by one Warrantra account.',
          style: TextStyle(fontSize: 14, height: 1.45, color: c.textMuted),
        ),
        const SizedBox(height: 16),
        option(PhosphorIconsRegular.userSwitch, 'Use that account', 'Sign out and sign in as ${hint ?? 'the account that bought Pro'} to use Pro there.'),
        option(PhosphorIconsRegular.xCircle, 'Move Pro to this account',
            'Cancel the subscription in Google Play. When it ends, you can subscribe here.'),
        option(PhosphorIconsRegular.googleLogo, 'Use another Google account', 'Switch the Google account in the Play Store, then subscribe here.'),
        const SizedBox(height: 4),
        WButton.secondary('Open Google Play subscriptions', icon: PhosphorIconsRegular.arrowSquareOut,
            onPressed: () => launchUrl(Uri.parse('https://play.google.com/store/account/subscriptions'), mode: LaunchMode.externalApplication)),
        const SizedBox(height: 4),
        WButton.ghost('OK', onPressed: () => Navigator.pop(ctx)),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final offer = ref.watch(offerProvider).value;
    final pkgs = ref.watch(_packagesProvider).value ?? const <StorePackage>[];
    final annual = pkgs.where((p) => p.period == 'annual').firstOrNull;
    final monthly = pkgs.where((p) => p.period == 'monthly').firstOrNull;
    final annualLabel = annual?.priceLabel ?? (offer?.annualPrice == null ? '\$79.99' : fmtMoney(offer!.annualPrice));
    final perMonth = annual?.pricePerMonthLabel ?? (offer?.annualPrice == null ? '\$6.67' : fmtMoney(offer!.annualPrice! / 12));
    final monthlyLabel = monthly?.priceLabel ?? (offer?.monthlyPrice == null ? '\$7.99' : fmtMoney(offer!.monthlyPrice));
    return WScreen(
      close: true,
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [
        WButton(period == 'annual' ? 'Start Pro · $annualLabel/year' : 'Start Pro · $monthlyLabel/month', loading: busy, onPressed: () => _buy(pkgs)),
        Wrap(alignment: WrapAlignment.center, children: [
          WButton.ghost('Restore', onPressed: () => _restore(context, ref)),
          WButton.ghost('Terms', onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication)),
          WButton.ghost('Privacy', onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication)),
        ]),
      ]),
      children: [
        WHeroCard(
          eyebrow: 'Warrantra Pro',
          title: 'Be ready when something breaks',
          icon: PhosphorIconsFill.crown,
          children: [
            const SizedBox(height: 6),
            Text('More room, AI that does the typing, and claim packs that make a return or repair easier to sort out.', style: WHeroCard.muted()),
          ],
        ),
        const SizedBox(height: 22),
        const WSectionHeader('What you get'),
        for (final b in proBenefits) ...[_BenefitCard(b), const SizedBox(height: 10)],
        const SizedBox(height: 12),
        const WSectionHeader('Free vs Pro'),
        const _CompareTable(),
        const SizedBox(height: 18),
        WCard(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const WTintIcon(PhosphorIconsRegular.heart, WTint.green, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Always free, on every plan', style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                const SizedBox(height: 4),
                Text('Reminders before deadlines, your original files, export, and adding items by hand. If Pro ends, nothing is deleted.',
                    style: TextStyle(fontSize: 13, height: 1.4, color: c.textMuted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 22),
        const WSectionHeader('Choose your plan'),
        const SizedBox(height: 4),
        WCheckRow(radio: true, value: period == 'annual', onChanged: (_) => setState(() => period = 'annual'), title: 'Annual · $annualLabel', subtitle: '$perMonth/month, billed yearly', trailing: const WTag('Best value', kind: WTagKind.accent)),
        WCheckRow(radio: true, value: period == 'monthly', onChanged: (_) => setState(() => period = 'monthly'), title: 'Monthly · $monthlyLabel', subtitle: 'Cancel any time'),
        const SizedBox(height: 10),
        Text(
            'Billed through the ${_isIOS ? 'App Store' : 'Play Store'}. Cancelling stops renewal; Pro lasts until the period ends. Free always keeps manual entry, reminders, your original files and export. Warrantra isn\'t insurance and can\'t guarantee a claim.',
            style: TextStyle(fontSize: 12, color: c.textSubtle, height: 1.45)),
      ],
    );
  }
}

class _BenefitCard extends StatelessWidget {
  const _BenefitCard(this.b);
  final ProBenefit b;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.divider)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        WTintIcon(b.icon, b.tint, size: 40, muted: b.soon),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(b.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: b.soon ? c.textMuted : c.text)),
              if (b.soon) const WTag('Coming soon', kind: WTagKind.outline),
            ]),
            const SizedBox(height: 3),
            Text(b.body, style: TextStyle(fontSize: 13, height: 1.4, color: c.textMuted)),
            if (b.free != null) ...[
              const SizedBox(height: 6),
              Text(b.free!, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.textSubtle)),
            ],
          ]),
        ),
      ]),
    );
  }
}

/// Side-by-side limits. Numbers mirror the live plan_limits rows.
class _CompareTable extends StatelessWidget {
  const _CompareTable();
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    const rows = <(String, String, String)>[
      ('Items', '5', '500'),
      ('Storage for originals', '20 MB', '1 GB'),
      ('AI receipt reads', '3 to try', '20 / month'),
      ('Claim packs', 'Summary', 'Full PDF'),
      ('AI claim letters', '–', '✓'),
      ('Household sharing', '–', '6 people'),
      ('Reminders & export', '✓', '✓'),
      ('Offline access', '–', 'Soon'),
    ];
    TextStyle head(bool pro) => TextStyle(fontSize: 12, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: pro ? c.accent : c.textSubtle);
    return Container(
      decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: c.divider)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Row(children: [
            const Expanded(flex: 5, child: SizedBox()),
            Expanded(flex: 3, child: Text('FREE', textAlign: TextAlign.center, style: head(false))),
            Expanded(flex: 3, child: Text('PRO', textAlign: TextAlign.center, style: head(true))),
          ]),
        ),
        for (final (i, (label, free, pro)) in rows.indexed)
          Container(
            color: i.isEven ? c.surfaceRaised.withValues(alpha: 0.6) : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(children: [
              Expanded(flex: 5, child: Text(label, style: TextStyle(fontSize: 13.5, color: c.text))),
              Expanded(flex: 3, child: Text(free, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, color: c.textMuted))),
              Expanded(
                flex: 3,
                child: Text(pro, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: pro == 'Soon' ? c.textMuted : c.accent)),
              ),
            ]),
          ),
      ]),
    );
  }
}
