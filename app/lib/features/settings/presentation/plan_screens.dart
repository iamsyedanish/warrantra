import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../domain/billing.dart';
import 'settings_providers.dart';

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
              const WSectionHeader('Usage'),
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
                    for (final b in const ['Far more items and storage', 'More AI receipt reads every month', 'Household sharing'])
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Icon(PhosphorIconsBold.check, size: 15, color: c.accent),
                          const SizedBox(width: 10),
                          Expanded(child: Text(b, style: TextStyle(color: c.text))),
                        ]),
                      ),
                    const SizedBox(height: 6),
                    WButton('See Pro', onPressed: () => context.push('/settings/paywall')),
                  ]),
                ),
              ],
              // Only a store subscription can be managed in the store (not promotional or gifted Pro).
              if (p.isPro && (p.store == 'play_store' || p.store == 'app_store')) ...[
                const SizedBox(height: 18),
                WButton.secondary(Platform.isIOS ? 'Manage in App Store' : 'Manage in Google Play', icon: PhosphorIconsRegular.arrowSquareOut,
                    onPressed: () => launchUrl(
                        Uri.parse(Platform.isIOS ? 'https://apps.apple.com/account/subscriptions' : 'https://play.google.com/store/account/subscriptions'),
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
            Expanded(child: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text))),
            const SizedBox(width: 8),
            Flexible(
              flex: 2,
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
          showToast(context, 'Welcome to Pro');
          context.pop();
        }
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
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
    Widget feature(IconData i, String t, String s) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconTile(i, emphasis: true),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                Text(s, style: TextStyle(fontSize: 13, color: c.textMuted)),
              ]),
            ),
          ]),
        );
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
        const Center(child: WTag('Warrantra Pro', kind: WTagKind.accent, icon: PhosphorIconsRegular.sealCheck)),
        const SizedBox(height: 10),
        Text('Be ready when something breaks', textAlign: TextAlign.center, style: context.t.headlineSmall),
        const SizedBox(height: 20),
        feature(PhosphorIconsRegular.receipt, '20 AI receipt reads a month', 'Multi-item receipts split into lines you choose'),
        feature(PhosphorIconsRegular.firstAidKit, 'Full claim packs', 'Evidence assembled into a PDF, optional AI wording'),
        feature(PhosphorIconsRegular.stack, '500 items · 1 GB of originals', 'Free: 10 items · 100 MB'),
        const SizedBox(height: 4),
        WCheckRow(radio: true, value: period == 'annual', onChanged: (_) => setState(() => period = 'annual'), title: 'Annual · $annualLabel', subtitle: '$perMonth/month, billed yearly', trailing: const WTag('Best value', kind: WTagKind.accent)),
        WCheckRow(radio: true, value: period == 'monthly', onChanged: (_) => setState(() => period = 'monthly'), title: 'Monthly · $monthlyLabel', subtitle: 'Cancel any time'),
        const SizedBox(height: 10),
        Text(
            'Billed through the ${Platform.isIOS ? 'App Store' : 'Play Store'}. Cancelling stops renewal; Pro lasts until the period ends. Free always keeps manual entry, reminders, your original files and export. Warrantra isn\'t insurance and can\'t guarantee a claim.',
            style: TextStyle(fontSize: 12, color: c.textSubtle, height: 1.45)),
      ],
    );
  }
}
