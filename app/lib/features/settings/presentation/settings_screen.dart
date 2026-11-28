import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../app/device_registration.dart';
import '../../../core/config/app_config.dart';
import '../../guide/guide_avatar.dart';
import '../../guide/guide_sheet.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';
import '../../auth/presentation/session_controller.dart';
import '../../claims/presentation/claims_providers.dart';
import 'settings_providers.dart';
import '../../guide/guide_spotlight.dart';

final _versionProvider = FutureProvider<String>((ref) async {
  final p = await PackageInfo.fromPlatform();
  return '${p.version} (${p.buildNumber})';
});

Future<void> signOutEverywhere(BuildContext context, WidgetRef ref) async {
  await unregisterPush(ref);
  await ref.read(billingProvider).reset();
  await ref.read(sessionProvider.notifier).signOut();
  if (context.mounted) context.go('/signin');
}

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  String _notifLine(Me me) {
    final p = me.profile;
    final on = ['return', 'warranty', 'registration'].where(p.prefEnabled).length;
    if (on == 0) return 'Off';
    final h = int.parse(p.alertTime.substring(0, 2)), m = p.alertTime.substring(3, 5);
    return '${h % 12 == 0 ? 12 : h % 12}:$m ${h < 12 ? 'AM' : 'PM'} · ${p.timezone}';
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
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 110),
            children: [
              Text('Settings', style: context.t.headlineMedium),
              const SizedBox(height: 14),
              AsyncBody<Me>(
                value: me,
                onRetry: () => ref.invalidate(meProvider),
                data: (m) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        WAvatar(m.profile.name, size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                m.profile.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text),
                              ),
                              Text(m.profile.email, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.textMuted)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    WCard(
                      onTap: () => context.push('/settings/plan'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                m.plan.name,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.text),
                              ),
                              const Spacer(),
                              Icon(PhosphorIconsRegular.caretRight, size: 16, color: c.textSubtle),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${m.itemsLine} · ${fmtBytes(m.usage.storageUsed)} of ${fmtBytes(m.usage.storageLimit)}',
                            style: TextStyle(fontSize: 13, color: c.textMuted),
                          ),
                          Text(m.aiLine, style: TextStyle(fontSize: 13, color: c.textMuted)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    WGroup(
                      children: [
                        WListRow(
                          icon: PhosphorIconsRegular.bell,
                          title: 'Reminders',
                          subtitle: _notifLine(m),
                          onTap: () => context.push('/settings/reminders'),
                        ),
                        WListRow(
                          icon: PhosphorIconsRegular.trophy,
                          title: 'Outcomes',
                          // Don't flash "0 confirmed" while the list is still loading.
                          subtitle: outcomes == null ? '…' : '${outcomes.length} confirmed',
                          onTap: () => context.push('/outcomes'),
                        ),
                        WListRow(icon: PhosphorIconsRegular.chatCircleText, title: 'Claims', onTap: () => context.push('/claims')),
                      ],
                    ),
                    WGroup(
                      children: [
                        WListRow(
                          icon: PhosphorIconsRegular.globe,
                          title: 'Region & currency',
                          subtitle: '${m.profile.country} · ${m.profile.currency}',
                          onTap: () => context.push('/settings/region'),
                        ),
                        WListRow(
                          icon: PhosphorIconsRegular.lockSimple,
                          title: 'Privacy & AI',
                          subtitle: m.profile.aiConsent ? 'AI reading on' : 'AI reading off',
                          onTap: () => context.push('/settings/privacy'),
                        ),
                        WListRow(
                          icon: PhosphorIconsRegular.export,
                          title: 'Export your data',
                          subtitle: 'Free on every plan',
                          onTap: () => context.push('/settings/export'),
                        ),
                      ],
                    ),
                    WGroup(
                      children: [
                        WListRow(
                          icon: PhosphorIconsRegular.calendarCheck,
                          title: 'Monthly digest',
                          subtitle: DateFormatName.month(),
                          onTap: () => context.push('/settings/digest'),
                        ),
                        WListRow(icon: PhosphorIconsRegular.chartLineUp, title: 'Your ${DateTime.now().year}', onTap: () => context.push('/settings/annual')),
                        WListRow(icon: PhosphorIconsRegular.creditCard, title: 'Payment cards', subtitle: 'Labels only', onTap: () => context.push('/cards')),
                        WListRow(
                          leading: const GuideAvatar(size: 36),
                          title: 'Ask Pip, your guide',
                          subtitle: 'Step-by-step help with anything',
                          onTap: () => showGuide(context),
                        ),
                        WListRow(icon: PhosphorIconsRegular.lifebuoy, title: 'Help & support', onTap: () => context.push('/settings/support')),
                      ],
                    ),
                    const WSectionHeader('Appearance'),
                    GuideTarget(id: 'settings.appearance', child: _AppearancePicker(value: mode, onChanged: (v) => ref.read(themeModeProvider.notifier).set(v))),
                    const SizedBox(height: 12),
                    const WSectionHeader('More'),
                    WGroup(
                      children: [
                        WListRow(
                          icon: PhosphorIconsRegular.usersThree,
                          title: 'Household',
                          subtitle: 'Share items with family',
                          trailing: m.plan.isPro ? null : const WTag('Pro', kind: WTagKind.outline),
                          onTap: () => context.push('/household'),
                        ),
                        WListRow(
                          icon: PhosphorIconsRegular.envelopeSimple,
                          title: 'Email forwarding',
                          subtitle: 'Forward e-receipts to your vault',
                          trailing: !AppConfig.emailForwardingLive
                              ? const WTag('Soon', kind: WTagKind.outline)
                              : m.plan.isPro
                                  ? null
                                  : const WTag('Pro', kind: WTagKind.outline),
                          onTap: () => context.push('/settings/email-forwarding'),
                        ),
                        WListRow(icon: PhosphorIconsRegular.tray, title: 'Drafts to review', subtitle: 'Forwarded and shared receipts', onTap: () => context.push('/drafts')),
                        WListRow(
                          icon: PhosphorIconsRegular.buildings,
                          title: 'Properties',
                          subtitle: 'For landlords and property managers',
                          trailing: const WTag('Business', kind: WTagKind.outline),
                          onTap: () => context.push('/portfolio'),
                        ),
                      ],
                    ),
                    const WSectionHeader('Account'),
                    WGroup(
                      children: [
                        WListRow(icon: PhosphorIconsRegular.key, title: 'Sign-in methods', onTap: () => context.push('/settings/sign-in-methods')),
                        WListRow(icon: PhosphorIconsRegular.userSwitch, title: 'Switch account', onTap: () => context.push('/settings/switch-account')),
                        WListRow(
                          icon: PhosphorIconsRegular.signOut,
                          title: 'Sign out',
                          caret: false,
                          onTap: () async {
                            final ok = await confirmDialog(
                              context,
                              title: 'Sign out?',
                              message: 'Cached items, documents and drafts are cleared from this phone. Your data stays in your account.',
                              confirm: 'Sign out',
                            );
                            if (ok && context.mounted) await signOutEverywhere(context, ref);
                          },
                        ),
                        WListRow(
                          icon: PhosphorIconsRegular.trash,
                          title: 'Delete account',
                          titleColor: c.danger,
                          onTap: () => context.push('/settings/delete-account'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text('Warrantra ${ref.watch(_versionProvider).value ?? ''}', style: TextStyle(fontSize: 12, color: c.textSubtle)),
                    ),
                    const SizedBox(height: 4),
                    Center(
                      child: Text("Warrantra isn't insurance and can't guarantee a claim.", style: TextStyle(fontSize: 11.5, color: c.textSubtle)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DateFormatName {
  static String month() => const [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ][DateTime.now().month - 1];
}

class SwitchAccountScreen extends ConsumerWidget {
  const SwitchAccountScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    Widget point(IconData i, String t) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(i, color: c.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(t, style: TextStyle(color: c.textMuted, height: 1.45)),
          ),
        ],
      ),
    );
    return WScreen(
      title: 'Switch account',
      bottom: WButton('Sign out and switch', onPressed: () => signOutEverywhere(context, ref)),
      children: [
        if (me != null)
          WCard(
            child: Row(
              children: [
                WAvatar(me.profile.name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(me.profile.email, style: TextStyle(color: c.text)),
                      Text('This phone', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                    ],
                  ),
                ),
                const WTag('Current', kind: WTagKind.accent),
              ],
            ),
          ),
        const SizedBox(height: 16),
        point(PhosphorIconsRegular.broom, 'We sign you out and clear cached items, documents and drafts from this phone before the next account loads.'),
        point(PhosphorIconsRegular.gitMerge, 'Accounts are never merged automatically, even if they use the same email.'),
        point(PhosphorIconsRegular.bell, 'Reminders for this account stop on this phone until you sign back in.'),
      ],
    );
  }
}

/// Three preview cards (System / Light / Dark), each a tiny screen drawn in that theme.
class _AppearancePicker extends StatelessWidget {
  const _AppearancePicker({required this.value, required this.onChanged});
  final ThemeMode value;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const options = [
      (ThemeMode.system, 'System', PhosphorIconsRegular.deviceMobile),
      (ThemeMode.light, 'Light', PhosphorIconsRegular.sun),
      (ThemeMode.dark, 'Dark', PhosphorIconsRegular.moon),
    ];
    return Row(children: [
      for (final (i, (mode, label, icon)) in options.indexed) ...[
        if (i > 0) const SizedBox(width: 10),
        Expanded(child: _AppearanceCard(mode: mode, label: label, icon: icon, selected: value == mode, onTap: () => onChanged(mode))),
      ],
    ]);
  }
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.mode, required this.label, required this.icon, required this.selected, required this.onTap});
  final ThemeMode mode;
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Semantics(
      button: true,
      selected: selected,
      label: '$label appearance',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
          decoration: BoxDecoration(
            color: selected ? c.accentSoft : c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? c.accent : c.divider, width: selected ? 2 : 1),
          ),
          child: Column(children: [
            AspectRatio(
              aspectRatio: 0.82,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: mode == ThemeMode.system
                    ? Stack(fit: StackFit.expand, children: [
                        const _MiniScreen(WColors.light),
                        ClipPath(clipper: _DiagonalHalf(), child: const _MiniScreen(WColors.dark)),
                      ])
                    : _MiniScreen(mode == ThemeMode.dark ? WColors.dark : WColors.light),
              ),
            ),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 16, color: selected ? c.accent : c.textMuted),
              const SizedBox(width: 5),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: selected ? c.text : c.textMuted)),
              ),
            ]),
            const SizedBox(height: 6),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? c.accent : Colors.transparent,
                border: Border.all(color: selected ? c.accent : c.textSubtle, width: 1.5),
              ),
              child: selected ? Icon(PhosphorIconsBold.check, size: 11, color: c.onAccent) : null,
            ),
          ]),
        ),
      ),
    );
  }
}

/// A tiny screen in the given palette: header, two cards and an accent button.
class _MiniScreen extends StatelessWidget {
  const _MiniScreen(this.p);
  final WColors p;

  @override
  Widget build(BuildContext context) {
    Widget bar(double? w, Color color, {double h = 4}) => Container(width: w, height: h, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)));
    Widget card() => Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(5), border: Border.all(color: p.divider, width: 0.5)),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: p.accentSoft, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 5),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                FractionallySizedBox(widthFactor: 0.9, child: bar(null, p.text.withValues(alpha: 0.75), h: 3)),
                const SizedBox(height: 3),
                FractionallySizedBox(widthFactor: 0.6, child: bar(null, p.textSubtle.withValues(alpha: 0.6), h: 3)),
              ]),
            ),
          ]),
        );
    return Container(
      color: p.bg,
      padding: const EdgeInsets.fromLTRB(7, 9, 7, 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        bar(26, p.text.withValues(alpha: 0.85), h: 5),
        const SizedBox(height: 7),
        card(),
        const SizedBox(height: 5),
        card(),
        const Spacer(),
        Container(height: 9, decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(4))),
      ]),
    );
  }
}

/// Lower-right half of the preview (for the System card's light/dark split).
class _DiagonalHalf extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width, 0)
    ..lineTo(s.width, s.height)
    ..lineTo(0, s.height)
    ..close();
  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
