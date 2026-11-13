import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../auth/presentation/session_controller.dart';
import '../data/cards_repository_impl.dart';
import '../domain/cards.dart';

final cardsRepositoryProvider = Provider<CardsRepository>((ref) => CardsRepositoryImpl(ref.watch(apiClientProvider)));

final paymentCardsProvider = FutureProvider<List<PaymentCard>>((ref) {
  ref.watch(sessionEpochProvider);
  return ref.watch(cardsRepositoryProvider).list();
});

final cardBenefitsProvider = FutureProvider<List<CardBenefit>>((ref) => ref.watch(cardsRepositoryProvider).benefits());
