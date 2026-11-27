import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../../items/presentation/item_detail_screen.dart' show claimKindLabel, claimStatusLabel;
import '../../items/presentation/items_providers.dart';
import '../domain/claims.dart';
import 'claim_wizard_screen.dart';
import 'claims_providers.dart';

Widget _loadClaim(WidgetRef ref, String id, String title, Widget Function(Claim) build) {
  final c = ref.watch(claimProvider(id));
  return c.when(
    loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
    error: (e, _) => WScreen(title: title, children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox(), onRetry: () => ref.invalidate(claimProvider(id)))]),
    data: build,
  );
}

// ---------------------------------------------------------------------------
// Pack ready
// ---------------------------------------------------------------------------
class ClaimPackScreen extends ConsumerStatefulWidget {
  const ClaimPackScreen({super.key, required this.claimId});
  final String claimId;
  @override
  ConsumerState<ClaimPackScreen> createState() => _ClaimPackScreenState();
}

class _ClaimPackScreenState extends ConsumerState<ClaimPackScreen> {
  bool busy = false;
  String? text;
  String? aiDraft;
  final _aiKey = ApiClient.newIdempotencyKey();

  Future<String> _text() async {
    if (text != null) return text!;
    final p = await ref.read(claimsRepositoryProvider).generatePack(widget.claimId, format: 'text');
    return text = p.text ?? '';
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() => busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _loadClaim(ref, widget.claimId, 'Claim pack', (cl) {
        final c = context.w;
        final me = ref.watch(meProvider).value;
        final assembled = me?.plan.claimPackAssembled ?? false;
        final draft = aiDraft ?? cl.aiDraft;
        final email = cl.providerContact['email']?.toString();
        return WScreen(
          title: 'Claim pack ready',
          bottom: cl.sent
              ? WButton.secondary('View claim', onPressed: () => context.pushReplacement('/claims/${cl.id}'))
              : WButton('I sent it · track this claim', loading: busy, onPressed: () => _run(() async {
                    await ref.read(claimsRepositoryProvider).update(cl.id, {
                      'status': 'submitted_by_user',
                      'follow_up_on': isoDate(DateTime.now().add(const Duration(days: 10))),
                    });
                    ref.invalidate(claimProvider(cl.id));
                    ref.invalidate(claimsProvider);
                    ref.refreshItems(itemId: cl.itemId);
                    if (mounted) {
                      showToast(context, "Tracking it. We'll remind you to follow up in 10 days.");
                      context.pushReplacement('/claims/${cl.id}');
                    }
                  })),
          children: [
            Text(claimKindLabel(cl.kind), style: TextStyle(color: c.textMuted)),
            Text(cl.itemLabel, style: context.t.headlineSmall),
            const SizedBox(height: 14),
            WCard(
              child: Row(children: [
                IconTile(PhosphorIconsRegular.paperclip, emphasis: true),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_packLabel(cl.docs.where((d) => d.includeInPack).length), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text)),
                    Text(assembled ? 'One PDF with your evidence attached' : 'PDF and plain text · built only from what you saved', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            WButton.secondary('Save PDF', icon: PhosphorIconsRegular.filePdf, loading: busy, onPressed: () => _run(() async {
                  final p = await ref.read(claimsRepositoryProvider).generatePack(cl.id, format: 'pdf');
                  if (p.url != null) await launchUrl(Uri.parse(p.url!), mode: LaunchMode.inAppBrowserView);
                })),
            const SizedBox(height: 8),
            WButton.secondary('Copy text', icon: PhosphorIconsRegular.copy, onPressed: () => _run(() async {
                  await Clipboard.setData(ClipboardData(text: draft ?? await _text()));
                  if (mounted) showToast(context, 'Copied');
                })),
            const SizedBox(height: 8),
            WButton.secondary('Email', icon: PhosphorIconsRegular.envelopeSimple, onPressed: () => _run(() async {
                  final body = draft ?? await _text();
                  final subject = body.split('\n').first.replaceFirst(RegExp(r'^Subject:\s*'), '');
                  await launchUrl(Uri(scheme: 'mailto', path: email ?? '', query: 'subject=${Uri.encodeComponent(subject)}&body=${Uri.encodeComponent(body)}'));
                })),
            const SizedBox(height: 12),
            WNote("Opening email or sharing doesn't count as sending. Mark it sent once you've submitted it to the provider.", icon: PhosphorIconsRegular.info),
            if (me?.plan.aiClaimDraft ?? false) ...[
              const WSectionHeader('AI-assisted letter'),
              if (draft == null)
                WButton.ghost('Draft a letter with AI · 1 action', icon: PhosphorIconsRegular.sparkle, onPressed: () => _run(() async {
                      final t = await ref.read(claimsRepositoryProvider).aiDraft(cl.id, idempotencyKey: _aiKey);
                      ref.invalidate(meProvider);
                      setState(() => aiDraft = t);
                    }))
              else ...[
                const WTag('AI-assisted — check every statement', kind: WTagKind.accent, icon: PhosphorIconsRegular.sparkle),
                const SizedBox(height: 8),
                WCard(child: SelectableText(draft, style: TextStyle(fontSize: 13.5, height: 1.5, color: c.text))),
                const SizedBox(height: 6),
                Text('Copy and Email use this letter. The PDF stays factual.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
              ],
            ],
          ],
        );
      });
}

// ---------------------------------------------------------------------------
// Claim detail
// ---------------------------------------------------------------------------
class ClaimDetailScreen extends ConsumerWidget {
  const ClaimDetailScreen({super.key, required this.claimId});
  final String claimId;

  Future<void> _edit(BuildContext context, WidgetRef ref, Claim cl) async {
    final number = TextEditingController(text: cl.claimNumber ?? '');
    String status = cl.status;
    DateTime? follow = parseDate(cl.followUpOn);
    final ok = await showWSheet<bool>(context, builder: (ctx) => StatefulBuilder(
          builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Update claim', style: ctx.t.titleLarge),
            const SizedBox(height: 10),
            WField(label: 'Claim / case number', controller: number),
            WChoiceChips<String>(
              label: 'Status',
              options: const [('submitted_by_user', 'Sent'), ('in_review', 'In review'), ('info_requested', 'Info requested'), ('approved', 'Approved'), ('denied', 'Denied'), ('withdrawn', 'Withdrawn')],
              value: status,
              onChanged: (v) => set(() => status = v),
            ),
            const SizedBox(height: 10),
            WDateField(notBeforeToday: true, label: 'Follow up on', value: follow, onChanged: (v) => set(() => follow = v)),
            WButton('Save', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ));
    if (ok != true) return;
    try {
      await ref.read(claimsRepositoryProvider).update(cl.id, {'claim_number': number.text.trim().isEmpty ? null : number.text.trim(), 'status': status, 'follow_up_on': isoDate(follow)}, version: cl.version);
      ref.invalidate(claimProvider(cl.id));
      ref.invalidate(claimsProvider);
      ref.refreshItems(itemId: cl.itemId); // the item page lists this claim's status
      if (context.mounted) showToast(context, 'Claim updated');
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _loadClaim(ref, claimId, 'Claim', (cl) {
        final c = context.w;
        final packed = cl.packs.isNotEmpty || cl.status != 'draft';
        Widget row(bool done, String title, String? sub, {bool next = false}) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(done ? PhosphorIconsFill.checkCircle : next ? PhosphorIconsRegular.circleDashed : PhosphorIconsRegular.circle, color: done ? c.accent : c.textSubtle, size: 20),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, style: TextStyle(color: c.text)),
                    if (sub != null) Text(sub, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                  ]),
                ),
              ]),
            );
        return WScreen(
          title: 'Claim',
          actions: [WIconButton(PhosphorIconsRegular.pencilSimple, tooltip: 'Update', onPressed: () => _edit(context, ref, cl))],
          bottom: Column(mainAxisSize: MainAxisSize.min, children: [
            if (cl.outcome == null && cl.sent) ...[WButton('Record outcome', onPressed: () => context.push('/outcomes/new?claim=${cl.id}')), const SizedBox(height: 8)],
            if (!cl.snapshotReviewed)
              WButton('Continue preparing', onPressed: () => context.push('/claims/new?item=${cl.itemId}'))
            else
              WButton.secondary('View claim pack', onPressed: () => context.push('/claims/${cl.id}/pack')),
          ]),
          children: [
            Text([cl.providerName ?? claimKindLabel(cl.kind), if (cl.claimNumber != null) cl.claimNumber!].join(' · '), style: TextStyle(color: c.textMuted)),
            Text(cl.itemLabel, style: context.t.headlineSmall),
            const SizedBox(height: 4),
            Text(cl.issue, style: TextStyle(color: c.textMuted, height: 1.4)),
            const SizedBox(height: 8),
            WTag(claimStatusLabel(cl.status), kind: cl.closed ? WTagKind.outline : WTagKind.accent),
            const SizedBox(height: 14),
            WCard(
              child: Column(children: [
                row(packed, 'Pack prepared', !packed ? null : fmtDate(cl.packs.firstOrNull?.generatedAt ?? cl.history.where((h) => h.to != 'draft').firstOrNull?.at ?? cl.createdAt)),
                row(cl.sent, 'Sent to provider', cl.submittedAt == null ? null : '${fmtDate(cl.submittedAt)} · you marked', next: packed && !cl.sent),
                if (cl.outcome == null) ...[
                  row(false, 'Follow up', cl.followUpOn == null ? null : '${fmtDate(cl.followUpOn)} · reminder set', next: cl.sent),
                  row(false, 'Outcome', null),
                ] else
                  row(true, outcomeLabel(cl.outcome!.type), [if (cl.outcome!.amount != null) fmtMoney(cl.outcome!.amount, currency: cl.outcome!.currency ?? 'USD'), fmtDate(cl.outcome!.date), evidenceLabel(cl.outcome!.evidence)].join(' · ')),
              ]),
            ),
            const SizedBox(height: 10),
            Text('A snapshot of the product and coverage facts is kept with this claim, so it stays readable even if you delete the item.',
                style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.4)),
            if (cl.reviewedFacts != null) ...[
              const WSectionHeader('Facts in the pack'),
              FactsCard(facts: cl.reviewedFacts!, issue: cl.issue, startedOn: cl.issueStartedOn, providerName: cl.providerName, providerContact: cl.providerContact),
            ],
            if (cl.providerContact.isNotEmpty) ...[
              const WSectionHeader('Provider contact'),
              for (final e in cl.providerContact.entries)
                WListRow(
                  icon: switch (e.key) { 'email' => PhosphorIconsRegular.envelopeSimple, 'phone' => PhosphorIconsRegular.phone, 'url' => PhosphorIconsRegular.globe, _ => PhosphorIconsRegular.mapPin },
                  title: e.value.toString(),
                  onTap: () => launchUrl(
                      e.key == 'email' ? Uri(scheme: 'mailto', path: '${e.value}') : e.key == 'phone' ? Uri(scheme: 'tel', path: '${e.value}') : Uri.parse('${e.value}'),
                      mode: LaunchMode.externalApplication),
                ),
            ],
          ],
        );
      });
}

String outcomeLabel(String t) => switch (t) {
      'refund_received' => 'Refund received',
      'repair_completed' => 'Repaired',
      'replacement_received' => 'Replaced',
      'denied' => 'Denied',
      'withdrawn' => 'Withdrawn',
      _ => titleCase(t),
    };

String evidenceLabel(String e) => switch (e) { 'document_attached' => 'document attached', 'provider_confirmation' => 'provider confirmed', _ => 'you reported' };

// ---------------------------------------------------------------------------
// Claims list
// ---------------------------------------------------------------------------
class ClaimsListScreen extends ConsumerWidget {
  const ClaimsListScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final claims = ref.watch(claimsProvider);
    return WScreen(
      title: 'Claims',
      actions: [WIconButton(PhosphorIconsRegular.chartBar, tooltip: 'Outcomes', onPressed: () => context.push('/outcomes'))],
      children: [
        AsyncBody<List<Claim>>(
          value: claims,
          onRetry: () => ref.invalidate(claimsProvider),
          data: (list) {
            if (list.isEmpty) {
              return const WEmpty(icon: PhosphorIconsRegular.lifebuoy, title: 'No claims yet', message: 'Start a claim from an item when something goes wrong. Warrantra assembles the facts; you send it.');
            }
            final open = list.where((c) => !c.closed).toList(), closed = list.where((c) => c.closed).toList();
            final next = (open.where((c) => c.followUpOn != null).toList()..sort((a, b) => a.followUpOn!.compareTo(b.followUpOn!))).firstOrNull;
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              WHeroCard(
                eyebrow: 'Claims',
                title: open.isEmpty ? 'All claims closed' : '${open.length} in progress',
                icon: PhosphorIconsFill.lifebuoy,
                children: [
                  const SizedBox(height: 6),
                  Text(
                    next != null
                        ? 'Next follow-up ${fmtDayShort(next.followUpOn)} · ${next.itemLabel}'
                        : '${closed.length} closed · ${list.length} in total',
                    style: WHeroCard.muted(),
                  ),
                ],
              ),
              if (open.isNotEmpty) ...[
                const SizedBox(height: 22),
                const WSectionHeader('In progress'),
                for (final cl in open) ...[_ClaimCard(cl), const SizedBox(height: 10)],
              ],
              if (closed.isNotEmpty) ...[
                const SizedBox(height: 12),
                const WSectionHeader('Closed'),
                for (final cl in closed) ...[_ClaimCard(cl), const SizedBox(height: 10)],
              ],
            ]);
          },
        ),
      ],
    );
  }
}

class _ClaimCard extends StatelessWidget {
  const _ClaimCard(this.cl);
  final Claim cl;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final days = daysUntil(cl.followUpOn);
    final soon = !cl.closed && days != null && days <= 3;
    return WCard(
      onTap: () => context.push('/claims/${cl.id}'),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        WTintIcon(cl.closed ? PhosphorIconsRegular.checkCircle : PhosphorIconsRegular.chatCircleText, cl.closed ? WTint.green : WTint.violet),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(cl.itemLabel, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: c.text)),
            const SizedBox(height: 2),
            Text(claimKindLabel(cl.kind), style: TextStyle(fontSize: 13, color: c.textMuted)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              WTag(claimStatusLabel(cl.status), kind: cl.closed ? WTagKind.outline : WTagKind.accent),
            ]),
            if (cl.followUpOn != null && !cl.closed) ...[
              const SizedBox(height: 8),
              // One wrapping line (icon inline) so large text never overflows.
              Text.rich(
                TextSpan(children: [
                  WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(PhosphorIconsRegular.calendarBlank, size: 14, color: soon ? WTint.amber : c.textSubtle),
                    ),
                  ),
                  TextSpan(text: days != null && days < 0 ? 'Follow-up overdue' : 'Follow up ${fmtDayShort(cl.followUpOn)}'),
                ]),
                style: TextStyle(fontSize: 12.5, fontWeight: soon ? FontWeight.w600 : FontWeight.w400, color: soon ? WTint.amber : c.textSubtle),
              ),
            ],
          ]),
        ),
        Padding(padding: const EdgeInsets.only(top: 10), child: Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Outcome form & ledger
// ---------------------------------------------------------------------------
class OutcomeFormScreen extends ConsumerStatefulWidget {
  const OutcomeFormScreen({super.key, this.claimId, this.returnId, this.paid});
  final String? claimId, returnId;

  /// What the item cost, when known; used to sanity-check reported refunds.
  final num? paid;
  @override
  ConsumerState<OutcomeFormScreen> createState() => _OutcomeFormScreenState();
}

class _OutcomeFormScreenState extends ConsumerState<OutcomeFormScreen> {
  // Returns and return/refund claims most often end in a refund; warranty claims in a repair.
  late String type = widget.returnId != null || _claimKind == 'return_refund' ? 'refund_received' : 'repair_completed';
  String? get _claimKind => widget.claimId == null ? null : ref.read(claimProvider(widget.claimId!)).value?.kind;
  final amount = TextEditingController();
  DateTime? date = DateTime.now();
  String evidence = 'user_reported';
  String? helped;
  final comment = TextEditingController();
  bool saving = false;

  bool get hasAmount => type == 'refund_received';

  Future<void> _save() async {
    if (hasAmount && isBadMoney(amount.text)) return showToast(context, badMoneyMessage);
    final refund = hasAmount ? num.tryParse(normalizeMoney(amount.text) ?? '') : null;
    final paid = widget.paid;
    if (refund != null && paid != null && paid > 0 && refund > paid) {
      final cur = ref.read(meProvider).value?.profile.currency ?? 'USD';
      // Spec §9: don't inflate outcomes. Tax/shipping can push a refund above the
      // line price, so ask rather than block.
      final ok = await confirmDialog(context,
          title: 'More than you paid?',
          message: 'You entered ${fmtMoney(refund, currency: cur)} but this item cost ${fmtMoney(paid, currency: cur)}. Record only what you actually received, including tax or shipping refunds.',
          confirm: 'Record ${fmtMoney(refund, currency: cur)}');
      if (!ok || !mounted) return;
    }
    setState(() => saving = true);
    final me = ref.read(meProvider).value;
    try {
      await ref.read(claimsRepositoryProvider).recordOutcome({
        'claim_id': ?widget.claimId,
        'return_window_id': ?widget.returnId,
        'outcome_type': type,
        if (hasAmount && normalizeMoney(amount.text) != null) ...{'amount': normalizeMoney(amount.text), 'currency': me?.profile.currency ?? 'USD'},
        'outcome_date': ?isoDate(date),
        'evidence_level': evidence,
        'warrantra_helped': ?helped,
        if (comment.text.trim().isNotEmpty) 'user_comment': comment.text.trim(),
      });
      ref.invalidate(outcomesProvider);
      ref.invalidate(outcomeSummaryProvider);
      if (widget.claimId != null) ref.invalidate(claimProvider(widget.claimId!));
      ref.invalidate(claimsProvider);
      ref.refreshItems();
      if (mounted) {
        context.pop();
        showToast(context, 'Outcome saved');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = ref.watch(meProvider).value?.profile.currency ?? 'USD';
    return WScreen(
      title: 'Record outcome',
      close: true,
      bottom: WButton('Save outcome', loading: saving, onPressed: _save),
      children: [
        Text('What happened?', style: context.t.titleLarge),
        const SizedBox(height: 10),
        WChoiceChips<String>(
          options: [
            ('refund_received', 'Refund'),
            if (widget.returnId == null) ...[('repair_completed', 'Repaired'), ('replacement_received', 'Replaced')],
            ('denied', 'Denied'),
            ('withdrawn', 'Withdrawn'),
          ],
          value: type,
          onChanged: (v) => setState(() => type = v),
        ),
        const SizedBox(height: 12),
        if (hasAmount) WField(label: 'Amount received ($cur)', controller: amount, hint: '0.00', keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        WDateField(notAfterToday: true, label: 'Date', value: date, onChanged: (v) => setState(() => date = v), allowClear: false),
        WChoiceChips<String>(
          label: 'Evidence',
          options: const [('user_reported', 'My word'), ('document_attached', 'I have a document'), ('provider_confirmation', 'Provider confirmed')],
          value: evidence,
          onChanged: (v) => setState(() => evidence = v),
        ),
        const SizedBox(height: 12),
        WChoiceChips<String>(
          label: 'Did Warrantra help with this?',
          options: const [('yes_significantly', 'A lot'), ('yes_somewhat', 'Somewhat'), ('no', 'No'), ('unsure', 'Not sure')],
          value: helped,
          onChanged: (v) => setState(() => helped = v),
        ),
        const SizedBox(height: 12),
        WField(label: 'Comment (optional)', controller: comment, maxLines: 2),
      ],
    );
  }
}

class OutcomesScreen extends ConsumerWidget {
  const OutcomesScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(outcomesProvider);
    final sum = ref.watch(outcomeSummaryProvider).value;
    final refunds = sum?.refunds.entries.map((e) => fmtMoney(e.value, currency: e.key)).join(' + ');
    final byType = sum?.byType ?? const <String, int>{};
    return WScreen(
      title: 'Outcomes',
      children: [
        WHeroCard(
          eyebrow: 'Outcomes · ${DateTime.now().year}',
          title: refunds == null || refunds.isEmpty ? 'No refunds yet' : refunds,
          icon: PhosphorIconsFill.trophy,
          children: [
            const SizedBox(height: 4),
            Text(refunds == null || refunds.isEmpty ? 'Record what happened when a return or claim finishes.' : 'Refunds you confirmed',
                style: WHeroCard.muted()),
            if (byType.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in byType.entries)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
                    child: Text('${e.value} · ${outcomeLabel(e.key)}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white)),
                  ),
              ]),
            ],
          ],
        ),
        const SizedBox(height: 22),
        AsyncBody<List<Outcome>>(
          value: list,
          onRetry: () => ref.invalidate(outcomesProvider),
          data: (os) => os.isEmpty
              ? const WEmpty(icon: PhosphorIconsRegular.chartBar, title: 'No outcomes yet', message: 'When a return or claim finishes, record what happened here.')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const WSectionHeader('History'),
                  for (final o in os) ...[_OutcomeCard(o), const SizedBox(height: 10)],
                  const SizedBox(height: 4),
                  const WNote("Only amounts you confirmed. Purchase value isn't counted as money saved.", icon: PhosphorIconsRegular.info),
                ]),
        ),
      ],
    );
  }
}

class _OutcomeCard extends StatelessWidget {
  const _OutcomeCard(this.o);
  final Outcome o;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final (icon, tint) = switch (o.type) {
      'refund_received' => (PhosphorIconsRegular.currencyCircleDollar, WTint.green),
      'repair_completed' => (PhosphorIconsRegular.wrench, WTint.blue),
      'replacement_received' => (PhosphorIconsRegular.arrowsClockwise, WTint.violet),
      'denied' => (PhosphorIconsRegular.xCircle, WTint.coral),
      _ => (PhosphorIconsRegular.minusCircle, WTint.amber),
    };
    final source = o.claimId != null ? 'Claim' : o.returnWindowId != null ? 'Return' : null;
    return WCard(
      onTap: o.claimId == null ? null : () => context.push('/claims/${o.claimId}'),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        WTintIcon(icon, tint),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(outcomeLabel(o.type), style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: c.text))),
              if (o.amount != null) Text(fmtMoney(o.amount, currency: o.currency ?? 'USD'), style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: tint)),
            ]),
            const SizedBox(height: 2),
            Text([fmtDate(o.date), ?source, evidenceLabel(o.evidence)].join(' · '), style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            if (o.helped != null) ...[
              const SizedBox(height: 8),
              WTag('Warrantra helped: ${titleCase(o.helped!.replaceAll('yes_', '').replaceAll('_', ' '))}', kind: WTagKind.outline),
            ],
          ]),
        ),
      ]),
    );
  }
}

String _packLabel(int n) => n == 0 ? 'Summary only' : 'Summary + $n document${n == 1 ? '' : 's'}';
