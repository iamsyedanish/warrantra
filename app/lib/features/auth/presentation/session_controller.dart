import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/storage/secure_store.dart';
import '../data/auth_repository_impl.dart';
import '../domain/auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepositoryImpl(ref.watch(apiClientProvider), ref.watch(secureStoreProvider)),
);

enum SessionStatus { unknown, signedOut, signedIn }

/// App-wide session state. Every user-scoped provider watches [sessionEpochProvider],
/// so signing out or switching accounts drops all cached private data.
class SessionController extends Notifier<SessionStatus> {
  @override
  SessionStatus build() {
    ref.watch(apiClientProvider).onSessionExpired = _expired;
    _restore();
    return SessionStatus.unknown;
  }

  Future<void> _restore() async {
    // Keep the splash up long enough for its short animation on a cold start
    // (the session check alone is near-instant). Skipped in widget tests.
    // Counted from when the splash has painted, so slow starts still show it.
    final minSplash = _inTests
        ? Future<void>.value()
        : _splashPainted.future.timeout(const Duration(seconds: 3), onTimeout: () {}).then((_) => Future<void>.delayed(const Duration(milliseconds: 1400)));
    final has = await ref.read(authRepositoryProvider).hasSession();
    await minSplash;
    state = has ? SessionStatus.signedIn : SessionStatus.signedOut;
  }

  static final _splashPainted = Completer<void>();

  /// Called by the splash screen once it is on screen.
  static void splashPainted() {
    if (!_splashPainted.isCompleted) _splashPainted.complete();
  }

  static final _inTests = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  void _expired() {
    if (state == SessionStatus.signedIn) _clearAndSignOut();
  }

  void markSignedIn() {
    ref.read(sessionEpochProvider.notifier).bump();
    state = SessionStatus.signedIn;
  }

  Future<void> signOut() async {
    await ref.read(authRepositoryProvider).signOut();
    _clearAndSignOut();
  }

  void _clearAndSignOut() {
    ref.read(sessionEpochProvider.notifier).bump();
    state = SessionStatus.signedOut;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionStatus>(SessionController.new);

/// Incremented on every sign-in/out so cached user data is rebuilt from scratch.
class SessionEpoch extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final sessionEpochProvider = NotifierProvider<SessionEpoch, int>(SessionEpoch.new);
