/// A failure surfaced to the presentation layer. `code` mirrors the API's
/// stable error codes (e.g. `quota_exceeded`, `ai_consent_required`).
class Failure implements Exception {
  const Failure(this.code, this.message, {this.status, this.details});

  final String code;
  final String message;
  final int? status;
  final Map<String, dynamic>? details;

  bool get isUnauthorized => status == 401;
  bool get isOffline => code == 'offline';
  bool get isQuota => code == 'quota_exceeded';
  bool get isPlanRequired => code == 'plan_required';

  static const offline = Failure('offline', "You're offline. Your draft is saved on this device until you reconnect.");
  static const unknown = Failure('unknown', 'Something went wrong. Please try again.');

  @override
  String toString() => 'Failure($code, $message)';
}
