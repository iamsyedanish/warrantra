/// Account domain entities and repository contract.
class Profile {
  const Profile({
    required this.id,
    required this.email,
    required this.displayName,
    required this.timezone,
    required this.alertTime,
    required this.preferences,
    required this.aiConsent,
    required this.analyticsConsent,
    required this.country,
    required this.currency,
    required this.onboardingCompleted,
    this.aiSuspendedUntil,
    this.aiSuspensionReason,
  });
  final String id;
  final String email;
  final String displayName;
  final String timezone;
  final String alertTime; // HH:MM:SS
  final Map<String, dynamic> preferences;
  final bool aiConsent;
  final bool analyticsConsent;
  final String country;
  final String currency;
  final bool onboardingCompleted;
  final DateTime? aiSuspendedUntil;
  final String? aiSuspensionReason;

  String get name => displayName.isNotEmpty ? displayName : email.split('@').first;
  bool get aiSuspended => aiSuspendedUntil != null && aiSuspendedUntil!.isAfter(DateTime.now());

  List<int> offsets(String key, List<int> fallback) {
    final p = preferences[key];
    if (p is Map && p['offsets_days'] is List) return (p['offsets_days'] as List).whereType<num>().map((n) => n.toInt()).toList();
    return fallback;
  }

  bool prefEnabled(String key) {
    final p = preferences[key];
    return p is Map ? p['enabled'] != false : true;
  }
}

class PlanInfo {
  const PlanInfo({
    required this.code,
    required this.maxItems,
    required this.storageBytes,
    required this.aiPerMonth,
    required this.aiTrial,
    required this.claimPackAssembled,
    required this.aiClaimDraft,
    required this.workspaces,
    required this.emailForwarding,
    this.state,
    this.renewalIntent,
    this.validUntil,
    this.store,
  });
  final String code;
  final int maxItems;
  final int storageBytes;
  final int aiPerMonth;
  final int aiTrial;
  final bool claimPackAssembled;
  final bool aiClaimDraft;
  final bool workspaces;
  final bool emailForwarding;
  final String? state;
  final String? renewalIntent;
  final DateTime? validUntil;
  final String? store;

  bool get isPro => code != 'free';
  String get name => switch (code) { 'pro' => 'Pro', 'business_pilot' => 'Business pilot', _ => 'Free' };
  bool get willNotRenew => renewalIntent == 'will_not_renew';
}

class Usage {
  const Usage({
    required this.itemsUsed,
    required this.itemsLimit,
    required this.storageUsed,
    required this.storageLimit,
    required this.aiUsed,
    required this.aiLimit,
    required this.aiPeriod,
    required this.additionsPaused,
  });
  final int itemsUsed, itemsLimit, storageUsed, storageLimit, aiUsed, aiLimit;
  final String aiPeriod;
  final bool additionsPaused;
  int get aiLeft => (aiLimit - aiUsed).clamp(0, 1 << 30);
  bool get nearItemLimit => itemsLimit > 0 && itemsUsed >= (itemsLimit * 0.8).floor();
}

class TimezoneHint {
  const TimezoneHint(this.deviceTimezone, this.message);
  final String deviceTimezone;
  final String message;
}

class Me {
  const Me({required this.profile, required this.plan, required this.usage, this.timezoneHint});
  final Profile profile;
  final PlanInfo plan;
  final Usage usage;
  final TimezoneHint? timezoneHint;
}

class PriceOffer {
  const PriceOffer({this.experiment, this.code, this.label, this.annualPrice, this.monthlyPrice, this.offering});
  final String? experiment, code, label, offering;
  final double? annualPrice, monthlyPrice;
}

abstract interface class AccountRepository {
  Future<Me> me();
  Future<void> updateProfile(Map<String, dynamic> patch);
  Future<void> setAiConsent(bool granted);
  Future<PriceOffer> offer();
  Future<void> restorePurchases();
  Future<void> registerDevice({required String installationId, required String platform, required String permission, String? pushToken, String? appVersion, String? timezone});
}
