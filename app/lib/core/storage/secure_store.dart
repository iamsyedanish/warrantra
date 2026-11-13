import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tokens live in the platform keychain/keystore; small preferences in
/// SharedPreferences. Private data is never cached in plain preferences.
class SecureStore {
  SecureStore([FlutterSecureStorage? storage]) : _s = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;

  static const _access = 'access_token';
  static const _refresh = 'refresh_token';
  static const _installation = 'installation_id';

  Future<String?> accessToken() => _s.read(key: _access);
  Future<String?> refreshToken() => _s.read(key: _refresh);

  Future<void> saveTokens({required String access, required String refresh}) async {
    await _s.write(key: _access, value: access);
    await _s.write(key: _refresh, value: refresh);
  }

  Future<void> clearTokens() async {
    await _s.delete(key: _access);
    await _s.delete(key: _refresh);
  }

  Future<String?> installationId() => _s.read(key: _installation);
  Future<void> saveInstallationId(String id) => _s.write(key: _installation, value: id);
}

final secureStoreProvider = Provider<SecureStore>((_) => SecureStore());

/// Overridden in main() after SharedPreferences.getInstance().
final sharedPrefsProvider = Provider<SharedPreferences>((_) => throw UnimplementedError('sharedPrefsProvider not overridden'));
