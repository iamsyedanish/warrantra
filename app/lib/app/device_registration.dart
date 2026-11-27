import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/push/push_service.dart';
import '../core/storage/secure_store.dart';
import '../features/account/presentation/account_providers.dart';
import '../features/home/presentation/home_providers.dart';
import '../features/settings/presentation/settings_providers.dart';

StreamSubscription<String>? _tokenRefresh;

/// profiles.timezone default in the database.
const _serverDefaultZone = 'America/New_York';

/// Registers this installation for reminders, with its push token when allowed,
/// and links the store account for purchases.
///
/// The notification permission is only asked once the user has saved an item,
/// so the prompt comes with a reason ("we'll remind you before deadlines").
Future<void> registerDevice(WidgetRef ref, {bool askPermission = false}) async {
  try {
    final store = ref.read(secureStoreProvider);
    var id = await store.installationId();
    if (id == null) {
      id = const Uuid().v4();
      await store.saveInstallationId(id);
    }
    final push = PushService.instance;
    await push.init();
    final me = await ref.read(meProvider.future);
    final ask = askPermission || me.usage.itemsUsed > 0;
    final permission = await push.permission(ask: ask);
    final token = permission == 'granted' || permission == 'provisional' ? await push.token() : null;
    final info = await PackageInfo.fromPlatform();
    final repo = ref.read(accountRepositoryProvider);
    // The phone's IANA zone ("Asia/Karachi"). The server compares it with the
    // account's zone and offers to switch when they differ (travel).
    String? tz;
    try {
      tz = (await FlutterTimezone.getLocalTimezone()).identifier;
    } catch (_) {}
    Future<void> send(String? t) => repo.registerDevice(
          installationId: id!,
          platform: Platform.isIOS ? 'ios' : 'android',
          permission: permission,
          pushToken: t,
          appVersion: info.version,
          timezone: tz,
        );
    await send(token);
    // New accounts start on the server default zone. The first time this account
    // registers on this phone, adopt the phone's zone so 9 AM reminders arrive at
    // 9 AM local time. Later differences are offered as a prompt, never forced.
    final prefs = ref.read(sharedPrefsProvider);
    final checkedKey = 'tz_adopted_${me.profile.id}';
    if (tz != null && prefs.getBool(checkedKey) != true) {
      await prefs.setBool(checkedKey, true);
      if (me.profile.timezone == _serverDefaultZone && tz != _serverDefaultZone) {
        await repo.updateProfile({'timezone': tz});
        ref.invalidate(meProvider);
        ref.invalidate(actionCenterProvider); // day counts follow the zone

      }
    }
    await _tokenRefresh?.cancel();
    _tokenRefresh = push.tokenRefresh.listen((t) => send(t).catchError((_) {}));
    await ref.read(billingProvider).identify(me.profile.id);
  } catch (_) {
    // Best effort: reminders still show in the Action Center.
  }
}

/// Called on sign-out so this phone stops receiving the old account's reminders.
Future<void> unregisterPush(WidgetRef ref) async {
  await _tokenRefresh?.cancel();
  _tokenRefresh = null;
  // Tell the server first (while still signed in) that this phone no longer takes
  // this account's pushes, then invalidate the token with Google as well.
  try {
    final id = await ref.read(secureStoreProvider).installationId();
    if (id != null) {
      await ref.read(accountRepositoryProvider).registerDevice(
            installationId: id,
            platform: Platform.isIOS ? 'ios' : 'android',
            permission: 'unknown',
            pushToken: null,
          );
    }
  } catch (_) {
    // Offline: deleting the token below still stops delivery.
  }
  await PushService.instance.deleteToken();
}
