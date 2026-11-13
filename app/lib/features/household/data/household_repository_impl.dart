import '../../../core/network/api_client.dart';
import '../../../core/utils/format.dart';
import '../domain/household.dart';

class HouseholdRepositoryImpl implements HouseholdRepository {
  HouseholdRepositoryImpl(this._api);
  final ApiClient _api;

  List<Json> _rows(dynamic r) => (r is List ? r : const []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  Workspace _ws(Json j) => Workspace(
        id: j.str('id'),
        kind: j.str('kind', 'household'),
        name: j.str('name'),
        ownerId: j.str('owner_id'),
        members: [...j.l('members'), ...j.l('workspace_members')]
            .map((m) => Member(userId: m.str('user_id'), role: m.str('role'), state: m.str('state'), name: m.m('profiles').s('display_name'), joinedAt: m.s('joined_at')))
            .toList(),
        items: j.l('items').map((x) {
          final it = x.m('items');
          return SharedItem(itemId: x.str('item_id'), name: it.str('name', 'Item'), brand: it.s('brand'), model: it.s('model_number'), locationId: x.s('location_id'), serial: it.s('serial_number'));
        }).toList(),
        locations: j.l('locations').map((l) => Location(id: l.str('id'), name: l.str('name'), kind: l.s('kind'), parentId: l.s('parent_location_id'))).toList(),
      );

  @override
  Future<List<Workspace>> list() async => _rows(await _api.get<dynamic>('/workspaces')).map(_ws).toList();
  @override
  Future<Workspace> get(String id) async => _ws(await _api.get<Json>('/workspaces/$id'));
  @override
  Future<Workspace> create({required String kind, required String name}) async => _ws(await _api.post<Json>('/workspaces', body: {'kind': kind, 'name': name}));
  @override
  Future<void> invite(String id, {required String email, required String role}) => _api.post<dynamic>('/workspaces/$id/invitations', body: {'email': email, 'role': role});
  @override
  Future<void> acceptInvite(String token) => _api.post<dynamic>('/workspaces/invitations/accept', body: {'token': token});
  @override
  Future<void> updateMember(String id, String userId, Map<String, dynamic> patch) => _api.patch<dynamic>('/workspaces/$id/members/$userId', body: patch);
  @override
  Future<void> leave(String id) => _api.post<dynamic>('/workspaces/$id/leave');
  @override
  Future<void> shareItem(String id, String itemId, {String? locationId}) => _api.post<dynamic>('/workspaces/$id/items', body: {'item_id': itemId, 'location_id': ?locationId});
  @override
  Future<void> unshareItem(String id, String itemId) => _api.delete<dynamic>('/workspaces/$id/items/$itemId');
  @override
  Future<void> addLocation(String id, {required String name, String kind = 'property'}) => _api.post<dynamic>('/workspaces/$id/locations', body: {'name': name, 'kind': kind});

  @override
  Future<ForwardingAddress?> forwardingAddress() async {
    final j = await _api.get<dynamic>('/email-forwarding');
    if (j is! Map) return null;
    final m = Map<String, dynamic>.from(j);
    return ForwardingAddress(m.str('address'), m.s('created_at'));
  }

  @override
  Future<ForwardingAddress> rotateAddress() async {
    final m = await _api.post<Json>('/email-forwarding/rotate');
    return ForwardingAddress(m.str('address'), m.s('created_at'));
  }

  @override
  Future<void> disableAddress() => _api.post<dynamic>('/email-forwarding/disable');

  @override
  Future<List<InboundEmail>> inboundLog() async => _rows(await _api.get<dynamic>('/email-forwarding/log'))
      .map((j) => InboundEmail(id: j.str('id'), state: j.str('state'), reason: j.s('rejection_reason'), attachments: j.i('accepted_attachments') ?? 0, receivedAt: j.s('received_at'), draftId: j.s('capture_draft_id')))
      .toList();
}
