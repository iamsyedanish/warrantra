import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../cards/presentation/cards_providers.dart';
import '../domain/items.dart';
import 'items_providers.dart';

class EditItemScreen extends ConsumerWidget {
  const EditItemScreen({super.key, required this.itemId});
  final String itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(itemDetailProvider(itemId));
    return d.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Edit item', children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox())]),
      data: (item) => _Form(item),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form(this.item);
  final ItemDetail item;
  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  late final d = widget.item;
  late final s = d.summary;
  late final name = TextEditingController(text: s.name);
  late final brand = TextEditingController(text: s.brand ?? '');
  late final model = TextEditingController(text: s.model ?? '');
  late final serial = TextEditingController(text: d.serial ?? '');
  late final retailer = TextEditingController(text: s.retailer ?? '');
  late final order = TextEditingController(text: d.orderNumber ?? '');
  late final price = TextEditingController(text: s.price ?? '');
  late final notes = TextEditingController(text: d.notes ?? '');
  late DateTime? purchased = parseDate(s.purchaseDate);
  late DateTime? delivered = parseDate(d.deliveryDate);
  late String currency = s.currency;
  late String condition = d.condition;
  late String? categoryId = d.categoryId;
  late String? cardId = d.paymentCardId;
  bool saving = false;

  Future<void> _save() async {
    if (name.text.trim().isEmpty) return showToast(context, 'Add a product name.');
    setState(() => saving = true);
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    try {
      await ref.read(itemsRepositoryProvider).update(s.id, {
        'name': name.text.trim(),
        'brand': t(brand),
        'model_number': t(model),
        'serial_number': t(serial),
        'retailer_name': t(retailer),
        'order_number': t(order),
        'purchase_date': isoDate(purchased),
        'delivery_date': isoDate(delivered),
        'purchase_price': normalizeMoney(price.text),
        'currency': currency,
        'condition_at_purchase': condition,
        'category_id': categoryId,
        'payment_card_id': cardId,
        'notes': t(notes),
      }, version: d.version);
      ref.refreshItems(itemId: s.id);
      if (mounted) {
        context.pop();
        showToast(context, 'Saved');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = ref.watch(categoriesProvider).value ?? const [];
    final cards = ref.watch(paymentCardsProvider).value ?? const [];
    return WScreen(
      title: 'Edit item',
      close: true,
      bottom: WButton('Save changes', loading: saving, onPressed: _save),
      children: [
        WField(label: 'Product name', controller: name),
        WField(label: 'Brand', controller: brand),
        WField(label: 'Model', controller: model),
        WField(label: 'Serial', controller: serial, hint: 'Not recorded'),
        if (cats.isNotEmpty) ...[
          WChoiceChips<String>(label: 'Category', options: [for (final c in cats) (c.id, c.name)], value: categoryId, onChanged: (v) => setState(() => categoryId = v)),
          const SizedBox(height: 10),
        ],
        WField(label: 'Retailer', controller: retailer),
        WField(label: 'Order number', controller: order),
        WDateField(label: 'Purchase date', value: purchased, onChanged: (v) => setState(() => purchased = v)),
        WDateField(label: 'Delivery date', value: delivered, onChanged: (v) => setState(() => delivered = v)),
        WField(label: 'Line price', controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
        WChoiceChips<String>(label: 'Currency', options: const [('USD', 'USD'), ('CAD', 'CAD'), ('GBP', 'GBP')], value: currency, onChanged: (v) => setState(() => currency = v)),
        const SizedBox(height: 10),
        WChoiceChips<String?>(
          label: 'Paid with (label only)',
          options: [(null, 'Not recorded'), for (final c in cards) (c.id, c.nickname)],
          value: cardId,
          onChanged: (v) => setState(() => cardId = v),
        ),
        const SizedBox(height: 10),
        WChoiceChips<String>(
          label: 'Condition when bought',
          options: const [('new', 'New'), ('open_box', 'Open box'), ('refurbished', 'Refurbished'), ('used', 'Used'), ('unknown', 'Unknown')],
          value: condition,
          onChanged: (v) => setState(() => condition = v),
        ),
        const SizedBox(height: 10),
        WField(label: 'Notes', controller: notes, maxLines: 3),
        const WNote('Changing the purchase or delivery date moves any return windows and coverage that count from it, and their reminders.', icon: PhosphorIconsRegular.info),
      ],
    );
  }
}
