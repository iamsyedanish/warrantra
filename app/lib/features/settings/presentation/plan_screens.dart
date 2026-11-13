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
            Widget usage(String title, String line, double v, String note) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Text(title, style: TextStyle(fontWeight: FontWeight.w500, color: c.text)), const Spacer(), Text(line, style: TextStyle(color: c.textMuted))]),
                    const SizedBox(height: 6),
                    WProgressBar(v.clamp(0, 1).toDouble()),
                    const SizedBox(height: 4),
                    Text(note, style: TextStyle(fontSize: 12, color: c.textSubtle)),
                  ]),
                );
            double r(int a, int b) => b <= 0 ? 0 : a / b;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('Current plan', style: TextStyle(color: c.textMuted)),
              Text(p.name, style: context.t.headlineMedium),
              const SizedBox(height: 4),
              Text(status, style: TextStyle(color: c.textMuted, height: 1.4)),
              const SizedBox(height: 18),
              usage('Items', '${u.itemsUsed} of ${u.itemsLimit}', r(u.itemsUsed, u.itemsLimit), 'Returned and archived items count.'),
              usage('Storage', '${fmtBytes(u.storageUsed)} of ${fmtBytes(u.storageLimit)}', r(u.storageUsed, u.storageLimit), 'Each file counts once, however many items use it.'),
              usage('AI actions', '${u.aiUsed} of ${u.aiLimit}${u.aiPeriod == 'lifetime' ? ' (trial)' : ' this month'}', r(u.aiUsed, u.aiLimit),
                  "One action = one receipt up to 2 pages, or one claim letter. Failed actions don't count."),
              if (!p.isPro) WButton('See Pro', onPressed: () => context.push('/settings/paywall')),
              if (p.isPro)
                WButton.secondary(Platform.isIOS ? 'Manage in App Store' : 'Manage in Google Play', icon: PhosphorIconsRegular.arrowSquareOut,
                    onPressed: () => launchUrl(
                        Uri.parse(Platform.isIOS ? 'https://apps.apple.com/account/subscriptions' : 'https://play.google.com/store/account/subscriptions'),
                        mode: LaunchMode.externalApplication)),
              const SizedBox(height: 6),
              Center(child: WButton.ghost('Restore purchases', onPressed: () => _restore(context, ref))),
            ]);
          },
        ),
      ],
    );
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
        await ref.read(accountRepositoryProvider).restorePurchases();
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
    final monthlyLabel = monthly?.priceLabel ?? (offer?.monthlyPrice == null ? '\$19.99' : fmtMoney(offer!.monthlyPrice));
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
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
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
