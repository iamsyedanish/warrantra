/// Auth domain: contracts only, no framework or HTTP types.
enum SocialProvider { apple, google }

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
  Future<void> signInWithProvider(SocialProvider provider);
  Future<void> sendPasswordReset(String email);

  /// Signs out on the server and clears every token on this device.
  Future<void> signOut();
}
