import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';

Future<void> _patch(BuildContext context, WidgetRef ref, Map<String, dynamic> body) async {
  try {
    await ref.read(accountRepositoryProvider).updateProfile(body);
    ref.invalidate(meProvider);
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}

class ReminderPrefsScreen extends ConsumerWidget {
  const ReminderPrefsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider);
    return WScreen(title: 'Reminders', children: [
      AsyncBody<Me>(
        value: me,
        onRetry: () => ref.invalidate(meProvider),
        data: (m) {
          final p = m.profile;
          Widget block(String key, String title, List<int> fallback, List<int> choices) {
            final on = p.prefEnabled(key);
            final offs = p.offsets(key, fallback).toSet();
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              WSwitchRow(title: title, value: on, onChanged: (v) => _patch(context, ref, {'notification_preferences': {key: {'enabled': v, 'offsets_days': offs.toList()}}})),
              if (on)
                WMultiChips<int>(
                  label: 'Days before',
                  options: [for (final d in choices) (d, d == 0 ? 'Same day' : '$d')],
                  values: offs,
                  onChanged: (v) => _patch(context, ref, {'notification_preferences': {key: {'enabled': true, 'offsets_days': (v.toList()..sort((a, b) => b.compareTo(a)))}}}),
                ),
              const SizedBox(height: 14),
            ]);
          }

          final hour = p.alertTime.substring(0, 5);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            block('return', 'Return windows', const [7, 3, 1], const [14, 7, 3, 1, 0]),
            block('warranty', 'Coverage ending', const [30, 7], const [90, 60, 30, 14, 7]),
            block('registration', 'Registration', const [7, 1], const [14, 7, 3, 1]),
            block('claim_follow_up', 'Claim follow-ups', const [0], const [3, 1, 0]),
            block('maintenance', 'Maintenance tasks', const [3, 0], const [7, 3, 1, 0]),
            WChoiceChips<String>(
              label: 'Alert time',
              options: const [('08:00', '8 am'), ('09:00', '9 am'), ('12:00', 'Noon'), ('18:00', '6 pm'), ('20:00', '8 pm')],
              value: hour,
              onChanged: (v) => _patch(context, ref, {'alert_local_time': v}),
            ),
            const SizedBox(height: 8),
            Text('Time zone: ${p.timezone}. Follows your phone when you travel.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
            const SizedBox(height: 14),
            WSwitchRow(
              title: 'Monthly digest',
              subtitle: "On the 1st: what's coming up and what's missing.",
              value: p.preferences['monthly_digest'] is Map && (p.preferences['monthly_digest'] as Map)['enabled'] == true,
              onChanged: (v) => _patch(context, ref, {'notification_preferences': {'monthly_digest': {'enabled': v}}}),
            ),
            const SizedBox(height: 14),
            Text("Reminders are scheduled on our servers, so they don't depend on opening the app. Delivery still depends on your phone and network; Action Center is the full list.",
                style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.45)),
          ]);
        },
      ),
    ]);
  }
}

class RegionScreen extends ConsumerWidget {
  const RegionScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider);
    return WScreen(title: 'Region & currency', children: [
      AsyncBody<Me>(
        value: me,
        data: (m) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WChoiceChips<String>(
            label: 'Country',
            options: const [('US', 'United States'), ('CA', 'Canada'), ('GB', 'United Kingdom')],
            value: m.profile.country,
            onChanged: (v) => _patch(context, ref, {'country_code': v}),
          ),
          if (m.profile.country != 'US') ...[
            const SizedBox(height: 8),
            const WNote('Warrantra launches in the US first. This country is waiting on its own policy and privacy review, so some features may change.', icon: PhosphorIconsRegular.hourglass),
          ],
          const SizedBox(height: 14),
          WChoiceChips<String>(
            label: 'Default currency for new purchases',
            options: const [('USD', 'USD'), ('CAD', 'CAD'), ('GBP', 'GBP')],
            value: m.profile.currency,
            onChanged: (v) => _patch(context, ref, {'default_currency': v}),
          ),
          const SizedBox(height: 6),
          Text('Each purchase keeps the currency it was paid in. Amounts are never converted.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          const SizedBox(height: 14),
          WKeyValue('Time zone', m.profile.timezone, note: 'Used for reminder times. Follows your phone.'),
          const SizedBox(height: 14),
          const WNote("Consumer rights differ by country. Warrantra tracks the dates you record and doesn't decide what your legal rights are.", icon: PhosphorIconsRegular.scales),
        ]),
      ),
    ]);
  }
}

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider);
    Widget point(IconData i, String t) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20, color: c.accent),
            const SizedBox(width: 12),
            Expanded(child: Text(t, style: TextStyle(color: c.textMuted, height: 1.45))),
          ]),
        );
    return WScreen(title: 'Privacy & AI', children: [
      AsyncBody<Me>(
        value: me,
        data: (m) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WSwitchRow(
            title: 'Read receipts with third-party AI',
            subtitle: m.profile.aiConsent ? 'On: images you choose are sent to our AI provider to fill in fields.' : 'Off: manual entry only.',
            value: m.profile.aiConsent,
            onChanged: (v) async {
              try {
                await ref.read(accountRepositoryProvider).setAiConsent(v);
                ref.invalidate(meProvider);
              } catch (e) {
                if (context.mounted) showFailure(context, e);
              }
            },
          ),
          WSwitchRow(
            title: 'Share product analytics',
            subtitle: 'Counts of screens and actions. Never receipt text, serial numbers or documents.',
            value: m.profile.analyticsConsent,
            onChanged: (v) => _patch(context, ref, {'analytics_consent': v}),
          ),
          const WSectionHeader('How your data is handled'),
          point(PhosphorIconsRegular.lockSimple, 'Files are stored privately. Viewing uses links that expire in minutes.'),
          point(PhosphorIconsRegular.chartBar, 'Analytics never include receipt text, serial numbers or document contents.'),
          point(PhosphorIconsRegular.clockCounterClockwise, 'Failed scans, logs and backups follow a published retention schedule.'),
          point(PhosphorIconsRegular.globe, 'You can also request deletion on the web at ${AppConfig.webDeletionUrl.replaceFirst('https://', '')}.'),
          Wrap(spacing: 4, children: [
            WButton.ghost('Privacy policy', onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication)),
            WButton.ghost('Terms', onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication)),
          ]),
        ]),
      ),
    ]);
  }
}
