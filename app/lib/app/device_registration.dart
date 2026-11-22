import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/push/push_service.dart';
import '../core/storage/secure_store.dart';
import '../features/account/presentation/account_providers.dart';
import '../features/settings/presentation/settings_providers.dart';

StreamSubscription<String>? _tokenRefresh;

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
    Future<void> send(String? t) => repo.registerDevice(
          installationId: id!,
          platform: Platform.isIOS ? 'ios' : 'android',
          permission: permission,
          pushToken: t,
          appVersion: info.version,
        );
    await send(token);
    await _tokenRefresh?.cancel();
    _tokenRefresh = push.tokenRefresh.listen((t) => send(t).catchError((_) {}));
    await ref.read(billingProvider).identify(me.profile.id);
  } catch (_) {
    // Best effort: reminders still show in the Action Center.
  }
}

/// Called on sign-out so this phone stops receiving the old account's reminders.
Future<void> unregisterPush() async {
  await _tokenRefresh?.cancel();
  _tokenRefresh = null;
  await PushService.instance.deleteToken();
}
