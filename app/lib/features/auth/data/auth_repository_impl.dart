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
  Future<void> signInWithProvider(SocialProvider provider, {bool signUp = false}) async {
    final t = await _providerToken(provider);
    try {
      await _exchange(provider, t, intent: signUp ? 'sign_up' : 'sign_in');
    } on Failure catch (e) {
      // The email already has an account without this provider. Newer servers
      // say so (409); older ones only report a generic auth_provider_error.
      final existing = e.code == 'account_exists_use_original_sign_in' || e.code == 'auth_provider_error';
      final email = t.$4;
      if (existing && email != null) throw AccountLinkRequired(provider: provider, email: email, pending: t);
      rethrow;
    }
  }

  @override
  Future<void> signInAndLink(AccountLinkRequired link, String password) async {
    await signIn(email: link.email, password: password); // proves ownership; counts as a recent sign-in
    await _api.post<Json>('/auth/identities/link-intent', body: {'provider': link.provider.name});
    await _exchange(link.provider, link.pending as (String, String?, String?, String?));
  }

  Future<(String, String?, String?, String?)> _providerToken(SocialProvider provider) async => switch (provider) {
        SocialProvider.apple => await _appleToken(),
        SocialProvider.google => await _googleToken(),
      };

  /// Trades the provider's ID token for a Warrantra session.
  /// [intent] 'sign_in' makes the server refuse emails without an account; linking sends none.
  Future<void> _exchange(SocialProvider provider, (String, String?, String?, String?) t, {String? intent}) async {
    final (idToken, nonce, accessToken, _) = t;
    final data = await _api.post<Json>('/auth/id-token',
        body: {'provider': provider.name, 'id_token': idToken, 'nonce': ?nonce, 'access_token': ?accessToken, 'intent': ?intent},
        auth: false);
    await _saveSession(data['session'] as Json?);
  }

  @override
  Future<List<String>> identities() async {
    final rows = await _api.get<List<dynamic>>('/auth/identities');
    return [for (final r in rows) (r as Json)['provider'] as String];
  }

  @override
  Future<void> linkProvider(SocialProvider provider, {required String accountEmail}) async {
    // 1. Pick the provider account first. A different email would start a
    //    separate new Warrantra account instead of linking, so stop here.
    final t = await _providerToken(provider);
    final email = t.$4;
    if (email == null || email.toLowerCase() != accountEmail.toLowerCase()) {
      final name = provider == SocialProvider.google ? 'Google' : 'Apple';
      throw Failure('provider_email_mismatch', 'Choose the $name account for $accountEmail. A different email would start a separate Warrantra account.');
    }
    // 2. Tell the server this account means to add the provider (10-minute window).
    await _api.post<Json>('/auth/identities/link-intent', body: {'provider': provider.name});
    // 3. Signing in with the provider now attaches it to this same account
    //    (Supabase matches the verified email; the intent lets it through).
    await _exchange(provider, t);
  }

  Future<(String, String?, String?, String?)> _appleToken() async {
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
    return (token, raw, null, credential.email);
  }

  Future<(String, String?, String?, String?)> _googleToken() async {
    if (AppConfig.googleServerClientId.isEmpty) {
      throw const Failure('provider_unavailable', 'Google sign-in is not configured yet. Use email for now.');
    }
    final google = GoogleSignIn.instance;
    await google.initialize(
      clientId: AppConfig.googleIosClientId.isEmpty ? null : AppConfig.googleIosClientId,
      serverClientId: AppConfig.googleServerClientId,
    );
    final GoogleSignInAccount account;
    try {
      account = await google.authenticate();
    } on GoogleSignInException catch (e) {
      throw switch (e.code) {
        GoogleSignInExceptionCode.canceled => const Failure('cancelled', ''),
        GoogleSignInExceptionCode.interrupted => const Failure('provider_error', 'Google sign-in was interrupted. Please try again.'),
        GoogleSignInExceptionCode.uiUnavailable => const Failure('provider_error', 'Google sign-in could not open on this phone. Use email for now.'),
        GoogleSignInExceptionCode.clientConfigurationError || GoogleSignInExceptionCode.providerConfigurationError =>
          Failure('provider_unavailable', "Google sign-in isn't set up for this version yet. Use email for now.${e.description == null ? '' : ' (${e.description})'}"),
        _ => Failure('provider_error', 'Google sign-in failed${e.description == null ? '' : ': ${e.description}'}. Try again, or use email.'),
      };
    }
    final token = account.authentication.idToken;
    if (token == null) throw const Failure('provider_error', 'Google did not return a sign-in token.');
    return (token, null, null, account.email);
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
