import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../domain/cards.dart';
import 'cards_providers.dart';

class CardsScreen extends ConsumerStatefulWidget {
  const CardsScreen({super.key});
  @override
  ConsumerState<CardsScreen> createState() => _CardsScreenState();
}

class _CardsScreenState extends ConsumerState<CardsScreen> {
  final name = TextEditingController();
  String? benefitId;
  bool busy = false;

  Future<void> _add() async {
    final n = name.text.trim();
    if (n.isEmpty) return;
    if (RegExp(r'\d{12,}').hasMatch(n.replaceAll(RegExp(r'[\s.-]'), ''))) return showToast(context, 'Never enter card numbers. Use a nickname.');
    setState(() => busy = true);
    try {
      await ref.read(cardsRepositoryProvider).add(nickname: n, benefitId: benefitId);
      name.clear();
      benefitId = null;
      ref.invalidate(paymentCardsProvider);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final cards = ref.watch(paymentCardsProvider);
    final benefits = ref.watch(cardBenefitsProvider).value ?? const <CardBenefit>[];
    return WScreen(title: 'Payment cards', children: [
      Text('Card nicknames', style: context.t.titleLarge),
      Text("Tag purchases with the card you used, so you can check that card's benefits later.", style: TextStyle(color: c.textMuted)),
      const SizedBox(height: 10),
      const WNote('Labels only. Never enter a card number, expiry date or security code.', icon: PhosphorIconsRegular.lockSimple),
      const SizedBox(height: 12),
      AsyncBody<List<PaymentCard>>(
        value: cards,
        data: (list) => Column(children: [
          for (final k in list)
            WListRow(
              icon: PhosphorIconsRegular.creditCard,
              title: k.nickname,
              subtitle: k.benefitName == null ? null : 'May include: ${k.benefitName}',
              caret: false,
              trailing: TextButton(
                onPressed: () async {
                  await ref.read(cardsRepositoryProvider).remove(k.id);
                  ref.invalidate(paymentCardsProvider);
                },
                child: const Text('Remove'),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 8),
      WField(label: 'Nickname', controller: name, hint: 'e.g. Costco Visa · Household'),
      if (benefits.isNotEmpty)
        WChoiceChips<String?>(
          label: 'Matches a known card (optional)',
          options: [(null, 'None'), for (final b in benefits) (b.id, b.label)],
          value: benefitId,
          onChanged: (v) => setState(() => benefitId = v),
        ),
      const SizedBox(height: 10),
      WButton('Add', loading: busy, onPressed: _add),
      const SizedBox(height: 10),
      Text("When a label matches a card with a known benefit, we'll say it may apply and link the official terms. We won't say it does.",
          style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.4)),
    ]);
  }
}
