import 'dart:async';
import 'dart:io';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:intl/intl.dart';

import '../../../core/errors/failure.dart';
import '../../../core/network/api_client.dart';
import '../domain/billing.dart';

/// Google Play Billing, directly. Every purchase token goes to our server, which
/// checks it with Google, grants Pro and acknowledges it; only then is the
/// purchase completed on the phone. Base plans `monthly` and `annual` live on
/// the Play subscription [productId].
class PlayBilling implements BillingGateway {
  PlayBilling(this._api);
  final ApiClient _api;

  static const productId = 'warrantra_pro';
  final _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  String? _userId;
  Completer<PurchaseOutcome>? _pending;
  final _inFlight = <Future<void>>{};
  Object? _restoreError;
  List<GooglePlayProductDetails> _products = const [];

  @override
  bool get available => Platform.isAndroid;

  @override
  Future<void> identify(String userId) async {
    _userId = userId;
    if (!available) return;
    // Purchases that finished while the app was closed arrive on this stream too.
    _sub ??= _iap.purchaseStream.listen(_onUpdates, onError: (Object e) => _pending?.completeError(e));
  }

  @override
  Future<void> reset() async {
    _userId = null;
    _products = const [];
  }

  Future<List<GooglePlayProductDetails>> _load() async {
    if (!await _iap.isAvailable()) return const [];
    final r = await _iap.queryProductDetails({productId});
    _products = r.productDetails.whereType<GooglePlayProductDetails>().toList();
    return _products;
  }

  /// One entry per base plan, ignoring promotional offers on top of it.
  GooglePlayProductDetails? _plan(String basePlan) {
    for (final p in _products) {
      final i = p.subscriptionIndex;
      final o = i == null ? null : p.productDetails.subscriptionOfferDetails?[i];
      if (o != null && o.basePlanId == basePlan && o.offerId == null) return p;
    }
    return null;
  }

  @override
  Future<List<StorePackage>> packages({String? offering}) async {
    if (!available) return const [];
    await _load();
    final out = <StorePackage>[];
    final a = _plan('annual'), m = _plan('monthly');
    if (a != null) {
      final perMonth = NumberFormat.simpleCurrency(name: a.currencyCode).format(a.rawPrice / 12);
      out.add(StorePackage(id: 'annual', period: 'annual', priceLabel: a.price, pricePerMonthLabel: perMonth));
    }
    if (m != null) out.add(StorePackage(id: 'monthly', period: 'monthly', priceLabel: m.price));
    return out;
  }

  @override
  Future<PurchaseOutcome> buy(String packageId, {String? offering}) async {
    if (!available || _userId == null) return PurchaseOutcome.unavailable;
    if (_products.isEmpty) await _load();
    final p = _plan(packageId);
    if (p == null) return PurchaseOutcome.unavailable;
    _pending = Completer<PurchaseOutcome>();
    final started = await _iap.buyNonConsumable(
      // The account id travels with the purchase so the server can match renewals to this user.
      purchaseParam: GooglePlayPurchaseParam(productDetails: p, applicationUserName: _userId, offerToken: p.offerToken),
    );
    if (!started) {
      _pending = null;
      return PurchaseOutcome.unavailable;
    }
    return _pending!.future;
  }

  @override
  Future<void> restore() async {
    if (!available) return;
    await _iap.restorePurchases();
    // Restored purchases are delivered on the stream; give them a moment, then wait for the server.
    _restoreError = null;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await Future.wait(_inFlight.toList());
    // e.g. the subscription belongs to another Warrantra account: say so.
    final err = _restoreError;
    _restoreError = null;
    if (err != null) throw err;
  }

  void _onUpdates(List<PurchaseDetails> updates) {
    for (final d in updates) {
      final f = _handle(d);
      _inFlight.add(f);
      f.whenComplete(() => _inFlight.remove(f));
    }
  }

  Future<void> _handle(PurchaseDetails d) async {
    switch (d.status) {
      case PurchaseStatus.pending:
        return;
      case PurchaseStatus.canceled:
        _finish(PurchaseOutcome.cancelled);
        if (d.pendingCompletePurchase) await _iap.completePurchase(d);
        return;
      case PurchaseStatus.error:
        if (d.pendingCompletePurchase) await _iap.completePurchase(d);
        final why = '${d.error?.message} ${d.error?.details}'.toLowerCase();
        if (_pending != null && (why.contains('alreadyowned') || why.contains('already_owned') || why.contains('already own'))) {
          await _resolveAlreadyOwned();
          return;
        }
        _fail(Failure('purchase_failed', d.error?.message ?? 'The purchase could not be completed.'));
        return;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        try {
          await _api.post<Map<String, dynamic>>('/me/purchases/google-play',
              body: {'purchase_token': d.verificationData.serverVerificationData, 'product_id': d.productID});
          if (d.pendingCompletePurchase) await _iap.completePurchase(d);
          _finish(PurchaseOutcome.purchased);
        } catch (e) {
          // Not completed: Google keeps redelivering it, and the server retries on restore.
          if (_pending == null) _restoreError = e; // surfaced by restore()
          _fail(e);
        }
    }
  }

  /// Google Play says this Play account already has the subscription. Find it
  /// and ask our server: if it belongs to this Warrantra account Pro turns on
  /// (e.g. after a reinstall); if it belongs to another account the server says
  /// which one (purchase_owned_by_other_account).
  Future<void> _resolveAlreadyOwned() async {
    try {
      final addition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final past = await addition.queryPastPurchases();
      final mine = past.pastPurchases.where((p) => p.productID == productId).toList();
      if (mine.isEmpty) {
        _fail(const Failure('already_subscribed',
            'This Google Play account already has a Warrantra subscription. Open Google Play → Payments & subscriptions to check it.'));
        return;
      }
      for (final p in mine) {
        await _api.post<Map<String, dynamic>>('/me/purchases/google-play',
            body: {'purchase_token': p.verificationData.serverVerificationData, 'product_id': p.productID});
      }
      _finish(PurchaseOutcome.purchased);
    } catch (e) {
      _fail(e);
    }
  }

  void _finish(PurchaseOutcome o) {
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) c.complete(o);
  }

  void _fail(Object e) {
    final c = _pending;
    _pending = null;
    if (c != null && !c.isCompleted) c.completeError(e);
  }
}
