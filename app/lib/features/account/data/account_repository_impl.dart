import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/account.dart';

class AccountRepositoryImpl implements AccountRepository {
  AccountRepositoryImpl(this._api);
  final ApiClient _api;

  @override
  Future<Me> me() async => meFromJson(await _api.get<Json>('/me'));

  @override
  Future<void> updateProfile(Map<String, dynamic> patch) => _api.patch<Json>('/me', body: patch);

  @override
  Future<void> setAiConsent(bool granted) =>
      _api.post<Json>('/me/ai-consent', body: {'granted': granted, 'consent_version': AppConfig.aiConsentVersion});

  @override
  Future<PriceOffer> offer() async {
    final j = await _api.get<Json>('/me/offer');
    final v = j.m('variant');
    return PriceOffer(
      experiment: j.s('experiment'),
      code: v.s('code'),
      label: v.s('label'),
      annualPrice: (v['annual_price_usd'] as num?)?.toDouble(),
      monthlyPrice: (v['monthly_price_usd'] as num?)?.toDouble(),
      offering: v.s('revenuecat_offering'),
    );
  }

  @override
  Future<void> restorePurchases() => _api.post<Json>('/me/restore-purchases');

  @override
  Future<void> registerDevice({required String installationId, required String platform, required String permission, String? pushToken, String? appVersion, String? timezone}) =>
      _api.put<Json>('/me/devices', body: {
        'installation_id': installationId,
        'platform': platform,
        'permission_state': permission,
        'push_token': pushToken,
        if (appVersion != null) 'app_version': appVersion,
        if (timezone != null) 'timezone': timezone,
      });
}

Me meFromJson(Json j) {
  final p = j.m('profile');
  final ent = j.m('entitlement');
  final limits = ent.m('limits');
  final e = ent.m('entitlement');
  final u = j.m('usage');
  final hint = j.m('timezone_hint');
  return Me(
    profile: Profile(
      id: p.str('id'),
      email: p.str('email'),
      displayName: p.str('display_name'),
      timezone: p.str('timezone', 'America/New_York'),
      alertTime: p.str('alert_local_time', '09:00:00'),
      preferences: p.m('notification_preferences'),
      aiConsent: p['ai_processing_consent_at'] != null,
      analyticsConsent: p.b('analytics_consent'),
      country: p.str('country_code', 'US'),
      currency: p.str('default_currency', 'USD'),
      onboardingCompleted: p.b('onboarding_completed'),
      aiSuspendedUntil: p.s('ai_suspended_until') == null ? null : DateTime.tryParse(p.str('ai_suspended_until')),
      aiSuspensionReason: p.s('ai_suspension_reason'),
    ),
    plan: PlanInfo(
      code: ent.str('plan_code', 'free'),
      maxItems: limits.i('max_items') ?? 10,
      storageBytes: limits.i('storage_bytes') ?? 104857600,
      aiPerMonth: limits.i('ai_actions_per_month') ?? 0,
      aiTrial: limits.i('ai_lifetime_trial_actions') ?? 0,
      claimPackAssembled: limits.s('claim_pack_level') == 'assembled',
      aiClaimDraft: limits.b('ai_claim_draft'),
      workspaces: limits.b('workspaces_enabled'),
      emailForwarding: limits.b('email_forwarding_enabled'),
      state: e.s('state'),
      renewalIntent: e.s('renewal_intent'),
      validUntil: e.s('valid_until') == null ? null : DateTime.tryParse(e.str('valid_until')),
      store: e.s('store'),
    ),
    usage: Usage(
      itemsUsed: u.m('items').i('used') ?? 0,
      itemsLimit: u.m('items').i('limit') ?? 10,
      storageUsed: u.m('storage_bytes').i('used') ?? 0,
      storageLimit: u.m('storage_bytes').i('limit') ?? 0,
      aiUsed: u.m('ai_actions').i('used') ?? 0,
      aiLimit: u.m('ai_actions').i('limit') ?? 0,
      aiPeriod: u.m('ai_actions').str('period', 'lifetime'),
      additionsPaused: u.b('additions_paused'),
    ),
    timezoneHint: hint.isEmpty ? null : TimezoneHint(hint.str('device_timezone'), hint.str('message')),
  );
}
