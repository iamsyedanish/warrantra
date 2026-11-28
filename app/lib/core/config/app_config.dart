/// Build-time configuration. Override with --dart-define, e.g.
///   flutter run --dart-define=API_BASE_URL=http://localhost:8080
class AppConfig {
  const AppConfig._();

  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://warrantra-api-production.up.railway.app',
  );

  /// Native Google sign-in (leave empty until Google is enabled in Supabase Auth).
  static const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const googleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  /// Apple sign-in is available on iOS once Apple is enabled in Supabase Auth.
  static const appleSignInEnabled = bool.fromEnvironment('APPLE_SIGN_IN', defaultValue: true);

  /// Current AI consent text version shown on the consent screen.
  static const aiConsentVersion = 'v1';

  static const supportEmail = 'support@warrantra.com';
  static const webDeletionUrl = 'https://warrantra.com/delete';
  static const privacyUrl = 'https://warrantra.com/privacy';
  static const termsUrl = 'https://warrantra.com/terms';

  /// Upload limits mirrored from the backend for early, friendly validation.
  /// Inbound email (receipt forwarding) needs the mail domain and provider set up.
  /// Until then the feature is shown as coming soon. Build with EMAIL_FORWARDING=true.
  static const emailForwardingLive = bool.fromEnvironment('EMAIL_FORWARDING');

  static const maxFileBytes = 10 * 1024 * 1024;
  static const allowedMime = {'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf'};
}
