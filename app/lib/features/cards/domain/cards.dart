/// Payment-card labels (never card numbers) and their reviewed benefit references.
class PaymentCard {
  const PaymentCard({required this.id, required this.nickname, this.issuer, this.network, this.benefitId, this.benefitName});
  final String id, nickname;
  final String? issuer, network, benefitId, benefitName;
}

class CardBenefit {
  const CardBenefit({required this.id, required this.issuer, required this.cardName, this.extensionMonths, this.maxOriginalMonths, this.enrollmentRequired = false, this.sourceUrl, this.lastVerified});
  final String id, issuer, cardName;
  final int? extensionMonths, maxOriginalMonths;
  final bool enrollmentRequired;
  final String? sourceUrl, lastVerified;
  String get label => '$issuer $cardName';
}

abstract interface class CardsRepository {
  Future<List<PaymentCard>> list();
  Future<List<CardBenefit>> benefits();
  Future<void> add({required String nickname, String? issuer, String? network, String? benefitId});
  Future<void> update(String id, Map<String, dynamic> patch);
  Future<void> remove(String id);
}
