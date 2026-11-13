import 'dart:io';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:purchases_flutter/purchases_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../domain/billing.dart';

class RevenueCatBilling implements BillingGateway {
  bool _configured = false;

  String get _key => Platform.isIOS ? AppConfig.revenueCatAppleKey : AppConfig.revenueCatGoogleKey;

  @override
  bool get available => _key.isNotEmpty;

  @override
  Future<void> identify(String userId) async {
    if (!available) return;
    if (!_configured) {
      await Purchases.configure(PurchasesConfiguration(_key)..appUserID = userId);
      _configured = true;
    } else {
      await Purchases.logIn(userId);
    }
  }

  @override
  Future<void> reset() async {
    if (_configured) {
      try {
        await Purchases.logOut();
      } catch (_) {}
    }
  }

  Future<Offering?> _offering(String? id) async {
    final all = await Purchases.getOfferings();
    return (id == null ? null : all.getOffering(id)) ?? all.current;
  }

  @override
  Future<List<StorePackage>> packages({String? offering}) async {
    if (!available || !_configured) return const [];
    final off = await _offering(offering);
    if (off == null) return const [];
    final out = <StorePackage>[];
    final a = off.annual, m = off.monthly;
    if (a != null) {
      final perMonth = NumberFormat.simpleCurrency(name: a.storeProduct.currencyCode).format(a.storeProduct.price / 12);
      out.add(StorePackage(id: a.identifier, period: 'annual', priceLabel: a.storeProduct.priceString, pricePerMonthLabel: perMonth));
    }
    if (m != null) out.add(StorePackage(id: m.identifier, period: 'monthly', priceLabel: m.storeProduct.priceString));
    return out;
  }

  @override
  Future<PurchaseOutcome> buy(String packageId, {String? offering}) async {
    if (!available || !_configured) return PurchaseOutcome.unavailable;
    final off = await _offering(offering);
    final pkg = off?.availablePackages.where((p) => p.identifier == packageId).firstOrNull;
    if (pkg == null) return PurchaseOutcome.unavailable;
    try {
      await Purchases.purchase(PurchaseParams.package(pkg));
      return PurchaseOutcome.purchased;
    } on PlatformException catch (e) {
      if (PurchasesErrorHelper.getErrorCode(e) == PurchasesErrorCode.purchaseCancelledError) return PurchaseOutcome.cancelled;
      throw Failure('purchase_failed', e.message ?? 'The purchase could not be completed.');
    }
  }

  @override
  Future<void> restore() async {
    if (!available || !_configured) return;
    await Purchases.restorePurchases();
  }
}
