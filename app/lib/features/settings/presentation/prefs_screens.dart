import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/device_registration.dart';
import '../../../core/config/app_config.dart';
import '../../../core/push/push_service.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';

/// Settings that change instantly on screen and save in the background.
/// If the save fails, the old value comes back with a message.
mixin _InstantSave<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final Map<String, Object?> pending = {};
  final Map<String, int> _gen = {};

  Future<void> save(
    String key,
    Object? shown,
    Map<String, dynamic> body,
  ) async {
    final g = (_gen[key] ?? 0) + 1;
    _gen[key] = g;
    setState(() => pending[key] = shown);
    try {
      await ref.read(accountRepositoryProvider).updateProfile(body);
      ref.invalidate(meProvider);
      await ref.read(meProvider.future);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      // A newer tap on the same setting owns the pending value.
      if (mounted && _gen[key] == g) setState(() => pending.remove(key));
    }
  }

  V shown<V>(String key, V saved) =>
      pending.containsKey(key) ? pending[key] as V : saved;
}

String _clock(String hhmm) {
  final h = int.parse(hhmm.substring(0, 2)),
      m = int.parse(hhmm.substring(3, 5));
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
}

String _offsetLabel(int d) => switch (d) {
  0 => 'Same day',
  1 => '1 day',
  7 => '1 week',
  14 => '2 weeks',
  30 => '1 month',
  60 => '2 months',
  90 => '3 months',
  _ => '$d days',
};

String _offsetSummary(List<int> offs) {
  if (offs.isEmpty) return 'No reminders set';
  final sorted = [...offs]..sort((a, b) => b.compareTo(a));
  final words = sorted
      .map(
        (d) =>
            d == 0 ? 'on the day' : '${_offsetLabel(d).toLowerCase()} before',
      )
      .toList();
  final joined = words.length == 1
      ? words.first
      : '${words.sublist(0, words.length - 1).join(', ')} and ${words.last}';
  return '${sorted.length} reminder${sorted.length == 1 ? '' : 's'}: $joined';
}

class _Kind {
  const _Kind(
    this.key,
    this.icon,
    this.title,
    this.about,
    this.example,
    this.fallback,
    this.choices,
  );
  final String key, title, about, example;
  final IconData icon;
  final List<int> fallback, choices;
}

const _kinds = [
  _Kind(
    'return',
    PhosphorIconsRegular.arrowUUpLeft,
    'Return windows',
    'Before you lose the chance to send something back.',
    '“Your AirPods return closes in 3 days”',
    [7, 3, 1],
    [14, 7, 3, 1, 0],
  ),
  _Kind(
    'warranty',
    PhosphorIconsRegular.shieldCheck,
    'Coverage ending',
    'Before a warranty or protection plan runs out.',
    '“Sony TV warranty ends in 1 month”',
    [30, 7, 1],
    [90, 60, 30, 14, 7, 1],
  ),
  _Kind(
    'registration',
    PhosphorIconsRegular.sealCheck,
    'Product registration',
    'When registering unlocks extra coverage.',
    '“Register your Dyson to keep the extra year”',
    [7, 1],
    [14, 7, 3, 1],
  ),
  _Kind(
    'claim_follow_up',
    PhosphorIconsRegular.chatCircleText,
    'Claim follow-ups',
    'When it is time to chase an open claim.',
    '“Follow up with Samsung about your claim”',
    [0],
    [3, 1, 0],
  ),
  _Kind(
    'maintenance',
    PhosphorIconsRegular.wrench,
    'Maintenance',
    'Filters, descaling and other upkeep you set.',
    '“Time to clean the washer filter”',
    [3, 0],
    [7, 3, 1, 0],
  ),
];

class ReminderPrefsScreen extends ConsumerStatefulWidget {
  const ReminderPrefsScreen({super.key});
  @override
  ConsumerState<ReminderPrefsScreen> createState() => _ReminderPrefsState();
}

class _ReminderPrefsState extends ConsumerState<ReminderPrefsScreen>
    with _InstantSave, WidgetsBindingObserver {
  String? _permission; // granted | provisional | denied | unknown | unsupported
  bool _testing = false;
  bool _blocked = false; // asking didn't work; the button opens system settings

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from the phone's settings: pick up the new permission and register.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission().then((_) {
        if (_permission == 'granted' || _permission == 'provisional') {
          registerDevice(ref);
        }
      });
    }
  }

  Future<void> _checkPermission({bool ask = false}) async {
    final push = PushService.instance;
    await push.init();
    final p = push.supported ? await push.permission(ask: ask) : 'unsupported';
    if (mounted) setState(() => _permission = p);
  }

  Future<void> _turnOn() async {
    if (!_blocked) {
      await registerDevice(ref, askPermission: true);
      await _checkPermission();
    }
    // Android stops asking after the second "Don't allow" (and Firebase then reports it as
    // undetermined), so if asking didn't work, send people to the switch itself.
    final allowed = _permission == 'granted' || _permission == 'provisional';
    if (mounted && !allowed) {
      setState(() => _blocked = true);
      await AppSettings.openAppSettings(type: AppSettingsType.notification);
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      await registerDevice(ref);
      final sent = await ref.read(accountRepositoryProvider).testPush();
      if (mounted) {
        showToast(
          context,
          sent > 0 ? 'Test sent. It should arrive in a few seconds.' : "This phone isn't registered for notifications yet. Turn them on above.",
        );
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pickTime(String current) async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(current.substring(0, 2)),
        minute: int.parse(current.substring(3, 5)),
      ),
      helpText: 'Send reminders at',
    );
    if (t == null) return;
    final v =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    if (v != current) save('time', v, {'alert_local_time': v});
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider);
    return WScreen(
      title: 'Reminders',
      children: [
        AsyncBody<Me>(
          value: me,
          onRetry: () => ref.invalidate(meProvider),
          data: (m) {
            final p = m.profile;
            final time = shown<String>('time', p.alertTime.substring(0, 5));
            final kinds = [
              for (final k in _kinds)
                (
                  k,
                  shown<bool>('${k.key}.on', p.prefEnabled(k.key)),
                  shown<List<int>>(
                    '${k.key}.offs',
                    p.offsets(k.key, k.fallback),
                  ),
                ),
            ];
            final activeCount = kinds.where((k) => k.$2).length;
            final digest = shown<bool>(
              'digest',
              p.preferences['monthly_digest'] is Map &&
                  (p.preferences['monthly_digest'] as Map)['enabled'] == true,
            );
            final allowed =
                _permission == 'granted' || _permission == 'provisional';

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // This phone
                WCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          IconTile(
                            allowed
                                ? PhosphorIconsRegular.bellRinging
                                : PhosphorIconsRegular.bellSlash,
                            emphasis: allowed,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _permission == null
                                      ? 'Checking this phone…'
                                      : allowed
                                      ? 'Notifications are on'
                                      : _permission == 'unsupported'
                                      ? 'Notifications come to Android for now'
                                      : 'Notifications are off on this phone',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: c.text,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  allowed
                                      ? '$activeCount of ${_kinds.length} reminder types on · ${_clock(time)}'
                                      : _permission == 'denied' || _blocked
                                      ? "They're blocked in your phone's settings. Reminders still show in Action Center."
                                      : 'Reminders still appear in Action Center inside the app.',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: c.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (_permission != null &&
                          _permission != 'unsupported') ...[
                        const SizedBox(height: 12),
                        allowed
                            ? WButton.secondary(
                                'Send a test notification',
                                icon: PhosphorIconsRegular.paperPlaneTilt,
                                loading: _testing,
                                onPressed: _test,
                              )
                            : WButton(
                                _permission == 'denied' || _blocked
                                    ? 'Open notification settings'
                                    : 'Turn on notifications',
                                icon: PhosphorIconsRegular.bell,
                                onPressed: _turnOn,
                              ),
                      ],
                    ],
                  ),
                ),

                const WSectionHeader('When to send them'),
                WGroup(
                  children: [
                    WListRow(
                      icon: PhosphorIconsRegular.clock,
                      title: 'Time of day',
                      subtitle: 'Tap to pick any time',
                      trailing: Text(
                        _clock(time),
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: c.accent,
                        ),
                      ),
                      onTap: () => _pickTime(time),
                    ),
                    WListRow(
                      icon: PhosphorIconsRegular.globe,
                      title: 'Time zone',
                      subtitle:
                          '${p.timezone} · follows your phone when you travel',
                      caret: false,
                    ),
                  ],
                ),

                const WSectionHeader('What to remind me about'),
                for (final (k, on, offs) in kinds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: WCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              IconTile(k.icon, size: 36, emphasis: on),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      k.title,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: c.text,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      k.about,
                                      style: TextStyle(
                                        fontSize: 13,
                                        height: 1.35,
                                        color: c.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Switch(
                                value: on,
                                onChanged: (v) => save('${k.key}.on', v, {
                                  'notification_preferences': {
                                    k.key: {'enabled': v, 'offsets_days': offs},
                                  },
                                }),
                              ),
                            ],
                          ),
                          if (on) ...[
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                // Saved offsets always get a chip, so nothing set is hidden or stuck on.
                                for (final d in ({
                                  ...k.choices,
                                  ...offs,
                                }.toList()..sort((a, b) => b.compareTo(a))))
                                  FilterChip(
                                    label: Text(_offsetLabel(d)),
                                    selected: offs.contains(d),
                                    showCheckmark: false,
                                    onSelected: (sel) {
                                      final next = {...offs};
                                      sel ? next.add(d) : next.remove(d);
                                      if (next.isEmpty) {
                                        return showToast(
                                          context,
                                          'Keep at least one, or turn this reminder off.',
                                        );
                                      }
                                      final list = next.toList()
                                        ..sort((a, b) => b.compareTo(a));
                                      save('${k.key}.offs', list, {
                                        'notification_preferences': {
                                          k.key: {
                                            'enabled': true,
                                            'offsets_days': list,
                                          },
                                        },
                                      });
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _offsetSummary(offs),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: c.textMuted,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Looks like: ${k.example}',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontStyle: FontStyle.italic,
                                color: c.textSubtle,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                const WSectionHeader('Summary'),
                WCard(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      IconTile(
                        PhosphorIconsRegular.calendarCheck,
                        size: 36,
                        emphasis: digest,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Monthly digest',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: c.text,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "On the 1st: what's ending soon, what's missing, and what you got back.",
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.35,
                                color: c.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: digest,
                        onChanged: (v) => save('digest', v, {
                          'notification_preferences': {
                            'monthly_digest': {'enabled': v},
                          },
                        }),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      PhosphorIconsRegular.info,
                      size: 16,
                      color: c.textSubtle,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Reminders are scheduled on our servers, so they arrive even if you don't open the app. Delivery still depends on your phone and network; Action Center always has the full list.",
                        style: TextStyle(
                          fontSize: 12.5,
                          color: c.textSubtle,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class RegionScreen extends ConsumerStatefulWidget {
  const RegionScreen({super.key});
  @override
  ConsumerState<RegionScreen> createState() => _RegionState();
}

class _RegionState extends ConsumerState<RegionScreen> with _InstantSave {
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider);
    return WScreen(
      title: 'Region & currency',
      children: [
        AsyncBody<Me>(
          value: me,
          onRetry: () => ref.invalidate(meProvider),
          data: (m) {
            final country = shown<String>('country', m.profile.country);
            final currency = shown<String>('currency', m.profile.currency);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WChoiceChips<String>(
                  label: 'Country',
                  options: const [
                    ('US', 'United States'),
                    ('CA', 'Canada'),
                    ('GB', 'United Kingdom'),
                  ],
                  value: country,
                  onChanged: (v) {
                    if (v == country) return;
                    const cur = {'US': 'USD', 'CA': 'CAD', 'GB': 'GBP'};
                    save('country', v, {'country_code': v});
                    // Moving country usually means a new default currency too.
                    if (cur[v] != currency) {
                      save('currency', cur[v], {'default_currency': cur[v]});
                    }
                  },
                ),
                if (country != 'US') ...[
                  const SizedBox(height: 8),
                  const WNote(
                    'Warrantra launches in the US first. This country is waiting on its own policy and privacy review, so some features may change.',
                    icon: PhosphorIconsRegular.hourglass,
                  ),
                ],
                const SizedBox(height: 14),
                WChoiceChips<String>(
                  label: 'Default currency for new purchases',
                  options: const [
                    ('USD', r'USD $'),
                    ('CAD', r'CAD $'),
                    ('GBP', 'GBP £'),
                  ],
                  value: currency,
                  onChanged: (v) => v == currency
                      ? null
                      : save('currency', v, {'default_currency': v}),
                ),
                const SizedBox(height: 6),
                Text(
                  'Each purchase keeps the currency it was paid in. Amounts are never converted.',
                  style: TextStyle(fontSize: 12.5, color: c.textSubtle),
                ),
                const SizedBox(height: 14),
                WKeyValue(
                  'Time zone',
                  m.profile.timezone,
                  note: 'Used for reminder times. Follows your phone.',
                ),
                const SizedBox(height: 14),
                const WNote(
                  "Consumer rights differ by country. Warrantra tracks the dates you record and doesn't decide what your legal rights are.",
                  icon: PhosphorIconsRegular.scales,
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class PrivacyScreen extends ConsumerStatefulWidget {
  const PrivacyScreen({super.key});
  @override
  ConsumerState<PrivacyScreen> createState() => _PrivacyState();
}

class _PrivacyState extends ConsumerState<PrivacyScreen> with _InstantSave {
  /// AI consent has its own endpoint (it records the consent version shown).
  Future<void> _setAi(bool v) async {
    setState(() => pending['ai'] = v);
    try {
      await ref.read(accountRepositoryProvider).setAiConsent(v);
      ref.invalidate(meProvider);
      await ref.read(meProvider.future);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => pending.remove('ai'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider);
    Widget toggle(IconData icon, Color tint, String title, String subtitle, bool value, ValueChanged<bool> onChanged) => Row(children: [
          WTintIcon(icon, tint, size: 38),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: c.text)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 12.5, height: 1.4, color: c.textMuted)),
            ]),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ]);
    Widget point(IconData i, Color tint, String title, String body) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          WTintIcon(i, tint, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
              const SizedBox(height: 2),
              Text(body, style: TextStyle(fontSize: 13, color: c.textMuted, height: 1.4)),
            ]),
          ),
        ]);
    return WScreen(
      title: 'Privacy & AI',
      children: [
        AsyncBody<Me>(
          value: me,
          data: (m) {
            final ai = shown<bool>('ai', m.profile.aiConsent);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                WHeroCard(
                  eyebrow: 'Privacy',
                  title: 'Your records stay yours',
                  icon: PhosphorIconsFill.shieldCheck,
                  children: [
                    const SizedBox(height: 6),
                    Text('Private storage and short-lived links. You choose what AI sees.', style: WHeroCard.muted()),
                  ],
                ),
                const SizedBox(height: 22),
                const WSectionHeader('Your choices'),
                WCard(
                  child: Column(children: [
                    toggle(PhosphorIconsRegular.sparkle, WTint.orchid, 'Read receipts with AI',
                        ai ? 'On: images you choose are sent to our AI provider to fill in fields.' : 'Off: manual entry only.', ai, _setAi),
                    Divider(height: 26, color: c.divider),
                    toggle(PhosphorIconsRegular.chartBar, WTint.blue, 'Share product analytics',
                        'Counts of screens and actions. Never receipt text, serial numbers or documents.',
                        shown<bool>('analytics', m.profile.analyticsConsent), (v) => save('analytics', v, {'analytics_consent': v})),
                  ]),
                ),
                const SizedBox(height: 22),
                const WSectionHeader('How your data is handled'),
                WCard(
                  child: Column(children: [
                    point(PhosphorIconsRegular.lockSimple, WTint.violet, 'Stored privately', 'Files are private to your account. Viewing uses links that expire in minutes.'),
                    Divider(height: 26, color: c.divider),
                    point(PhosphorIconsRegular.eyeSlash, WTint.green, 'Analytics stay anonymous', 'Never receipt text, serial numbers or document contents.'),
                    Divider(height: 26, color: c.divider),
                    point(PhosphorIconsRegular.clockCounterClockwise, WTint.amber, 'Kept only as long as needed', 'Failed scans, logs and backups follow a published retention schedule.'),
                    Divider(height: 26, color: c.divider),
                    point(PhosphorIconsRegular.globe, WTint.coral, 'Delete from anywhere',
                        'Request deletion on the web at ${AppConfig.webDeletionUrl.replaceFirst('https://', '')}, even without the app.'),
                  ]),
                ),
                const SizedBox(height: 12),
                Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  WButton.ghost('Privacy policy',
                      onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication)),
                  Text('·', style: TextStyle(color: c.textSubtle)),
                  WButton.ghost('Terms', onPressed: () => launchUrl(Uri.parse(AppConfig.termsUrl), mode: LaunchMode.externalApplication)),
                ]),
              ],
            );
          },
        ),
      ],
    );
  }
}
