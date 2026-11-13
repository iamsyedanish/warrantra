/// Shared household vaults and business portfolios (workspaces).
class Member {
  const Member({required this.userId, required this.role, required this.state, this.name, this.joinedAt});
  final String userId, role, state;
  final String? name, joinedAt;
}

class SharedItem {
  const SharedItem({required this.itemId, required this.name, this.brand, this.model, this.locationId, this.serial});
  final String itemId, name;
  final String? brand, model, locationId, serial;
}

class Location {
  const Location({required this.id, required this.name, this.kind, this.parentId});
  final String id, name;
  final String? kind, parentId;
}

class Workspace {
  const Workspace({required this.id, required this.kind, required this.name, required this.ownerId, this.members = const [], this.items = const [], this.locations = const []});
  final String id, kind, name, ownerId;
  final List<Member> members;
  final List<SharedItem> items;
  final List<Location> locations;
}

class ForwardingAddress {
  const ForwardingAddress(this.address, this.createdAt);
  final String address;
  final String? createdAt;
}

class InboundEmail {
  const InboundEmail({required this.id, required this.state, this.reason, this.attachments = 0, this.receivedAt, this.draftId});
  final String id, state;
  final String? reason, receivedAt, draftId;
  final int attachments;
}

abstract interface class HouseholdRepository {
  Future<List<Workspace>> list();
  Future<Workspace> get(String id);
  Future<Workspace> create({required String kind, required String name});
  Future<void> invite(String id, {required String email, required String role});
  Future<void> acceptInvite(String token);
  Future<void> updateMember(String id, String userId, Map<String, dynamic> patch);
  Future<void> leave(String id);
  Future<void> shareItem(String id, String itemId, {String? locationId});
  Future<void> unshareItem(String id, String itemId);
  Future<void> addLocation(String id, {required String name, String kind = 'property'});
  Future<ForwardingAddress?> forwardingAddress();
  Future<ForwardingAddress> rotateAddress();
  Future<void> disableAddress();
  Future<List<InboundEmail>> inboundLog();
}
