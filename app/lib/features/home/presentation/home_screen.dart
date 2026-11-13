import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';
import '../../capture/presentation/add_sheet.dart';
import '../../items/presentation/item_ui.dart';
import '../../items/presentation/items_providers.dart';
import '../domain/action_center.dart';
import 'home_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final ac = ref.watch(actionCenterProvider);
    final me = ref.watch(meProvider).value;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(actionCenterProvider);
            ref.invalidate(recentItemsProvider);
            ref.invalidate(meProvider);
            await ref.read(actionCenterProvider.future);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 110), children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(fmtToday(), style: TextStyle(fontSize: 13, color: c.textMuted)),
                  const SizedBox(height: 2),
                  Text('Action Center', style: context.t.headlineMedium),
                ]),
              ),
              InkWell(
                customBorder: const CircleBorder(),
                onTap: () => context.go('/settings'),
                child: WAvatar(me?.profile.name ?? '', size: 40),
              ),
            ]),
            const SizedBox(height: 14),
            if (me != null) ..._banners(context, me),
            AsyncBody<ActionCenter>(
              value: ac,
              onRetry: () => ref.invalidate(actionCenterProvider),
              data: (a) => a.empty ? const _EmptyHome() : _FullHome(center: a),
            ),
          ]),
        ),
      ),
    );
  }

  List<Widget> _banners(BuildContext context, Me me) {
    final out = <Widget>[];
    void add(String title, String body, VoidCallback onTap, {IconData? icon}) => out.add(Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: WCard(
            color: context.w.accentSoft,
            border: false,
            onTap: onTap,
            child: Row(children: [
              Icon(icon ?? PhosphorIconsRegular.info, color: context.w.accentSoftText),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: context.w.accentSoftText)),
                  Text(body, style: TextStyle(fontSize: 13, height: 1.4, color: context.w.accentSoftText)),
                ]),
              ),
            ]),
          ),
        ));
    if (me.plan.isPro && me.plan.willNotRenew && me.plan.validUntil != null) {
      add('Pro until ${fmtDate(me.plan.validUntil)}', 'Renewal is off. After that, Free limits apply; nothing is deleted.', () => context.push('/settings/plan'));
    } else if (!me.plan.isPro && me.usage.additionsPaused) {
      add("You've reached ${me.usage.itemsLimit} items on Free", 'Everything stays viewable, exportable and reminded. Go Pro to add more.', () => context.push('/settings/paywall'));
    }
    final hint = me.timezoneHint;
    if (hint != null) {
      add('Reminder time zone', hint.message, () => context.push('/settings/reminders'), icon: PhosphorIconsRegular.globe);
    }
    if (me.profile.aiSuspended) {
      add('AI reading is paused on this account', 'Manual entry and your records work as normal. Contact support if this is a mistake.', () => context.push('/settings/support'),
          icon: PhosphorIconsRegular.pauseCircle);
    }
    return out;
  }
}

class _EmptyHome extends StatelessWidget {
  const _EmptyHome();
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      WEmpty(
        icon: PhosphorIconsRegular.receipt,
        title: 'Protect your first purchase',
        message: 'Add something you own and Warrantra will keep its receipt, coverage and deadlines together.',
        action: WButton('Add purchase', icon: PhosphorIconsRegular.plus, onPressed: () => showAddSheet(context), expand: false),
      ),
      WCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Good first items', style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
          const SizedBox(height: 4),
          Text("Anything still inside a return window, a recent appliance, or the laptop you'd most hate to replace.",
              style: TextStyle(fontSize: 13.5, height: 1.45, color: c.textMuted)),
        ]),
      ),
    ]);
  }
}

class _FullHome extends ConsumerWidget {
  const _FullHome({required this.center});
  final ActionCenter center;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final attention = center.actions.where((a) => a.overdue || (a.daysLeft ?? 99) <= 14).toList();
    final upcoming = center.actions.where((a) => !attention.contains(a)).take(6).toList();
    final recent = ref.watch(recentItemsProvider).value ?? const [];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(center.title, style: TextStyle(fontSize: 15, color: c.textMuted)),
      const SizedBox(height: 10),
      if (center.caughtUp)
        WCard(
          child: Row(children: [
            Icon(PhosphorIconsRegular.checkCircle, color: c.accent),
            const SizedBox(width: 10),
            Expanded(child: Text(center.message ?? 'No returns, registrations or coverage need attention right now.', style: TextStyle(color: c.textMuted))),
          ]),
        ),
      for (final a in attention) Padding(padding: const EdgeInsets.only(bottom: 10), child: _ActionCard(a)),
      if (upcoming.isNotEmpty) ...[
        const WSectionHeader('Coming up'),
        WCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(children: [
            for (final u in upcoming)
              InkWell(
                onTap: () => _open(context, u),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(children: [
                    SizedBox(
                      width: 44,
                      child: Column(children: [
                        Text(parseDate(u.dueDate) == null ? '' : fmtMonth(parseDate(u.dueDate)!), style: TextStyle(fontSize: 10.5, letterSpacing: 1, color: c.textSubtle)),
                        Text('${parseDate(u.dueDate)?.day ?? ''}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text)),
                      ]),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(u.title, style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
                        Text(u.itemName, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                      ]),
                    ),
                    if (u.certainty == 'estimated') const CertBadge('estimated'),
                  ]),
                ),
              ),
          ]),
        ),
      ],
      if (center.missing.isNotEmpty) ...[
        const WSectionHeader('Missing info'),
        for (final m in center.missing.take(4)) Padding(padding: const EdgeInsets.only(bottom: 10), child: _ActionCard(m)),
      ],
      if (recent.isNotEmpty) ...[
        WSectionHeader('Recent purchases', action: 'All items', actionIcon: PhosphorIconsRegular.list, onAction: () => context.go('/items')),
        for (final it in recent.take(4))
          WListRow(
            icon: itemIcon(category: it.categorySlug, name: it.name),
            title: it.name,
            subtitle: [it.retailer, if (it.purchaseDate != null) fmtDate(it.purchaseDate)].whereType<String>().join(' · '),
            onTap: () => context.push('/items/${it.id}'),
          ),
      ],
    ]);
  }
}

void _open(BuildContext context, ActionItem a) {
  if (a.itemId == null) {
    if (a.kind == 'claim_follow_up' && a.sourceId != null) context.push('/claims/${a.sourceId}');
    return;
  }
  switch (a.kind) {
    case 'return_deadline':
      context.push('/items/${a.itemId}/return/${a.sourceId}');
    case 'registration_deadline':
      context.push('/items/${a.itemId}/registration/${a.sourceId}');
    case 'claim_follow_up':
      context.push('/claims/${a.sourceId}');
    default:
      context.push('/items/${a.itemId}');
  }
}

String _due(ActionItem a) {
  final d = a.daysLeft;
  if (d == null || !a.urgent) return '';
  if (d < 0) return ' · OVERDUE';
  if (d == 0) return ' · DUE TODAY';
  if (d == 1) return ' · DUE TOMORROW';
  return ' · ${d}D LEFT';
}

class _ActionCard extends StatelessWidget {
  const _ActionCard(this.a);
  final ActionItem a;

  (String, IconData) get kindInfo => switch (a.kind) {
        'return_deadline' => ('Return', PhosphorIconsRegular.arrowUUpLeft),
        'registration_deadline' => ('Registration', PhosphorIconsRegular.clipboardText),
        'coverage_ending' => ('Coverage', PhosphorIconsRegular.shieldCheck),
        'claim_follow_up' => ('Claim', PhosphorIconsRegular.chatCircleText),
        'maintenance_due' => ('Maintenance', PhosphorIconsRegular.wrench),
        'missing_receipt' => ('Missing info', PhosphorIconsRegular.receipt),
        'missing_coverage' || 'missing_information' => ('Missing info', PhosphorIconsRegular.question),
        _ => ('Action', PhosphorIconsRegular.info),
      };

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final (kind, icon) = kindInfo;
    return WCard(
      onTap: () => _open(context, a),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(icon, emphasis: a.urgent),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text('${kind.toUpperCase()}${_due(a)}',
                    style: TextStyle(fontSize: 10.5, letterSpacing: 1, fontWeight: FontWeight.w600, color: a.urgent ? c.accent : c.textSubtle)),
              ),
              if (a.certainty == 'estimated') ...[const SizedBox(width: 6), const CertBadge('estimated')],
            ]),
            const SizedBox(height: 2),
            Text(a.title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text)),
            Text(a.itemName, style: TextStyle(fontSize: 13, color: c.textMuted)),
            if (a.detail != null || a.dueDate != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text([if (a.dueDate != null) fmtDayShort(a.dueDate), ?a.detail].join(' · '), style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textSubtle)),
              ),
          ]),
        ),
        Padding(padding: const EdgeInsets.only(top: 10), child: Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle)),
      ]),
    );
  }
}
