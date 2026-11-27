// Auth domain: contracts only, no framework or HTTP types.
import '../../../core/errors/failure.dart';

enum SocialProvider { apple, google }

/// "Continue with Google/Apple" found an existing account with the same email
/// that doesn't have this sign-in method yet. Accounts are never merged
/// silently, so the owner confirms with the account's password; [pending]
/// keeps the provider pick so the account chooser doesn't open twice.
class AccountLinkRequired extends Failure {
  const AccountLinkRequired({required this.provider, required this.email, required this.pending})
      : super('account_exists_use_original_sign_in', 'An account already uses this email.');
  final SocialProvider provider;
  final String email;
  final Object pending;
}

class SignUpResult {
  const SignUpResult({required this.signedIn, required this.emailConfirmationRequired});
  final bool signedIn;
  final bool emailConfirmationRequired;
}

abstract interface class AuthRepository {
  /// True when a stored session exists (it may still be refreshed on first use).
  Future<bool> hasSession();
  Future<void> signIn({required String email, required String password});
  Future<SignUpResult> signUp({required String email, required String password, String? displayName});
  /// Continue with Google/Apple. With [signUp] false (the Sign in screen) the
  /// server refuses emails that have no account (`no_account_for_provider_email`).
  Future<void> signInWithProvider(SocialProvider provider, {bool signUp = false});
  Future<void> sendPasswordReset(String email);

  /// Sign-in methods on the signed-in account: 'email', 'google', 'apple'.
  Future<List<String>> identities();

  /// Adds Google or Apple to the signed-in account. The server only allows this
  /// shortly after a sign-in (throws `reauthentication_required` otherwise).
  Future<void> linkProvider(SocialProvider provider, {required String accountEmail});

  /// Signs in to the existing account with its password, then adds the
  /// provider from [AccountLinkRequired] and finishes signing in.
  Future<void> signInAndLink(AccountLinkRequired link, String password);

  /// Signs out on the server and clears every token on this device.
  Future<void> signOut();
}
