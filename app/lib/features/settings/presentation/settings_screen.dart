import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';
import '../../auth/presentation/session_controller.dart';
import '../../claims/presentation/claims_providers.dart';
import 'settings_providers.dart';

final _versionProvider = FutureProvider<String>((ref) async {
  final p = await PackageInfo.fromPlatform();
  return '${p.version} (${p.buildNumber})';
});

Future<void> signOutEverywhere(BuildContext context, WidgetRef ref) async {
  await ref.read(billingProvider).reset();
  await ref.read(sessionProvider.notifier).signOut();
  if (context.mounted) context.go('/signin');
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  String _notifLine(Me me) {
    final p = me.profile;
    final on = ['return', 'warranty', 'registration'].where(p.prefEnabled).length;
    return on == 0 ? 'Off' : '${p.alertTime.substring(0, 5)} · ${p.timezone}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider);
    final outcomes = ref.watch(outcomesProvider).value;
    final mode = ref.watch(themeModeProvider);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(meProvider);
            await ref.read(meProvider.future);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 110), children: [
            Text('Settings', style: context.t.headlineMedium),
            const SizedBox(height: 14),
            AsyncBody<Me>(
              value: me,
              onRetry: () => ref.invalidate(meProvider),
              data: (m) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  WAvatar(m.profile.name, size: 48),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.profile.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text)),
                      Text(m.profile.email, style: TextStyle(fontSize: 13, color: c.textMuted)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 14),
                WCard(
                  onTap: () => context.push('/settings/plan'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Text(m.plan.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text)),
                      const Spacer(),
                      Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle),
                    ]),
                    const SizedBox(height: 6),
                    Text('${m.itemsLine} · ${fmtBytes(m.usage.storageUsed)} of ${fmtBytes(m.usage.storageLimit)}', style: TextStyle(fontSize: 13, color: c.textMuted)),
                    Text(m.aiLine, style: TextStyle(fontSize: 13, color: c.textMuted)),
                  ]),
                ),
                const SizedBox(height: 6),
                WListRow(icon: PhosphorIconsRegular.bell, title: 'Reminders', subtitle: _notifLine(m), onTap: () => context.push('/settings/reminders')),
                WListRow(icon: PhosphorIconsRegular.trophy, title: 'Outcomes', subtitle: '${outcomes?.length ?? 0} confirmed', onTap: () => context.push('/outcomes')),
                WListRow(icon: PhosphorIconsRegular.chatCircleText, title: 'Claims', onTap: () => context.push('/claims')),
                WListRow(icon: PhosphorIconsRegular.globe, title: 'Region & currency', subtitle: '${m.profile.country} · ${m.profile.currency}', onTap: () => context.push('/settings/region')),
                WListRow(icon: PhosphorIconsRegular.lockSimple, title: 'Privacy & AI', subtitle: m.profile.aiConsent ? 'AI reading on' : 'AI reading off', onTap: () => context.push('/settings/privacy')),
                WListRow(icon: PhosphorIconsRegular.export, title: 'Export your data', subtitle: 'Free on every plan', onTap: () => context.push('/settings/export')),
                WListRow(icon: PhosphorIconsRegular.calendarCheck, title: 'Monthly digest', subtitle: DateFormatName.month(), onTap: () => context.push('/settings/digest')),
                WListRow(icon: PhosphorIconsRegular.chartLineUp, title: 'Your ${DateTime.now().year}', onTap: () => context.push('/settings/annual')),
                WListRow(icon: PhosphorIconsRegular.creditCard, title: 'Payment cards', subtitle: 'Labels only', onTap: () => context.push('/cards')),
                WListRow(icon: PhosphorIconsRegular.lifebuoy, title: 'Help & support', onTap: () => context.push('/settings/support')),
                const WSectionHeader('Appearance'),
                WChoiceChips<ThemeMode>(
                  options: const [(ThemeMode.system, 'System'), (ThemeMode.dark, 'Dark'), (ThemeMode.light, 'Light')],
                  value: mode,
                  onChanged: (v) => ref.read(themeModeProvider.notifier).set(v),
                ),
                const WSectionHeader('More'),
                WListRow(icon: PhosphorIconsRegular.usersThree, title: 'Household', trailing: const WTag('P1', kind: WTagKind.outline), onTap: () => context.push('/household')),
                WListRow(icon: PhosphorIconsRegular.envelopeSimple, title: 'Email forwarding', trailing: const WTag('P1', kind: WTagKind.outline), onTap: () => context.push('/settings/email-forwarding')),
                WListRow(icon: PhosphorIconsRegular.tray, title: 'Shared drafts', onTap: () => context.push('/drafts')),
                WListRow(icon: PhosphorIconsRegular.buildings, title: 'Properties', trailing: const WTag('Pilot', kind: WTagKind.outline), onTap: () => context.push('/portfolio')),
                const WSectionHeader('Account'),
                WListRow(icon: PhosphorIconsRegular.userSwitch, title: 'Switch account', onTap: () => context.push('/settings/switch-account')),
                WListRow(
                  icon: PhosphorIconsRegular.signOut,
                  title: 'Sign out',
                  caret: false,
                  onTap: () async {
                    final ok = await confirmDialog(context,
                        title: 'Sign out?', message: 'Cached items, documents and drafts are cleared from this phone. Your data stays in your account.', confirm: 'Sign out');
                    if (ok && context.mounted) await signOutEverywhere(context, ref);
                  },
                ),
                WListRow(icon: PhosphorIconsRegular.trash, title: 'Delete account', titleColor: c.danger, onTap: () => context.push('/settings/delete-account')),
                const SizedBox(height: 16),
                Center(child: Text('Warrantra ${ref.watch(_versionProvider).value ?? ''}', style: TextStyle(fontSize: 12, color: c.textSubtle))),
                const SizedBox(height: 4),
                Center(child: Text("Warrantra isn't insurance and can't guarantee a claim.", style: TextStyle(fontSize: 11.5, color: c.textSubtle))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class DateFormatName {
  static String month() => const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'][DateTime.now().month - 1];
}

class SwitchAccountScreen extends ConsumerWidget {
  const SwitchAccountScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    Widget point(IconData i, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, color: c.accent, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(t, style: TextStyle(color: c.textMuted, height: 1.45))),
          ]),
        );
    return WScreen(
      title: 'Switch account',
      bottom: WButton('Sign out and switch', onPressed: () => signOutEverywhere(context, ref)),
      children: [
        if (me != null)
          WCard(
            child: Row(children: [
              WAvatar(me.profile.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(me.profile.email, style: TextStyle(color: c.text)),
                  Text('This phone', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                ]),
              ),
              const WTag('Current', kind: WTagKind.accent),
            ]),
          ),
        const SizedBox(height: 16),
        point(PhosphorIconsRegular.broom, 'We sign you out and clear cached items, documents and drafts from this phone before the next account loads.'),
        point(PhosphorIconsRegular.gitMerge, 'Accounts are never merged automatically, even if they use the same email.'),
        point(PhosphorIconsRegular.bell, 'Reminders for this account stop on this phone until you sign back in.'),
      ],
    );
  }
}
