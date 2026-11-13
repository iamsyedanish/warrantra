import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/cards.dart';

class CardsRepositoryImpl implements CardsRepository {
  CardsRepositoryImpl(this._api);
  final ApiClient _api;

  List<Json> _rows(dynamic r) => (r is List ? r : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  @override
  Future<List<PaymentCard>> list() async => _rows(await _api.get<dynamic>('/payment-cards'))
      .map((j) => PaymentCard(
            id: j.str('id'),
            nickname: j.str('nickname'),
            issuer: j.s('issuer_label'),
            network: j.s('network'),
            benefitId: j.s('card_benefit_id'),
            benefitName: j.m('card_benefits').isEmpty ? null : '${j.m('card_benefits').str('issuer')} ${j.m('card_benefits').str('card_name')}',
          ))
      .toList();

  @override
  Future<List<CardBenefit>> benefits() async => _rows(await _api.get<dynamic>('/reference/card-benefits'))
      .map((j) => CardBenefit(
            id: j.str('id'),
            issuer: j.str('issuer'),
            cardName: j.str('card_name'),
            extensionMonths: j.i('extension_months'),
            maxOriginalMonths: j.i('max_original_warranty_months'),
            enrollmentRequired: j.b('enrollment_required'),
            sourceUrl: j.s('source_url'),
            lastVerified: j.s('last_verified_at'),
          ))
      .toList();

  @override
  Future<void> add({required String nickname, String? issuer, String? network, String? benefitId}) =>
      _api.post<dynamic>('/payment-cards', body: {'nickname': nickname, 'issuer_label': ?issuer, 'network': ?network, 'card_benefit_id': ?benefitId});

  @override
  Future<void> update(String id, Map<String, dynamic> patch) => _api.patch<dynamic>('/payment-cards/$id', body: patch);

  @override
  Future<void> remove(String id) => _api.delete<dynamic>('/payment-cards/$id');
}
