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
import '../../items/presentation/items_providers.dart';
import '../domain/capture.dart';
import 'capture_providers.dart';

/// Step 1 of 2: check every extracted field, choose the lines to track.
class ReviewScreen extends ConsumerWidget {
  const ReviewScreen({super.key, required this.scanId, this.attachmentId});
  final String scanId;
  final String? attachmentId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanProvider(scanId));
    return scan.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Review receipt', children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox(), onRetry: () => ref.invalidate(scanProvider(scanId)))]),
      data: (job) => job.receipt == null
          ? WScreen(title: 'Review receipt', children: const [WNote('Nothing to review. The read may have expired; enter the purchase manually.')])
          : _ReviewForm(job: job, draft: job.receipt!, attachmentId: attachmentId ?? job.attachmentId),
    );
  }
}

class _Line {
  _Line(this.src) : name = TextEditingController(text: src.description ?? ''), amount = TextEditingController(text: src.lineAmount ?? src.unitAmount ?? '');
  final DraftLine src;
  final TextEditingController name, amount;
  bool on = true;
}

class _ReviewForm extends ConsumerStatefulWidget {
  const _ReviewForm({required this.job, required this.draft, this.attachmentId});
  final ScanJob job;
  final ReceiptDraft draft;
  final String? attachmentId;
  @override
  ConsumerState<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends ConsumerState<_ReviewForm> {
  late final merchant = TextEditingController(text: widget.draft.merchant.value ?? '');
  late final order = TextEditingController(text: widget.draft.orderNumber.value ?? '');
  late final total = TextEditingController(text: widget.draft.total.value ?? '');
  late DateTime? purchaseDate = parseDate(widget.draft.purchaseDate.value);
  late DateTime? deliveryDate = parseDate(widget.draft.deliveryDate.value);
  late String currency = widget.draft.currency.value ?? ref.read(meProvider).value?.profile.currency ?? 'USD';
  late final lines = widget.draft.lines.isEmpty ? [_Line(const DraftLine(index: 0))] : widget.draft.lines.map(_Line.new).toList();
  final _key = ApiClient.newIdempotencyKey();
  bool saving = false;

  String _evidence(DraftField f) => switch (f.status) {
        'extracted' => f.evidence == null ? 'Found on the document' : '“${f.evidence}”',
        'rejected' => 'Could not be verified, left empty',
        _ => 'Not found, left empty',
      };

  Future<void> _save() async {
    final chosen = lines.where((l) => l.on && l.name.text.trim().isNotEmpty).toList();
    if (chosen.isEmpty) return showToast(context, 'Choose at least one line to track and give it a name.');
    setState(() => saving = true);
    final d = widget.draft;
    try {
      final body = <String, dynamic>{
        'retailer': merchant.text.trim().isEmpty ? null : merchant.text.trim(),
        'order_number': order.text.trim().isEmpty ? null : order.text.trim(),
        'purchase_date': isoDate(purchaseDate),
        'delivery_date': isoDate(deliveryDate),
        'currency': currency,
        'subtotal': d.subtotal.value,
        'tax': d.tax.value,
        'shipping': d.shipping.value,
        'discount': d.discount.value,
        'total_paid': normalizeMoney(total.text),
        'source': 'receipt_scan',
        'scan_job_id': widget.job.id,
        'attachment_ids': [?widget.attachmentId],
        'lines': [
          for (final l in lines)
            {
              'original_description': l.src.description,
              'confirmed_name': l.name.text.trim().isEmpty ? null : l.name.text.trim(),
              'sku': l.src.sku,
              'quantity': l.src.quantity ?? 1,
              'unit_amount': l.src.unitAmount,
              'line_amount': normalizeMoney(l.amount.text),
              'confirmation_state': !l.on ? 'excluded' : (l.name.text.trim() != (l.src.description ?? '') ? 'user_edited' : 'user_confirmed'),
              'track': l.on && l.name.text.trim().isNotEmpty ? {'name': l.name.text.trim(), 'attachment_ids': [?widget.attachmentId]} : null,
            }
        ],
      };
      final res = await ref.read(itemsRepositoryProvider).savePurchase(body, idempotencyKey: _key);
      ref.refreshItems();
      if (!mounted) return;
      final mentions = [...d.returnMentions.map((m) => 'Return: ${m.text}'), ...d.warrantyMentions.map((m) => 'Warranty: ${m.text}')];
      context.pushReplacement('/capture/coverage', extra: CoverageSetupArgs(itemIds: res.itemIds, retailer: merchant.text.trim(), mentions: mentions, warnings: res.warnings));
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final d = widget.draft;
    final n = lines.where((l) => l.on).length;
    return WScreen(
      title: 'Review receipt · Step 1 of 2',
      bottom: WButton(n == 0 ? 'Choose at least one line' : 'Continue with $n item${n == 1 ? '' : 's'}', loading: saving, onPressed: n == 0 ? null : _save),
      children: [
        WNote('Nothing is saved until you confirm. Check each field against the receipt.', icon: PhosphorIconsRegular.eye),
        const SizedBox(height: 14),
        WField(label: 'Merchant', controller: merchant, helper: _evidence(d.merchant)),
        WDateField(label: 'Purchase date', value: purchaseDate, onChanged: (v) => setState(() => purchaseDate = v), helper: _evidence(d.purchaseDate)),
        WField(label: 'Order / transaction number', controller: order, helper: _evidence(d.orderNumber)),
        WDateField(label: 'Delivery date', value: deliveryDate, onChanged: (v) => setState(() => deliveryDate = v), hint: 'Not found', helper: _evidence(d.deliveryDate)),
        WChoiceChips<String>(label: 'Currency', options: const [('USD', 'USD'), ('CAD', 'CAD'), ('GBP', 'GBP')], value: currency, onChanged: (v) => setState(() => currency = v)),
        const SizedBox(height: 8),
        WSectionHeader('Lines · choose what to track', action: '$n of ${lines.length}'),
        for (final l in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: WCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Checkbox(value: l.on, onChanged: (v) => setState(() => l.on = v ?? false)),
                  Expanded(child: TextField(controller: l.name, decoration: const InputDecoration(hintText: 'Item name', isDense: true))),
                  const SizedBox(width: 8),
                  SizedBox(width: 90, child: TextField(controller: l.amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(hintText: 'Amount', isDense: true))),
                ]),
                if (l.src.evidence != null || l.src.description != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 4),
                    child: Text([if (l.src.description != null) l.src.description!, if (l.src.quantity != null && l.src.quantity != 1) 'qty ${l.src.quantity}', if (l.src.sku != null) 'SKU ${l.src.sku}'].join(' · '),
                        style: TextStyle(fontSize: 12, color: c.textSubtle)),
                  ),
              ]),
            ),
          ),
        TextButton.icon(
          onPressed: () => setState(() => lines.add(_Line(DraftLine(index: lines.length)))),
          icon: const Icon(PhosphorIconsRegular.plus, size: 16),
          label: const Text('Add a line the read missed'),
        ),
        const SizedBox(height: 6),
        WCard(
          child: Column(children: [
            if (d.subtotal.value != null) WKeyValue('Subtotal', fmtMoney(d.subtotal.value, currency: currency)),
            if (d.tax.value != null) WKeyValue('Tax', fmtMoney(d.tax.value, currency: currency)),
            if (d.shipping.value != null) WKeyValue('Shipping', fmtMoney(d.shipping.value, currency: currency)),
            if (d.discount.value != null) WKeyValue('Discount', '−${fmtMoney(d.discount.value, currency: currency)}'),
            WField(label: 'Total paid', controller: total, keyboardType: const TextInputType.numberWithOptions(decimal: true), helper: _evidence(d.total)),
          ]),
        ),
        const SizedBox(height: 6),
        Text('Stored once on the purchase. Items get their own line amount, not the receipt total.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
        const SizedBox(height: 10),
        if (d.returnMentions.isEmpty) WNote("The return policy isn't printed on this receipt. You can add it next or leave it unknown.", icon: PhosphorIconsRegular.warning),
        for (final w in d.warnings) Padding(padding: const EdgeInsets.only(top: 6), child: WNote(w, icon: PhosphorIconsRegular.warningCircle)),
      ],
    );
  }
}

class CoverageSetupArgs {
  const CoverageSetupArgs({required this.itemIds, this.retailer, this.mentions = const [], this.warnings = const []});
  final List<String> itemIds;
  final String? retailer;
  final List<String> mentions, warnings;
}
