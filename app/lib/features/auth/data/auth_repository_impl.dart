import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../../../core/network/api_client.dart';
import '../../../core/storage/secure_store.dart';
import '../domain/auth_repository.dart';

class AuthRepositoryImpl implements AuthRepository {
  AuthRepositoryImpl(this._api, this._store);
  final ApiClient _api;
  final SecureStore _store;

  Future<void> _saveSession(Json? session) async {
    if (session == null) return;
    await _store.saveTokens(access: session['access_token'] as String, refresh: session['refresh_token'] as String);
  }

  @override
  Future<bool> hasSession() async => (await _store.refreshToken()) != null;

  @override
  Future<void> signIn({required String email, required String password}) async {
    final data = await _api.post<Json>('/auth/sign-in', body: {'email': email.trim(), 'password': password}, auth: false);
    await _saveSession(data['session'] as Json?);
  }

  @override
  Future<SignUpResult> signUp({required String email, required String password, String? displayName}) async {
    final data = await _api.post<Json>('/auth/sign-up',
        body: {'email': email.trim(), 'password': password, if (displayName != null && displayName.isNotEmpty) 'display_name': displayName},
        auth: false);
    final session = data['session'] as Json?;
    await _saveSession(session);
    return SignUpResult(signedIn: session != null, emailConfirmationRequired: data['email_confirmation_required'] == true);
  }

  @override
  Future<void> signInWithProvider(SocialProvider provider) async {
    final (idToken, nonce, accessToken) = switch (provider) {
      SocialProvider.apple => await _appleToken(),
      SocialProvider.google => await _googleToken(),
    };
    final data = await _api.post<Json>('/auth/id-token',
        body: {'provider': provider.name, 'id_token': idToken, if (nonce != null) 'nonce': nonce, if (accessToken != null) 'access_token': accessToken},
        auth: false);
    await _saveSession(data['session'] as Json?);
  }

  Future<(String, String?, String?)> _appleToken() async {
    if (!Platform.isIOS || !AppConfig.appleSignInEnabled) {
      throw const Failure('provider_unavailable', 'Sign in with Apple is available on iPhone.');
    }
    // The raw nonce goes to Supabase; Apple receives its SHA-256.
    final raw = _randomNonce();
    final credential = await SignInWithApple.getAppleIDCredential(
      scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      nonce: sha256.convert(utf8.encode(raw)).toString(),
    );
    final token = credential.identityToken;
    if (token == null) throw const Failure('provider_error', 'Apple did not return a sign-in token.');
    return (token, raw, null);
  }

  Future<(String, String?, String?)> _googleToken() async {
    if (AppConfig.googleServerClientId.isEmpty) {
      throw const Failure('provider_unavailable', 'Google sign-in is not configured yet. Use email for now.');
    }
    final google = GoogleSignIn.instance;
    await google.initialize(
      clientId: AppConfig.googleIosClientId.isEmpty ? null : AppConfig.googleIosClientId,
      serverClientId: AppConfig.googleServerClientId,
    );
    final account = await google.authenticate();
    final token = account.authentication.idToken;
    if (token == null) throw const Failure('provider_error', 'Google did not return a sign-in token.');
    return (token, null, null);
  }

  String _randomNonce([int length = 32]) {
    const chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final r = Random.secure();
    return List.generate(length, (_) => chars[r.nextInt(chars.length)]).join();
  }

  @override
  Future<void> sendPasswordReset(String email) => _api.post<Json>('/auth/password-reset', body: {'email': email.trim()}, auth: false);

  @override
  Future<void> signOut() async {
    try {
      await _api.post<Json>('/auth/sign-out');
    } catch (_) {
      // Signing out locally must always succeed, even offline.
    }
    await _store.clearTokens();
  }
}
