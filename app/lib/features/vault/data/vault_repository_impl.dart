import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/vault.dart';

class VaultRepositoryImpl implements VaultRepository {
  VaultRepositoryImpl(this._api);
  final ApiClient _api;

  VaultDoc _doc(Json j) => VaultDoc(
        id: j.str('id'),
        fileType: j.str('file_type', 'other'),
        filename: j.s('original_filename'),
        mime: j.s('verified_mime_type') ?? j.s('declared_mime_type'),
        size: j.i('actual_byte_size') ?? j.i('declared_byte_size'),
        pages: j.i('page_count'),
        state: j.str('processing_state', 'ready'),
        createdAt: j.s('created_at'),
        itemIds: j.l('item_attachments').map((x) => x.str('item_id')).toList(),
        claimIds: j.l('claim_attachments').map((x) => x.str('claim_id')).toList(),
      );

  @override
  Future<List<VaultDoc>> list({String? fileType}) async {
    final rows = await _api.get<List<dynamic>>('/vault', query: {'limit': 100, 'file_type': ?fileType});
    return rows.whereType<Map>().map((r) => _doc(Map<String, dynamic>.from(r))).toList();
  }

  @override
  Future<VaultDoc> get(String id) async => _doc(await _api.get<Json>('/attachments/$id'));

  @override
  Future<String> url(String id, {int? previewWidth, bool download = false}) async {
    final j = await _api.get<Json>('/attachments/$id/url', query: {'preview_width': ?previewWidth, if (download) 'download': 'true'});
    return j.str('url');
  }

  @override
  Future<DocImpact> impact(String id) async {
    final j = await _api.get<Json>('/attachments/$id/impact');
    return DocImpact(
      items: j.l('items').map((x) => (x.str('item_id'), x.str('name'))).toList(),
      purchases: j.l('purchases').length,
      claims: j.l('claims').map((x) => (x.str('claim_id'), x.str('item_label'))).toList(),
      warrantySources: j.i('warranty_sources') ?? 0,
      registrationConfirmations: j.i('registration_confirmations') ?? 0,
      serviceRecords: j.i('service_records') ?? 0,
    );
  }

  @override
  Future<void> delete(String id, {required bool confirm}) => _api.delete<dynamic>('/attachments/$id', query: {if (confirm) 'confirm': 'true'});

  @override
  Future<void> rename(String id, String filename) => _api.patch<dynamic>('/attachments/$id', body: {'original_filename': filename});

  @override
  Future<void> setType(String id, String fileType) => _api.patch<dynamic>('/attachments/$id', body: {'file_type': fileType});

  @override
  Future<void> unlinkItem(String id, String itemId) => _api.delete<dynamic>('/attachments/$id/links/item/$itemId');
}
