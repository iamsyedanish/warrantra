import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_shell.dart';
import '../../features/auth/presentation/auth_screens.dart';
import '../../features/auth/presentation/session_controller.dart';
import '../../features/capture/presentation/capture_screens.dart';
import '../../features/capture/presentation/coverage_setup_screen.dart';
import '../../features/capture/presentation/drafts_screen.dart';
import '../../features/capture/presentation/manual_screen.dart';
import '../../features/capture/presentation/product_result_screen.dart';
import '../../features/capture/presentation/review_screen.dart';
import '../../features/cards/presentation/cards_screen.dart';
import '../../features/claims/presentation/claim_screens.dart';
import '../../features/claims/presentation/claim_wizard_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/household/presentation/household_screens.dart';
import '../../features/items/presentation/coverage_edit_screen.dart';
import '../../features/items/presentation/edit_item_screen.dart';
import '../../features/items/presentation/item_detail_screen.dart';
import '../../features/items/presentation/items_screen.dart';
import '../../features/items/presentation/return_registration_screens.dart';
import '../../features/maintenance/presentation/maintenance_screen.dart';
import '../../features/settings/presentation/account_screens.dart';
import '../../features/settings/presentation/plan_screens.dart';
import '../../features/settings/presentation/prefs_screens.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/vault/presentation/vault_screens.dart';
import '../errors/failure.dart';
import '../storage/secure_store.dart';

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Bridges Riverpod session changes to go_router redirects.
class _RouterRefresh extends ChangeNotifier {
  void ping() => notifyListeners();
}

const _public = {'/splash', '/onboarding', '/signin', '/signup', '/forgot'};

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh();
  ref.listen(sessionProvider, (_, _) => refresh.ping());
  ref.onDispose(refresh.dispose);

  String? q(GoRouterState s, String k) => s.uri.queryParameters[k];
  GoRoute r(String path, Widget Function(GoRouterState s) b) => GoRoute(path: path, parentNavigatorKey: rootNavigatorKey, builder: (_, s) => b(s));

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final status = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      if (status == SessionStatus.unknown) return loc == '/splash' ? null : '/splash';
      final signedIn = status == SessionStatus.signedIn;
      if (!signedIn) {
        if (_public.contains(loc) && loc != '/splash') return null;
        final seen = ref.read(sharedPrefsProvider).getBool(OnboardingScreen.seenKey) ?? false;
        return seen ? '/signin' : '/onboarding';
      }
      if (_public.contains(loc)) return '/home';
      return null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/onboarding', builder: (_, _) => const OnboardingScreen()),
      GoRoute(path: '/signin', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/signup', builder: (_, _) => const SignUpScreen()),
      GoRoute(path: '/forgot', builder: (_, _) => const ForgotPasswordScreen()),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => AppShell(shell: shell),
        branches: [
          StatefulShellBranch(routes: [GoRoute(path: '/home', builder: (_, _) => const HomeScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/items', builder: (_, _) => const ItemsScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/vault', builder: (_, _) => const VaultScreen())]),
          StatefulShellBranch(routes: [GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen())]),
        ],
      ),
      // Items & coverage
      r('/items/:id', (s) => ItemDetailScreen(itemId: s.pathParameters['id']!)),
      r('/items/:id/edit', (s) => EditItemScreen(itemId: s.pathParameters['id']!)),
      r('/items/:id/coverage/new', (s) => CoverageEditScreen(itemId: s.pathParameters['id']!, suggestion: s.extra as Map<String, dynamic>?)),
      r('/items/:id/coverage/:wid', (s) => CoverageEditScreen(itemId: s.pathParameters['id']!, warrantyId: s.pathParameters['wid'])),
      r('/items/:id/return/new', (s) => ReturnEditScreen(itemId: s.pathParameters['id']!)),
      r('/items/:id/return/:rid', (s) => ReturnTrackScreen(itemId: s.pathParameters['id']!, returnId: s.pathParameters['rid']!)),
      r('/items/:id/return/:rid/edit', (s) => ReturnEditScreen(itemId: s.pathParameters['id']!, returnId: s.pathParameters['rid'])),
      r('/items/:id/registration/new', (s) => RegistrationScreen(itemId: s.pathParameters['id']!)),
      r('/items/:id/registration/:gid', (s) => RegistrationScreen(itemId: s.pathParameters['id']!, registrationId: s.pathParameters['gid'])),
      // Capture
      r('/capture/manual', (s) => ManualEntryScreen(attachmentId: q(s, 'attachment'), prefill: s.extra as ManualPrefill?)),
      r('/capture/ai-consent', (s) => AiConsentScreen(mode: q(s, 'mode'))),
      r('/capture/ai-limit', (s) => AiLimitScreen(attachmentId: q(s, 'attachment'), reason: q(s, 'reason'))),
      r('/capture/upload-issue', (s) => UploadIssueScreen(failure: s.extra is Failure ? s.extra as Failure : Failure.unknown)),
      r('/capture/scan/:id', (s) => ProcessingScreen(scanId: s.pathParameters['id']!, attachmentId: q(s, 'attachment'))),
      r('/capture/failed', (s) => ScanFailedScreen(code: q(s, 'code'), attachmentId: q(s, 'attachment'))),
      r('/capture/review/:id', (s) => ReviewScreen(scanId: s.pathParameters['id']!, attachmentId: q(s, 'attachment'))),
      r('/capture/product/:id', (s) => ProductResultScreen(scanId: s.pathParameters['id']!, attachmentId: q(s, 'attachment'))),
      r('/capture/coverage', (s) => CoverageSetupScreen(args: s.extra is CoverageSetupArgs ? s.extra as CoverageSetupArgs : const CoverageSetupArgs(itemIds: []))),
      r('/drafts', (_) => const DraftsScreen()),
      // Vault
      r('/vault/:id', (s) => DocViewerScreen(id: s.pathParameters['id']!)),
      // Claims & outcomes
      r('/claims', (_) => const ClaimsListScreen()),
      r('/claims/new', (s) => ClaimWizardScreen(itemId: q(s, 'item') ?? '')),
      r('/claims/:id', (s) => ClaimDetailScreen(claimId: s.pathParameters['id']!)),
      r('/claims/:id/pack', (s) => ClaimPackScreen(claimId: s.pathParameters['id']!)),
      r('/outcomes', (_) => const OutcomesScreen()),
      r('/outcomes/new', (s) => OutcomeFormScreen(claimId: q(s, 'claim'), returnId: q(s, 'return'))),
      // Settings
      r('/settings/plan', (_) => const PlanScreen()),
      r('/settings/paywall', (_) => const PaywallScreen()),
      r('/settings/reminders', (_) => const ReminderPrefsScreen()),
      r('/settings/region', (_) => const RegionScreen()),
      r('/settings/privacy', (_) => const PrivacyScreen()),
      r('/settings/export', (_) => const ExportScreen()),
      r('/settings/delete-account', (_) => const DeleteAccountScreen()),
      r('/settings/annual', (_) => const AnnualScreen()),
      r('/settings/digest', (_) => const DigestScreen()),
      r('/settings/support', (_) => const SupportScreen()),
      r('/settings/switch-account', (_) => const SwitchAccountScreen()),
      r('/settings/email-forwarding', (_) => const EmailForwardingScreen()),
      // P1/P2
      r('/household', (s) => HouseholdScreen(shareItemId: q(s, 'share'))),
      r('/portfolio', (_) => const HouseholdScreen(kind: 'business')),
      r('/maintenance', (s) => MaintenanceScreen(itemId: q(s, 'item'))),
      r('/cards', (_) => const CardsScreen()),
    ],
  );
});
