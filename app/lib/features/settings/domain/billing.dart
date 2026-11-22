/// Store purchases. The server (Google Play API + real-time notifications) is the
/// source of truth for entitlement; the app starts purchases and hands it the tokens.
class StorePackage {
  const StorePackage({required this.id, required this.period, required this.priceLabel, this.pricePerMonthLabel});
  final String id, period, priceLabel; // period: annual | monthly
  final String? pricePerMonthLabel;
}

enum PurchaseOutcome { purchased, cancelled, unavailable }

abstract interface class BillingGateway {
  bool get available;
  Future<void> identify(String userId);
  Future<void> reset();
  Future<List<StorePackage>> packages({String? offering});
  Future<PurchaseOutcome> buy(String packageId, {String? offering});
  Future<void> restore();
}
