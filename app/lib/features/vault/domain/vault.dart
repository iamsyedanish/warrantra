/// Document vault domain.
class VaultDoc {
  const VaultDoc({required this.id, required this.fileType, this.filename, this.mime, this.size, this.pages, required this.state, this.createdAt, this.itemIds = const [], this.claimIds = const []});
  final String id, fileType, state;
  final String? filename, mime, createdAt;
  final int? size, pages;
  final List<String> itemIds, claimIds;
  bool get isImage => (mime ?? '').startsWith('image/');
  bool get isPdf => mime == 'application/pdf';
  bool get held => state == 'quarantined';
}

class DocImpact {
  const DocImpact({this.items = const [], this.purchases = 0, this.claims = const [], this.warrantySources = 0, this.registrationConfirmations = 0, this.serviceRecords = 0});
  final List<(String id, String name)> items;
  final List<(String id, String label)> claims;
  final int purchases, warrantySources, registrationConfirmations, serviceRecords;
  bool get linked => items.isNotEmpty || claims.isNotEmpty || purchases > 0;
}

abstract interface class VaultRepository {
  Future<List<VaultDoc>> list({String? fileType});
  Future<VaultDoc> get(String id);
  Future<String> url(String id, {int? previewWidth, bool download = false});
  Future<DocImpact> impact(String id);
  Future<void> delete(String id, {required bool confirm});
  Future<void> rename(String id, String filename);
  Future<void> setType(String id, String fileType);
  Future<void> unlinkItem(String id, String itemId);
}
