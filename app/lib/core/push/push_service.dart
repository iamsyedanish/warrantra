import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Firebase Cloud Messaging on Android (reads android/app/google-services.json).
/// iOS push is not set up yet, so everything here is a no-op there.
class PushService {
  PushService._();
  static final instance = PushService._();

  bool _ready = false;
  final _opened = StreamController<Map<String, dynamic>>.broadcast();
  final _foreground = StreamController<RemoteMessage>.broadcast();

  /// Data of a notification the user tapped (reminder_id, reminder_type, item_id).
  Stream<Map<String, dynamic>> get opened => _opened.stream;

  /// Messages that arrive while the app is open (Android shows nothing by itself).
  Stream<RemoteMessage> get foreground => _foreground.stream;

  bool get supported => !kIsWeb && Platform.isAndroid;

  Future<void> init() async {
    if (_ready || !supported) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onMessageOpenedApp.listen((m) => _opened.add(m.data));
      FirebaseMessaging.onMessage.listen(_foreground.add);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _opened.add(initial.data);
      _ready = true;
    } catch (e) {
      debugPrint('push init skipped: $e');
    }
  }

  /// The server's permission states: unknown | granted | denied | provisional.
  Future<String> permission({bool ask = false}) async {
    if (!_ready) return 'unknown';
    final m = FirebaseMessaging.instance;
    final settings = ask ? await m.requestPermission() : await m.getNotificationSettings();
    return switch (settings.authorizationStatus) {
      AuthorizationStatus.authorized => 'granted',
      AuthorizationStatus.provisional => 'provisional',
      AuthorizationStatus.denied => 'denied',
      _ => 'unknown',
    };
  }

  Future<String?> token() async {
    if (!_ready) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      debugPrint('push token unavailable: $e');
      return null;
    }
  }

  Stream<String> get tokenRefresh => _ready ? FirebaseMessaging.instance.onTokenRefresh : const Stream.empty();

  /// Stops pushes to this phone for the account that is signing out.
  Future<void> deleteToken() async {
    if (_ready) await FirebaseMessaging.instance.deleteToken().catchError((_) {});
  }
}
