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
import 'upload_flow.dart';

/// Values carried into manual entry (from a product-label read or share-in).
class ManualPrefill {
  const ManualPrefill({this.name, this.brand, this.model, this.serial, this.categorySlug, this.warranty, this.attachmentIds = const [], this.source});
  final String? name, brand, model, serial, categorySlug, source;
  final Map<String, dynamic>? warranty;
  final List<String> attachmentIds;
}

class ManualEntryScreen extends ConsumerStatefulWidget {
  const ManualEntryScreen({super.key, this.attachmentId, this.prefill});
  final String? attachmentId;
  final ManualPrefill? prefill;
  @override
  ConsumerState<ManualEntryScreen> createState() => _ManualEntryScreenState();
}

class _ManualEntryScreenState extends ConsumerState<ManualEntryScreen> {
  late final p = widget.prefill;
  late final name = TextEditingController(text: p?.name ?? '');
  final price = TextEditingController();
  late final brand = TextEditingController(text: p?.brand ?? '');
  late final model = TextEditingController(text: p?.model ?? '');
  late final serial = TextEditingController(text: p?.serial ?? '');
  final retailer = TextEditingController();
  final order = TextEditingController();
  final notes = TextEditingController();
  DateTime? purchaseDate = DateTime.now();
  DateTime? deliveryDate;
  DateTime? returnDeadline;
  String? categoryId;
  late String currency = ref.read(meProvider).value?.profile.currency ?? 'USD';
  late String coverage = p?.warranty != null ? 'suggested' : 'unknown';
  bool more = false, saving = false, nameError = false;
  late final List<UploadedFile> files = [
    for (final id in {...?(widget.attachmentId == null ? null : [widget.attachmentId!]), ...?p?.attachmentIds}) UploadedFile(attachmentId: id, state: 'ready', filename: 'Attached document'),
  ];
  final _key = ApiClient.newIdempotencyKey();

  @override
  void initState() {
    super.initState();
    more = p?.brand != null || p?.model != null;
  }

  List<(String, String)> get _covChips => [
        ('unknown', 'Unknown'),
        if (p?.warranty != null) ('suggested', 'Suggested'),
        ('12', '1 year'),
        ('24', '2 years'),
        ('36', '3 years'),
        ('lifetime', 'Lifetime'),
      ];

  String? get _covNote {
    switch (coverage) {
      case 'unknown':
        return "Fine to leave unknown. We'll list it under Missing info.";
      case 'lifetime':
        return 'No end date. No expiry reminders.';
      case 'suggested':
        return '${p?.warranty?['prompt'] ?? 'Suggested from manufacturer information.'} Saved as Estimated.';
      default:
        final m = int.parse(coverage);
        final start = purchaseDate;
        if (start == null) return 'Saved as Estimated. Add the purchase date to calculate the end date.';
        final end = DateTime(start.year, start.month + m, start.day);
        return 'Saved as Estimated · ends ${fmtDate(end)}. Edit details later.';
    }
  }

  Map<String, dynamic>? get _warranty => switch (coverage) {
        'unknown' => null,
        'lifetime' => {'coverage_type': 'manufacturer', 'term_kind': 'lifetime', 'date_certainty': 'user_confirmed', 'source_kind': 'user_entry'},
        'suggested' => {
            'coverage_type': 'manufacturer',
            'provider_name': p!.warranty!['provider_name'],
            'term_kind': p!.warranty!['term_kind'] ?? 'duration',
            'duration_months': p!.warranty!['duration_months'],
            'start_anchor': 'purchase_date',
            'date_certainty': 'estimated',
            'accept_estimate': true,
            'source_kind': 'reference_suggestion',
            'source_reference_id': p!.warranty!['source_reference_id'],
          },
        _ => {
            'coverage_type': 'manufacturer',
            'provider_name': brand.text.trim().isEmpty ? null : brand.text.trim(),
            'term_kind': 'duration',
            'duration_months': int.parse(coverage),
            'start_anchor': 'purchase_date',
            'date_certainty': 'estimated',
            'accept_estimate': true,
            'source_kind': 'user_entry',
          },
      };

  Future<void> _attach() async {
    final src = await showWSheet<PickSource>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Add receipt or photo', style: ctx.t.titleLarge),
          const SizedBox(height: 8),
          WListRow(icon: PhosphorIconsRegular.camera, title: 'Take a photo', onTap: () => Navigator.pop(ctx, PickSource.camera)),
          WListRow(icon: PhosphorIconsRegular.image, title: 'Choose from photos', onTap: () => Navigator.pop(ctx, PickSource.gallery)),
          WListRow(icon: PhosphorIconsRegular.filePdf, title: 'Choose a file', onTap: () => Navigator.pop(ctx, PickSource.files)),
        ]));
    if (src == null || !mounted) return;
    PickedFile? f;
    try {
      f = await pickFile(src);
    } catch (e) {
      if (mounted) showUploadIssue(context, e);
      return;
    }
    if (f == null || !mounted) return;
    final up = await uploadWithProgress(context, ref, f, fileType: 'receipt');
    if (up != null) setState(() => files.add(up));
  }

  Future<void> _save() async {
    if (name.text.trim().isEmpty) return setState(() => nameError = true);
    setState(() => saving = true);
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      final body = <String, dynamic>{
        'name': name.text.trim(),
        'brand': t(brand),
        'model_number': t(model),
        'serial_number': t(serial),
        'category_id': categoryId,
        'retailer_name': t(retailer),
        'order_number': t(order),
        'purchase_date': isoDate(purchaseDate),
        'delivery_date': isoDate(deliveryDate),
        'purchase_price': normalizeMoney(price.text),
        'currency': currency,
        'notes': t(notes),
        'attachment_ids': files.map((f) => f.attachmentId).toList(),
        'warranties': [?_warranty],
        'return_window': returnDeadline == null
            ? null
            : {'retailer_name': t(retailer), 'terms_state': 'known', 'return_deadline': isoDate(returnDeadline), 'deadline_basis': 'request_by', 'date_certainty': 'user_confirmed', 'source_kind': 'user_entry'},
      }..removeWhere((k, v) => v == null);
      final res = await ref.read(itemsRepositoryProvider).quickAdd(body, idempotencyKey: _key);
      ref.refreshItems();
      if (!mounted) return;
      showToast(context, 'Purchase saved');
      final id = res.itemIds.isEmpty ? null : res.itemIds.first;
      if (id != null) {
        context.pushReplacement('/items/$id');
      } else {
        context.pop();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final cats = ref.watch(categoriesProvider).value ?? const [];
    if (categoryId == null && p?.categorySlug != null) {
      final match = cats.where((x) => x.slug == p!.categorySlug);
      if (match.isNotEmpty) categoryId = match.first.id;
    }
    return WScreen(
      title: 'Add purchase',
      close: true,
      bottom: WButton('Save purchase', loading: saving, onPressed: _save),
      children: [
        WField(label: 'Product name', controller: name, hint: 'e.g. Vitamix 5200', error: nameError ? 'Add a product name to save.' : null, onChanged: (_) => nameError ? setState(() => nameError = false) : null),
        WDateField(label: 'Purchase date', value: purchaseDate, onChanged: (v) => setState(() => purchaseDate = v)),
        WField(label: 'Price ($currency)', controller: price, hint: '0.00', keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        WChoiceChips<String>(label: 'Coverage', options: _covChips, value: coverage, onChanged: (v) => setState(() => coverage = v)),
        if (_covNote != null) Padding(padding: const EdgeInsets.only(top: 6, bottom: 8), child: Text(_covNote!, style: TextStyle(fontSize: 12.5, color: c.textMuted))),
        const SizedBox(height: 8),
        for (final f in files)
          WListRow(icon: PhosphorIconsRegular.paperclip, title: f.filename ?? 'Document', subtitle: 'Attached', caret: false, trailing: IconButton(icon: const Icon(PhosphorIconsRegular.x, size: 18), onPressed: () => setState(() => files.remove(f)))),
        WButton.secondary('Add receipt or photo', icon: PhosphorIconsRegular.paperclip, onPressed: _attach),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text('JPEG, PNG, HEIC, PDF · 10 MB', textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: c.textSubtle))),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => setState(() => more = !more),
          icon: Icon(more ? PhosphorIconsRegular.caretUp : PhosphorIconsRegular.caretDown, size: 16),
          label: const Text('More details'),
        ),
        if (more) ...[
          WField(label: 'Brand', controller: brand),
          WField(label: 'Model', controller: model),
          WField(label: 'Serial', controller: serial),
          WField(label: 'Retailer', controller: retailer),
          WField(label: 'Order number', controller: order),
          WDateField(label: 'Delivery date', value: deliveryDate, onChanged: (v) => setState(() => deliveryDate = v)),
          if (cats.isNotEmpty)
            WChoiceChips<String>(label: 'Category', options: [for (final x in cats) (x.id, x.name)], value: categoryId, onChanged: (v) => setState(() => categoryId = v)),
          const SizedBox(height: 8),
          WChoiceChips<String>(label: 'Currency', options: const [('USD', 'USD'), ('CAD', 'CAD'), ('GBP', 'GBP')], value: currency, onChanged: (v) => setState(() => currency = v)),
          const SizedBox(height: 8),
          WDateField(label: 'Return deadline', value: returnDeadline, hint: "Unknown · we won't assume 30 days", onChanged: (v) => setState(() => returnDeadline = v)),
          WField(label: 'Notes', controller: notes, maxLines: 3),
        ],
      ],
    );
  }
}
