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

  /// RevenueCat public SDK keys (purchases are disabled when empty).
  static const revenueCatAppleKey = String.fromEnvironment('REVENUECAT_APPLE_KEY');
  static const revenueCatGoogleKey = String.fromEnvironment('REVENUECAT_GOOGLE_KEY');

  /// Current AI consent text version shown on the consent screen.
  static const aiConsentVersion = 'v1';

  static const supportEmail = 'support@warrantra.app';
  static const webDeletionUrl = 'https://warrantra.app/delete';
  static const privacyUrl = 'https://warrantra.app/privacy';
  static const termsUrl = 'https://warrantra.app/terms';

  /// Upload limits mirrored from the backend for early, friendly validation.
  static const maxFileBytes = 10 * 1024 * 1024;
  static const allowedMime = {'image/jpeg', 'image/png', 'image/heic', 'image/heif', 'application/pdf'};
}
