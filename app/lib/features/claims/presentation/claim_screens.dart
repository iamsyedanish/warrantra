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
                  if (p.url != null) await launchUrl(Uri.parse(p.url!), mode: LaunchMode.externalApplication);
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
            WDateField(label: 'Follow up on', value: follow, onChanged: (v) => set(() => follow = v)),
            WButton('Save', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ));
    if (ok != true) return;
    try {
      await ref.read(claimsRepositoryProvider).update(cl.id, {'claim_number': number.text.trim().isEmpty ? null : number.text.trim(), 'status': status, 'follow_up_on': isoDate(follow)}, version: cl.version);
      ref.invalidate(claimProvider(cl.id));
      ref.invalidate(claimsProvider);
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
                row(packed, 'Pack prepared', cl.packs.isEmpty ? null : fmtDate(cl.packs.first.generatedAt)),
                row(cl.sent, 'Sent to provider', cl.submittedAt == null ? null : '${fmtDate(cl.submittedAt)} · you marked', next: packed && !cl.sent),
                if (cl.outcome == null) ...[
                  row(false, 'Follow up', cl.followUpOn == null ? null : '${fmtDate(cl.followUpOn)} · reminder set', next: cl.sent),
                  row(false, 'Outcome', null),
                ] else
                  row(true, outcomeLabel(cl.outcome!.type), '${fmtDate(cl.outcome!.date)} · ${evidenceLabel(cl.outcome!.evidence)}'),
              ]),
            ),
            const SizedBox(height: 10),
            Text('A snapshot of the product and coverage facts is kept with this claim, so it stays readable even if you delete the item.',
                style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.4)),
            if (cl.reviewedFacts != null) ...[
              const WSectionHeader('Facts in the pack'),
              FactsCard(facts: cl.reviewedFacts!, issue: cl.issue, startedOn: cl.issueStartedOn),
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
          data: (list) => list.isEmpty
              ? const WEmpty(icon: PhosphorIconsRegular.lifebuoy, title: 'No claims yet', message: 'Start a claim from an item when something goes wrong. Warrantra assembles the facts; you send it.')
              : Column(children: [
                  for (final cl in list)
                    WListRow(
                      icon: PhosphorIconsRegular.chatCircleText,
                      title: cl.itemLabel,
                      subtitle: [claimKindLabel(cl.kind), claimStatusLabel(cl.status), if (cl.followUpOn != null && !cl.closed) 'follow up ${fmtDayShort(cl.followUpOn)}'].join(' · '),
                      onTap: () => context.push('/claims/${cl.id}'),
                    ),
                ]),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Outcome form & ledger
// ---------------------------------------------------------------------------
class OutcomeFormScreen extends ConsumerStatefulWidget {
  const OutcomeFormScreen({super.key, this.claimId, this.returnId});
  final String? claimId, returnId;
  @override
  ConsumerState<OutcomeFormScreen> createState() => _OutcomeFormScreenState();
}

class _OutcomeFormScreenState extends ConsumerState<OutcomeFormScreen> {
  late String type = widget.returnId != null ? 'refund_received' : 'repair_completed';
  final amount = TextEditingController();
  DateTime? date = DateTime.now();
  String evidence = 'user_reported';
  String? helped;
  final comment = TextEditingController();
  bool saving = false;

  bool get hasAmount => type == 'refund_received';

  Future<void> _save() async {
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
        WDateField(label: 'Date', value: date, onChanged: (v) => setState(() => date = v), allowClear: false),
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
    final c = context.w;
    final list = ref.watch(outcomesProvider);
    final sum = ref.watch(outcomeSummaryProvider).value;
    final refunds = sum?.refunds.entries.map((e) => fmtMoney(e.value, currency: e.key)).join(' + ');
    return WScreen(
      title: 'Outcomes',
      children: [
        WCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Confirmed refunds · ${DateTime.now().year}', style: TextStyle(color: c.textMuted)),
            const SizedBox(height: 4),
            Text(refunds == null || refunds.isEmpty ? fmtMoney(0) : refunds, style: context.t.headlineMedium),
            const SizedBox(height: 4),
            Text("Only amounts you confirmed. Purchase value isn't counted as money saved.", style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          ]),
        ),
        const SizedBox(height: 10),
        AsyncBody<List<Outcome>>(
          value: list,
          onRetry: () => ref.invalidate(outcomesProvider),
          data: (os) => os.isEmpty
              ? const WEmpty(icon: PhosphorIconsRegular.chartBar, title: 'No outcomes yet', message: 'When a return or claim finishes, record what happened here.')
              : Column(children: [
                  for (final o in os)
                    WCard(
                      onTap: o.claimId == null ? null : () => context.push('/claims/${o.claimId}'),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(outcomeLabel(o.type), style: TextStyle(fontWeight: FontWeight.w500, color: c.text))),
                          if (o.amount != null) Text(fmtMoney(o.amount, currency: o.currency ?? 'USD'), style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
                        ]),
                        Text('${fmtDate(o.date)} · ${evidenceLabel(o.evidence)}${o.claimId != null ? ' · claim' : o.returnWindowId != null ? ' · return' : ''}', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                        if (o.helped != null) Text('Warrantra helped: ${titleCase(o.helped!.replaceAll('yes_', ''))}', style: TextStyle(fontSize: 12, color: c.textSubtle)),
                      ]),
                    ),
                ].expand((w) => [w, const SizedBox(height: 8)]).toList()),
        ),
      ],
    );
  }
}

String _packLabel(int n) => n == 0 ? 'Summary only' : 'Summary + $n document${n == 1 ? '' : 's'}';
