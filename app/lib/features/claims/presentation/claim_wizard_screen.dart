import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../../capture/presentation/upload_flow.dart';
import '../../items/domain/items.dart';
import '../../items/presentation/item_ui.dart';
import '../../items/presentation/items_providers.dart';
import '../domain/claims.dart';
import 'claims_providers.dart';

/// Four steps: issue → coverage → evidence → review the facts. Then the pack.
class ClaimWizardScreen extends ConsumerWidget {
  const ClaimWizardScreen({super.key, required this.itemId});
  final String itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(itemDetailProvider(itemId));
    return d.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Claim pack', children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox())]),
      data: (item) => _Wizard(item: item),
    );
  }
}

class _Wizard extends ConsumerStatefulWidget {
  const _Wizard({required this.item});
  final ItemDetail item;
  @override
  ConsumerState<_Wizard> createState() => _WizardState();
}

class _WizardState extends ConsumerState<_Wizard> {
  int step = 0;
  final issue = TextEditingController();
  DateTime? started;
  String? coverage; // 'w:<id>' | 'r:<id>' | 'none'
  final contact = TextEditingController();
  late final provider = TextEditingController(text: widget.item.summary.brand ?? '');
  late final Set<String> evidence = widget.item.documents.map((d) => d.attachmentId).toSet();
  final extra = <(String, String)>[]; // uploaded claim evidence (id, name)
  Claim? claim;
  bool busy = false;
  final _draftKey = ApiClient.newIdempotencyKey();

  ItemDetail get item => widget.item;

  @override
  void initState() {
    super.initState();
    final active = item.warranties.where((w) => w.contractState == 'active').toList();
    final openReturn = item.returns.where((r) => r.state == 'not_started' && (daysUntil(r.deadline) ?? -1) >= 0).toList();
    coverage = openReturn.isNotEmpty ? 'r:${openReturn.first.id}' : active.isNotEmpty ? 'w:${active.first.id}' : 'none';
  }

  String get _kind {
    if (coverage?.startsWith('r:') ?? false) return 'return_refund';
    final w = item.warranties.where((x) => 'w:${x.id}' == coverage).firstOrNull;
    return switch (w?.coverageType) { 'protection_plan' || 'extended' => 'protection_plan', 'credit_card' => 'credit_card_benefit', null => 'other', _ => 'warranty_repair' };
  }

  Map<String, dynamic> _contact() {
    final t = contact.text.trim();
    if (t.isEmpty) return {};
    if (t.contains('@')) return {'email': t};
    if (t.startsWith('http')) return {'url': t};
    return {'phone': t};
  }

  Future<void> _next() async {
    if (step == 0 && issue.text.trim().isEmpty) return showToast(context, 'Describe what is wrong in your own words.');
    if (step < 2) return setState(() => step++);
    if (step == 2) {
      setState(() => busy = true);
      try {
        final c = await ref.read(claimsRepositoryProvider).create({
          'item_id': item.summary.id,
          if (coverage!.startsWith('w:')) 'warranty_id': coverage!.substring(2),
          if (coverage!.startsWith('r:')) 'return_window_id': coverage!.substring(2),
          'claim_kind': _kind,
          'issue_description': issue.text.trim(),
          'issue_started_on': isoDate(started),
          'provider_name': provider.text.trim().isEmpty ? null : provider.text.trim(),
          if (_contact().isNotEmpty) 'provider_contact': _contact(),
          'attachment_ids': [...evidence, ...extra.map((e) => e.$1)],
        });
        claim = await ref.read(claimsRepositoryProvider).get(c.id);
        ref.invalidate(claimsProvider);
        ref.refreshItems(itemId: item.summary.id);
        setState(() => step = 3);
      } catch (e) {
        if (mounted) showFailure(context, e);
      } finally {
        if (mounted) setState(() => busy = false);
      }
      return;
    }
    // step 3: confirm facts, mark ready and build the pack
    setState(() => busy = true);
    try {
      final repo = ref.read(claimsRepositoryProvider);
      await repo.reviewSnapshot(claim!.id, claim!.proposedFacts ?? {});
      await repo.update(claim!.id, {'status': 'ready_to_submit'});
      ref.invalidate(claimProvider(claim!.id));
      ref.invalidate(claimsProvider);
      if (mounted) context.pushReplacement('/claims/${claim!.id}/pack');
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addEvidence() async {
    final src = await showWSheet<PickSource>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add evidence', style: ctx.t.titleLarge),
          WListRow(icon: PhosphorIconsRegular.camera, title: 'Photo of the issue', onTap: () => Navigator.pop(ctx, PickSource.camera)),
          WListRow(icon: PhosphorIconsRegular.image, title: 'From photos', onTap: () => Navigator.pop(ctx, PickSource.gallery)),
          WListRow(icon: PhosphorIconsRegular.filePdf, title: 'A file', onTap: () => Navigator.pop(ctx, PickSource.files)),
        ]));
    if (src == null || !mounted) return;
    try {
      final f = await pickFile(src);
      if (f == null || !mounted) return;
      final up = await uploadWithProgress(context, ref, f, fileType: 'claim_evidence');
      if (up != null) setState(() => extra.add((up.attachmentId, f.name)));
    } catch (e) {
      if (mounted) showUploadIssue(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final s = item.summary;
    const labels = ['Issue', 'Coverage', 'Evidence', 'Review'];
    return WScreen(
      title: 'Claim pack · Step ${step + 1} of 4',
      onBack: () => step == 0 || step == 3 ? context.pop() : setState(() => step--),
      bottom: WButton(step == 3 ? 'Confirm facts & build pack' : 'Continue', loading: busy, onPressed: _next),
      children: [
        Row(children: [
          for (final (i, l) in labels.indexed)
            Expanded(
              child: Column(children: [
                Container(height: 3, margin: const EdgeInsets.symmetric(horizontal: 2), decoration: BoxDecoration(color: i <= step ? c.accent : c.divider, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 4),
                Text(l, style: TextStyle(fontSize: 11, color: i == step ? c.text : c.textSubtle)),
              ]),
            ),
        ]),
        const SizedBox(height: 14),
        WCard(
          child: Row(children: [
            IconTile(itemIcon(category: s.categorySlug, name: s.name)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.name, style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
                Text([s.model, s.retailer, if (s.purchaseDate != null) fmtDate(s.purchaseDate)].whereType<String>().join(' · '), style: TextStyle(fontSize: 12.5, color: c.textMuted)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        ...switch (step) {
          0 => [
              Text("What's wrong?", style: context.t.titleLarge),
              const SizedBox(height: 10),
              WField(label: 'Describe what you see, in your words', controller: issue, maxLines: 5),
              WDateField(label: 'When did it start?', value: started, onChanged: (v) => setState(() => started = v)),
              Text("Warrantra won't add symptoms, causes or legal claims to what you write.", style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
            ],
          1 => [
              Text('Which coverage?', style: context.t.titleLarge),
              const SizedBox(height: 10),
              for (final r in item.returns.where((r) => !r.dismissed && r.state == 'not_started'))
                WCheckRow(
                  radio: true,
                  value: coverage == 'r:${r.id}',
                  onChanged: (_) => setState(() => coverage = 'r:${r.id}'),
                  title: 'Return to ${r.retailer ?? 'the store'}',
                  subtitle: r.deadline == null ? 'Deadline unknown' : '${returnMeaning(r.deadlineBasis)} ${fmtDate(r.deadline)}',
                  trailing: CertBadge(r.certainty),
                ),
              for (final w in item.warranties)
                WCheckRow(
                  radio: true,
                  value: coverage == 'w:${w.id}',
                  onChanged: (_) => setState(() => coverage = 'w:${w.id}'),
                  title: coverageTitle(w),
                  subtitle: '${w.provider ?? ''}${w.provider == null ? '' : ' · '}${coverageRange(w)}${w.timeStatus == 'expired' ? '\nEnded per your records. The provider decides eligibility.' : ''}',
                  trailing: CertBadge(w.certainty),
                ),
              WCheckRow(radio: true, value: coverage == 'none', onChanged: (_) => setState(() => coverage = 'none'), title: 'No specific coverage', subtitle: 'Prepare a pack with your proof of purchase'),
              const SizedBox(height: 12),
              WField(label: 'Provider', controller: provider),
              WField(label: 'Provider contact (from their terms)', controller: contact, hint: 'Phone, email or claim page'),
            ],
          2 => [
              Text('Choose evidence', style: context.t.titleLarge),
              Text('${evidence.length + extra.length} selected', style: TextStyle(color: c.textMuted)),
              const SizedBox(height: 8),
              if (item.documents.isEmpty && extra.isEmpty) const WNote('No documents on this item yet. Add a photo of the issue or the receipt.'),
              for (final d in item.documents)
                WCheckRow(
                  value: evidence.contains(d.attachmentId),
                  onChanged: (v) => setState(() => v ? evidence.add(d.attachmentId) : evidence.remove(d.attachmentId)),
                  title: d.filename ?? titleCase(d.fileType),
                  subtitle: titleCase(d.role),
                ),
              for (final e in extra) WCheckRow(value: true, onChanged: (_) => setState(() => extra.remove(e)), title: e.$2, subtitle: 'Claim evidence'),
              const SizedBox(height: 8),
              WButton.secondary('Add photo of the issue', icon: PhosphorIconsRegular.camera, onPressed: _addEvidence),
            ],
          _ => [
              Text('Review the facts', style: context.t.titleLarge),
              const SizedBox(height: 4),
              Text('These come only from what you saved. Edit the item if something is wrong; the pack uses exactly this.', style: TextStyle(color: c.textMuted)),
              const SizedBox(height: 10),
              if (claim != null) FactsCard(facts: claim!.proposedFacts ?? {}, issue: claim!.issue, startedOn: claim!.issueStartedOn),
              const SizedBox(height: 10),
              _AiDraftOffer(claimId: claim?.id, idempotencyKey: _draftKey),
            ],
        },
      ],
    );
  }
}

class FactsCard extends StatelessWidget {
  const FactsCard({super.key, required this.facts, required this.issue, this.startedOn});
  final Map<String, dynamic> facts;
  final String issue;
  final String? startedOn;
  @override
  Widget build(BuildContext context) {
    final p = facts.m('product'), pu = facts.m('purchase'), cov = facts.m('coverage');
    String v(Object? x) => x == null || x.toString().isEmpty ? 'Not recorded' : x.toString();
    return WCard(
      child: Column(children: [
        WKeyValue('Product', v(p['name'])),
        WKeyValue('Brand', v(p['brand'])),
        WKeyValue('Model', v(p['model_number'])),
        WKeyValue('Serial', v(p['serial_number'])),
        WKeyValue('Retailer', v(pu['retailer'])),
        WKeyValue('Order', v(pu['order_number'])),
        WKeyValue('Purchased', fmtDate(pu['purchase_date'], empty: 'Not recorded')),
        WKeyValue('Price', pu['price'] == null ? 'Not recorded' : '${fmtMoney(pu['price'], currency: v(pu['currency']))}${pu['price_is_estimated'] == true ? ' (est.)' : ''}'),
        if (cov.isNotEmpty) ...[
          WKeyValue('Coverage', '${titleCase(v(cov['coverage_type']))} · ${v(cov['provider_name'])}'),
          WKeyValue('Coverage dates', '${fmtDate(cov['start_date'], empty: '?')} → ${fmtDate(cov['end_date'], empty: '?')}', note: 'Certainty: ${titleCase(v(cov['date_certainty']))}'),
        ],
        WKeyValue('Issue started', fmtDate(startedOn, empty: 'Not recorded')),
        WKeyValue('Issue', issue),
      ]),
    );
  }
}

class _AiDraftOffer extends ConsumerStatefulWidget {
  const _AiDraftOffer({required this.claimId, required this.idempotencyKey});
  final String? claimId;
  final String idempotencyKey;
  @override
  ConsumerState<_AiDraftOffer> createState() => _AiDraftOfferState();
}

class _AiDraftOfferState extends ConsumerState<_AiDraftOffer> {
  bool open = false;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    final pro = me?.plan.aiClaimDraft ?? false;
    return WCard(
      onTap: () => setState(() => open = !open),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(PhosphorIconsRegular.sparkle, color: c.accent, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text('Polish the wording with AI', style: TextStyle(fontWeight: FontWeight.w500, color: c.text))),
          if (!pro) const WTag('Pro', kind: WTagKind.accent),
        ]),
        if (open) ...[
          const SizedBox(height: 6),
          Text(
              pro
                  ? 'After you confirm the facts, you can generate an AI-assisted letter on the next screen. It uses 1 AI action and is labeled AI-assisted.'
                  : 'Pro adds an optional AI-written letter and an assembled PDF with your evidence. The factual template is always free.',
              style: TextStyle(fontSize: 13, color: c.textMuted, height: 1.4)),
          if (!pro) Align(alignment: Alignment.centerLeft, child: WButton.ghost('See Pro', onPressed: () => context.push('/settings/paywall'))),
        ],
      ]),
    );
  }
}
