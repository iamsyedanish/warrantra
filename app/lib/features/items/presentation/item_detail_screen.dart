import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../capture/presentation/upload_flow.dart';
import '../domain/items.dart';
import 'item_ui.dart';
import 'items_providers.dart';

class ItemDetailScreen extends ConsumerWidget {
  const ItemDetailScreen({super.key, required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(itemDetailProvider(itemId));
    return WScreen(
      title: 'Item',
      actions: [
        if (detail.hasValue) _ItemMenu(item: detail.value!),
      ],
      children: [
        AsyncBody<ItemDetail>(
          value: detail,
          onRetry: () => ref.invalidate(itemDetailProvider(itemId)),
          data: (d) => _Body(d),
        ),
      ],
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body(this.d);
  final ItemDetail d;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final s = d.summary;
    final activeReturns = d.returns.where((r) => !r.dismissed && !['refunded', 'cancelled', 'rejected'].contains(r.state)).toList();
    final pendingRegs = d.registrations.where((g) => !g.done && g.status != 'not_applicable' && g.status != 'dismissed').toList();
    final sub = [s.brand, s.model].whereType<String>().where((x) => x.isNotEmpty).join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconTile(itemIcon(category: s.categorySlug, name: s.name), size: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: context.t.headlineSmall),
            if (sub.isNotEmpty) Text(sub, style: TextStyle(color: c.textMuted)),
          ]),
        ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (s.lifecycle != 'owned') WTag(lifecycleLabels[s.lifecycle] ?? s.lifecycle, kind: WTagKind.outline),
        if (s.archived) const WTag('Archived', kind: WTagKind.outline),
        if (s.hasReceipt) const WTag('Receipt saved', icon: PhosphorIconsRegular.receipt) else const WTag('No receipt', kind: WTagKind.outline),
        if (s.price != null) WTag('${fmtMoney(s.price, currency: s.currency)}${d.priceIsEstimated ? ' (est.)' : ''}'),
      ]),
      const SizedBox(height: 6),

      // ---- Return windows
      for (final r in activeReturns) ...[
        const WSectionHeader('Return window'),
        _ReturnCard(itemId: s.id, r: r),
      ],

      // ---- Coverage
      WSectionHeader('Coverage', action: 'Add', actionIcon: PhosphorIconsRegular.plus, onAction: () => context.push('/items/${s.id}/coverage/new')),
      if (d.warranties.isEmpty)
        _SuggestionsOrEmpty(itemId: s.id)
      else
        for (final w in d.warranties) Padding(padding: const EdgeInsets.only(bottom: 8), child: _WarrantyCard(itemId: s.id, w: w)),

      // ---- Registration
      if (d.registrations.isNotEmpty || pendingRegs.isNotEmpty) ...[
        const WSectionHeader('Registration'),
        for (final g in d.registrations)
          WListRow(
            icon: g.done ? PhosphorIconsRegular.checkCircle : PhosphorIconsRegular.clipboardText,
            title: g.done ? 'Registered${g.provider == null ? '' : ' with ${g.provider}'}' : 'Register${g.provider == null ? '' : ' with ${g.provider}'}',
            subtitle: g.done
                ? 'Marked done ${fmtDate(g.completedAt)}'
                : g.deadline == null
                    ? (g.requirement == 'terms_stated_required' ? 'Terms say registration is required' : 'Optional')
                    : 'By ${fmtDate(g.deadline)}',
            trailing: g.done ? null : CertBadge(g.certainty),
            onTap: () => context.push('/items/${s.id}/registration/${g.id}'),
          ),
      ] else
        WListRow(
          icon: PhosphorIconsRegular.clipboardText,
          title: 'Add a registration reminder',
          subtitle: 'Some brands extend coverage when you register',
          onTap: () => context.push('/items/${s.id}/registration/new'),
          dense: true,
        ),
      if (d.returns.isEmpty)
        WListRow(
          icon: PhosphorIconsRegular.arrowUUpLeft,
          title: 'Add a return window',
          subtitle: 'Track the last day to return this item',
          onTap: () => context.push('/items/${s.id}/return/new'),
          dense: true,
        ),

      // ---- Documents
      WSectionHeader('Documents', action: 'Add', actionIcon: PhosphorIconsRegular.plus, onAction: () => addDocumentToItem(context, ref, s.id)),
      if (d.documents.isEmpty)
        WNote('No documents yet. Add the receipt, warranty card or manual so they are ready if something goes wrong.', icon: PhosphorIconsRegular.fileDashed)
      else
        for (final doc in d.documents)
          WListRow(
            icon: docIcon(doc.fileType, doc.mime),
            title: doc.filename ?? titleCase(doc.fileType),
            subtitle: [titleCase(doc.role), if (doc.pages != null) '${doc.pages} page${doc.pages == 1 ? '' : 's'}', if (doc.state == 'quarantined') 'Held for review']
                .join(' · '),
            onTap: () => context.push('/vault/${doc.attachmentId}'),
          ),

      // ---- Claims
      WSectionHeader('Claims & returns', action: 'Start', actionIcon: PhosphorIconsRegular.plus, onAction: () => context.push('/claims/new?item=${s.id}')),
      if (d.claims.isEmpty)
        WNote('If something goes wrong, Warrantra assembles the facts and documents into a claim package you send yourself.', icon: PhosphorIconsRegular.lifebuoy)
      else
        for (final cl in d.claims)
          WListRow(
            icon: PhosphorIconsRegular.chatCircleText,
            title: claimKindLabel(cl.kind),
            subtitle: [claimStatusLabel(cl.status), if (cl.provider != null) cl.provider!].join(' · '),
            onTap: () => context.push('/claims/${cl.id}'),
          ),

      // ---- Details
      const WSectionHeader('Details'),
      WCard(
        child: Column(children: [
          WKeyValue('Purchased', fmtDate(s.purchaseDate, empty: 'Unknown')),
          if (d.deliveryDate != null) WKeyValue('Delivered', fmtDate(d.deliveryDate)),
          WKeyValue('Store', s.retailer ?? 'Unknown'),
          if (d.orderNumber != null) WKeyValue('Order number', d.orderNumber!),
          if (s.model != null) WKeyValue('Model', s.model!),
          WKeyValue('Serial number', d.serial ?? 'Not recorded'),
          if (d.quantity > 1) WKeyValue('Quantity', '${d.quantity}'),
          WKeyValue('Condition', titleCase(d.condition)),
          if (d.notes != null && d.notes!.isNotEmpty) WKeyValue('Notes', d.notes!),
        ]),
      ),
      const SizedBox(height: 8),
      WListRow(icon: PhosphorIconsRegular.wrench, title: 'Service & maintenance', subtitle: 'Repairs, servicing and recurring tasks', onTap: () => context.push('/maintenance?item=${s.id}'), dense: true),

      // ---- Timeline
      if (d.timeline.isNotEmpty) ...[
        const WSectionHeader('Timeline'),
        WCard(
          child: Column(children: [
            for (final (i, t) in d.timeline.indexed)
              Padding(
                padding: EdgeInsets.only(bottom: i == d.timeline.length - 1 ? 0 : 12),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(margin: const EdgeInsets.only(top: 5), width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.label, style: TextStyle(color: c.text))),
                  Text(fmtDate(t.date, empty: ''), style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                ]),
              ),
          ]),
        ),
      ],
      const SizedBox(height: 20),
    ]);
  }
}

String claimKindLabel(String k) => switch (k) {
      'warranty_repair' => 'Warranty repair',
      'warranty_replacement' => 'Warranty replacement',
      'return_refund' => 'Return / refund',
      'protection_plan' => 'Protection plan claim',
      'credit_card_benefit' => 'Card benefit claim',
      _ => 'Claim',
    };

String claimStatusLabel(String s) => switch (s) {
      'draft' => 'Draft',
      'ready_to_submit' => 'Ready to send',
      'submitted_by_user' => 'Sent',
      'in_review' => 'In review',
      'info_requested' => 'Info requested',
      'approved' => 'Approved',
      'denied' => 'Denied',
      'resolved' => 'Resolved',
      'withdrawn' => 'Withdrawn',
      _ => titleCase(s),
    };

class _ReturnCard extends StatelessWidget {
  const _ReturnCard({required this.itemId, required this.r});
  final String itemId;
  final ReturnWindow r;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final days = daysUntil(r.deadline);
    final urgent = days != null && days <= 3;
    return WCard(
      color: urgent ? c.urgentSoft : null,
      onTap: () => context.push('/items/$itemId/return/${r.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r.deadline == null ? 'Return deadline unknown' : '${returnMeaning(r.deadlineBasis)} ${fmtDate(r.deadline)}',
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text)),
          ),
          CertBadge(r.certainty),
        ]),
        const SizedBox(height: 4),
        Text(
          [
            if (days != null) daysLeftLabel(days),
            if (r.windowDays != null) '${r.windowDays}-day window from ${returnAnchorLabel(r.anchor)}',
            if (r.retailer != null) r.retailer!,
          ].join(' · '),
          style: TextStyle(fontSize: 13, color: urgent ? c.urgent : c.textMuted),
        ),
        if (r.state != 'not_started') ...[const SizedBox(height: 8), WTag(returnStateLabel(r.state), kind: WTagKind.accent)],
      ]),
    );
  }
}

class _WarrantyCard extends StatelessWidget {
  const _WarrantyCard({required this.itemId, required this.w});
  final String itemId;
  final Warranty w;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final p = coverageProgress(w);
    final inactive = w.contractState != 'active';
    return WCard(
      onTap: () => context.push('/items/$itemId/coverage/${w.id}'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(coverageTitle(w), style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text))),
          CertBadge(w.certainty),
        ]),
        if (w.provider != null) Text(w.provider!, style: TextStyle(fontSize: 13, color: c.textMuted)),
        const SizedBox(height: 8),
        Text(coverageRange(w), style: TextStyle(fontSize: 13, color: c.textMuted)),
        if (p != null) ...[const SizedBox(height: 8), WProgressBar(p)],
        if (w.daysRemaining != null && w.daysRemaining! >= 0 && !inactive) ...[
          const SizedBox(height: 6),
          Text('${w.daysRemaining} days remaining', style: TextStyle(fontSize: 12, color: c.textSubtle)),
        ],
        if (inactive) ...[const SizedBox(height: 6), WTag(titleCase(w.contractState), kind: WTagKind.outline)],
        if (w.certainty == 'estimated' && !w.estimateAccepted) ...[
          const SizedBox(height: 8),
          Text('Estimated — confirm the real terms to get reminders.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
        ],
        if (w.disclosure != null) ...[const SizedBox(height: 6), Text(w.disclosure!, style: TextStyle(fontSize: 12, color: c.textSubtle))],
      ]),
    );
  }
}

class _SuggestionsOrEmpty extends ConsumerWidget {
  const _SuggestionsOrEmpty({required this.itemId});
  final String itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final sug = ref.watch(suggestionsProvider(itemId)).value;
    final list = (sug?['warranties'] as List?)?.whereType<Map>().toList() ?? const [];
    if (list.isEmpty) {
      return WCard(
        onTap: () => context.push('/items/$itemId/coverage/new'),
        child: Row(children: [
          Icon(PhosphorIconsRegular.question, color: c.textSubtle),
          const SizedBox(width: 10),
          Expanded(child: Text('Coverage unknown. Add the warranty terms if you have them.', style: TextStyle(color: c.textMuted))),
        ]),
      );
    }
    final first = Map<String, dynamic>.from(list.first);
    return WCard(
      color: c.accentSoft,
      border: false,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(PhosphorIconsRegular.lightbulb, color: c.accentSoftText, size: 18),
          const SizedBox(width: 8),
          Text('Suggested coverage', style: TextStyle(fontWeight: FontWeight.w600, color: c.accentSoftText)),
        ]),
        const SizedBox(height: 6),
        Text(first['duration_months'] != null
                ? "${first['provider_name']}'s standard warranty appears to be ${first['duration_months']} months. Confirm?"
                : '${first['provider_name'] ?? 'The manufacturer'} lists ${first['term_kind']} terms. Confirm?', style: TextStyle(color: c.accentSoftText, height: 1.4)),
        const SizedBox(height: 4),
        Text((sug?['disclaimer'] ?? 'Suggested from manufacturer information. Confirm your actual terms.').toString(),
            style: TextStyle(fontSize: 12, color: c.accentSoftText)),
        const SizedBox(height: 10),
        Row(children: [
          WButton('Review', compact: true, expand: false, onPressed: () => context.push('/items/$itemId/coverage/new', extra: first)),
          const SizedBox(width: 8),
          WButton.ghost('Enter my own', onPressed: () => context.push('/items/$itemId/coverage/new')),
        ]),
      ]),
    );
  }
}

class _ItemMenu extends ConsumerWidget {
  const _ItemMenu({required this.item});
  final ItemDetail item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = item.summary;
    return PopupMenuButton<String>(
      icon: Icon(PhosphorIconsRegular.dotsThreeVertical, color: context.w.text),
      onSelected: (v) async {
        final repo = ref.read(itemsRepositoryProvider);
        switch (v) {
          case 'edit':
            context.push('/items/${s.id}/edit');
          case 'lifecycle':
            await showLifecycleSheet(context, ref, item);
          case 'archive':
            try {
              await repo.update(s.id, {'archived': !s.archived}, version: item.version);
              ref.refreshItems(itemId: s.id);
              if (context.mounted) showToast(context, s.archived ? 'Item restored' : 'Item archived. Reminders are paused.');
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
          case 'share':
            context.push('/household?share=${s.id}');
          case 'delete':
            final ok = await confirmDialog(context,
                title: 'Delete ${s.name}?',
                message: 'Coverage, return windows and reminders for this item are removed. Documents stay in your vault until you delete them there.',
                confirm: 'Delete item',
                destructive: true,
                icon: PhosphorIconsRegular.trash);
            if (!ok) return;
            try {
              await repo.delete(s.id);
              ref.refreshItems();
              if (context.mounted) {
                context.pop();
                showToast(context, 'Item deleted');
              }
            } catch (e) {
              if (context.mounted) showFailure(context, e);
            }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'edit', child: Text('Edit details')),
        const PopupMenuItem(value: 'lifecycle', child: Text('Returned, sold or gifted…')),
        const PopupMenuItem(value: 'share', child: Text('Share with household')),
        PopupMenuItem(value: 'archive', child: Text(s.archived ? 'Unarchive' : 'Archive')),
        const PopupMenuItem(value: 'delete', child: Text('Delete item')),
      ],
    );
  }
}

Future<void> showLifecycleSheet(BuildContext context, WidgetRef ref, ItemDetail item) async {
  final picked = await showWSheet<String>(context, builder: (ctx) {
    final c = ctx.w;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('What happened to it?', style: ctx.t.titleLarge),
      const SizedBox(height: 4),
      Text('Reminders stop for items you no longer own. The record and documents stay.', style: TextStyle(color: c.textMuted)),
      const SizedBox(height: 12),
      for (final e in lifecycleLabels.entries)
        WListRow(
          title: e.value,
          icon: e.key == item.summary.lifecycle ? PhosphorIconsFill.checkCircle : PhosphorIconsRegular.circle,
          caret: false,
          onTap: () => Navigator.pop(ctx, e.key),
        ),
    ]);
  });
  if (picked == null || picked == item.summary.lifecycle) return;
  try {
    await ref.read(itemsRepositoryProvider).update(item.summary.id, {'lifecycle_state': picked}, version: item.version);
    ref.refreshItems(itemId: item.summary.id);
    if (context.mounted) showToast(context, 'Marked as ${lifecycleLabels[picked]!.toLowerCase()}');
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}
