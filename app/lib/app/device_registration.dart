import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/storage/secure_store.dart';
import '../features/account/presentation/account_providers.dart';
import '../features/settings/presentation/settings_providers.dart';

/// Registers this installation for reminders and links the store account.
/// Push tokens are attached once APNs/FCM is configured for the build.
Future<void> registerDevice(WidgetRef ref) async {
  try {
    final store = ref.read(secureStoreProvider);
    var id = await store.installationId();
    if (id == null) {
      id = const Uuid().v4();
      await store.saveInstallationId(id);
    }
    final info = await PackageInfo.fromPlatform();
    final tz = DateTime.now().timeZoneName;
    await ref.read(accountRepositoryProvider).registerDevice(
          installationId: id,
          platform: Platform.isIOS ? 'ios' : 'android',
          permission: 'unknown',
          appVersion: info.version,
          timezone: tz.contains('/') ? tz : null,
        );
    final me = await ref.read(meProvider.future);
    await ref.read(billingProvider).identify(me.profile.id);
  } catch (_) {
    // Best effort: reminders still show in the Action Center.
  }
}
