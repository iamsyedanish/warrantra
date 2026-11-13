import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../../home/domain/action_center.dart';
import '../../home/presentation/home_providers.dart';
import '../domain/settings.dart';
import 'settings_providers.dart';
import 'settings_screen.dart';

// ---------------------------------------------------------------------------
// Export
// ---------------------------------------------------------------------------
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key});
  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  Timer? _poll;
  bool busy = false;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _watch() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
      ref.invalidate(exportsProvider);
      final list = await ref.read(exportsProvider.future);
      if (list.isEmpty || !list.first.busy) _poll?.cancel();
    });
  }

  Future<void> _start() async {
    setState(() => busy = true);
    try {
      await ref.read(settingsRepositoryProvider).requestExport();
      ref.invalidate(exportsProvider);
      _watch();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _download(ExportJob j) async {
    try {
      final links = await ref.read(settingsRepositoryProvider).exportLinks(j.id);
      if (links.dataUrl != null) await launchUrl(Uri.parse(links.dataUrl!), mode: LaunchMode.externalApplication);
      if (links.manifestUrl != null && mounted) {
        final more = await confirmDialog(context, title: 'Original files', message: 'Also open the list of links to your original documents? Those links expire.', confirm: 'Open');
        if (more) await launchUrl(Uri.parse(links.manifestUrl!), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final jobs = ref.watch(exportsProvider).value ?? const <ExportJob>[];
    final me = ref.watch(meProvider).value;
    final latest = jobs.isEmpty ? null : jobs.first;
    if (latest?.busy ?? false) {
      if (_poll == null || !_poll!.isActive) _watch();
    }
    Widget row(IconData i, String t, String s) => WListRow(icon: i, title: t, subtitle: s, caret: false);
    return WScreen(
      title: 'Export your data',
      bottom: latest?.busy ?? false
          ? const WButton('Preparing your export…', loading: true)
          : latest?.ready ?? false
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  WButton('Download', icon: PhosphorIconsRegular.downloadSimple, onPressed: () => _download(latest!)),
                  const SizedBox(height: 6),
                  WButton.ghost('Prepare a new export', onPressed: _start),
                ])
              : WButton('Prepare export', loading: busy, onPressed: _start),
      children: [
        Text('Yours on every plan', style: context.t.titleLarge),
        Text('Export works without paying and after cancelling.', style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 12),
        row(PhosphorIconsRegular.fileText, 'Items & coverage', 'JSON'),
        row(PhosphorIconsRegular.fileZip, 'Original documents', 'Download links · ${fmtBytes(me?.usage.storageUsed)}'),
        row(PhosphorIconsRegular.chatCircleText, 'Claims & outcomes', 'Included in JSON'),
        const SizedBox(height: 10),
        if (latest?.ready ?? false)
          WNote('Export ready${latest!.itemCount == null ? '' : ' · ${latest.itemCount} items, ${latest.fileCount ?? 0} files'}. Download links expire ${fmtDate(latest.expiresAt)}.', icon: PhosphorIconsRegular.checkCircle),
        if (latest?.state == 'failed') const WNote("The last export didn't finish. Try again; if it keeps failing, contact support.", icon: PhosphorIconsRegular.warningCircle),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Delete account
// ---------------------------------------------------------------------------
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});
  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  int step = 0;
  final typed = TextEditingController();
  bool busy = false;

  Future<void> _go() async {
    setState(() => busy = true);
    final repo = ref.read(settingsRepositoryProvider);
    try {
      if (step == 0) {
        await repo.requestDeletion();
        setState(() => step = 1);
      } else if (step == 1) {
        await repo.confirmDeletion();
        setState(() => step = 2);
        ref.invalidate(deletionStatusProvider);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(settingsRepositoryProvider).cancelDeletion();
      ref.invalidate(meProvider);
      if (mounted) {
        showToast(context, 'Deletion cancelled. Your account is active again.');
        context.pop();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final status = ref.watch(deletionStatusProvider).value;
    final open = status?.where((s) => s.pending || s.running).firstOrNull;
    if (open != null && step == 0) step = open.pending ? 1 : 2;
    final me = ref.watch(meProvider).value;
    return WScreen(
      title: 'Delete account',
      bottom: switch (step) {
        0 => WButton.danger('Continue to delete', loading: busy, onPressed: _go),
        1 => Column(mainAxisSize: MainAxisSize.min, children: [
            WButton.danger('Delete my account', loading: busy, onPressed: typed.text.trim() == 'DELETE' ? _go : null),
            const SizedBox(height: 6),
            WButton.ghost('Keep my account', onPressed: _cancel),
          ]),
        _ => WButton.secondary('Sign out', onPressed: () => signOutEverywhere(context, ref)),
      },
      children: [
        if (step == 0) ...[
          Text('This deletes everything', style: context.t.titleLarge),
          const SizedBox(height: 6),
          Text("Items, coverage, reminders, claims, outcomes and every original file. It can't be undone.", style: TextStyle(color: c.textMuted, height: 1.45)),
          const SizedBox(height: 14),
          WListRow(icon: PhosphorIconsRegular.export, title: 'Export first', subtitle: 'Keep a copy of your receipts and records', onTap: () => context.push('/settings/export')),
          const SizedBox(height: 8),
          WNote("Deleting your account doesn't cancel an App Store or Play subscription. Cancel it in your store account.", icon: PhosphorIconsRegular.info),
        ],
        if (step == 1) ...[
          Text('Type DELETE to confirm', style: context.t.titleLarge),
          const SizedBox(height: 10),
          WField(label: 'Confirmation', controller: typed, hint: 'DELETE', onChanged: (_) => setState(() {})),
          Text('New uploads and scans have stopped. Cleanup runs until every file is verified gone.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
        ],
        if (step == 2) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Text("We're deleting your account", textAlign: TextAlign.center, style: context.t.titleLarge),
          const SizedBox(height: 6),
          Text(
              "This keeps retrying until every file and record is removed. We'll email ${me?.profile.email ?? 'you'} when cleanup is verified. Restored backups won't bring it back.",
              textAlign: TextAlign.center,
              style: TextStyle(color: c.textMuted, height: 1.45)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Annual summary
// ---------------------------------------------------------------------------
class AnnualScreen extends ConsumerWidget {
  const AnnualScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final year = DateTime.now().year;
    final s = ref.watch(annualProvider(year));
    return WScreen(title: 'Your $year', children: [
      AsyncBody<AnnualSummary>(
        value: s,
        onRetry: () => ref.invalidate(annualProvider(year)),
        data: (a) {
          Widget stat(String n, String l) => Expanded(
                child: WCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(n, style: context.t.headlineMedium),
                    Text(l, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
                  ]),
                ),
              );
          final refunds = a.raw['refunds_reported'];
          final refundLine = refunds is Map && refunds.isNotEmpty ? refunds.entries.map((e) => fmtMoney(e.value, currency: e.key.toString())).join(' + ') : null;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('A year of keeping the proof', style: context.t.headlineSmall),
            const SizedBox(height: 14),
            Row(children: [stat('${a.n('purchases_tracked')}', 'purchases tracked'), const SizedBox(width: 8), stat('${a.n('receipts_stored')}', 'documents kept')]),
            const SizedBox(height: 8),
            Row(children: [stat('${a.n('returns_completed_before_deadline')}', 'returns on time'), const SizedBox(width: 8), stat('${a.n('claims_started')}', 'claims started')]),
            const SizedBox(height: 8),
            Row(children: [stat('${a.n('registrations_completed')}', 'registrations done'), const SizedBox(width: 8), stat('${a.raw['outcomes'] is List ? (a.raw['outcomes'] as List).length : a.n('outcomes')}', 'outcomes')]),
            const WSectionHeader('Confirmed outcomes'),
            Text(refundLine == null ? 'No refunds recorded yet.' : 'Refunds reported · $refundLine', style: TextStyle(color: c.text)),
            const SizedBox(height: 6),
            Text("Counts only what you recorded. Purchase value isn't counted as money saved.", style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          ]);
        },
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Monthly digest (built from the Action Center)
// ---------------------------------------------------------------------------
class DigestScreen extends ConsumerWidget {
  const DigestScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final ac = ref.watch(actionCenterProvider);
    return WScreen(title: 'Monthly digest', children: [
      AsyncBody<ActionCenter>(
        value: ac,
        data: (a) {
          final month = a.actions.where((x) => (x.daysLeft ?? 999) <= 30).toList();
          final later = a.actions.where((x) => (x.daysLeft ?? 999) > 30 && (x.daysLeft ?? 999) <= 90).toList();
          Widget row(ActionItem x) => WListRow(
                leading: SizedBox(width: 50, child: Text(fmtDayShort(x.dueDate), style: TextStyle(fontSize: 12.5, color: c.textMuted))),
                title: x.title,
                subtitle: x.itemName,
                onTap: x.itemId == null ? null : () => context.push('/items/${x.itemId}'),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(DateFormatName.month(), style: context.t.headlineMedium),
            Text('${month.length} thing${month.length == 1 ? '' : 's'} this month, ${a.missing.length} gap${a.missing.length == 1 ? '' : 's'} to fill.', style: TextStyle(color: c.textMuted)),
            const WSectionHeader('This month'),
            if (month.isEmpty) Text('Nothing due.', style: TextStyle(color: c.textMuted)),
            ...month.map(row),
            if (later.isNotEmpty) ...[const WSectionHeader('Next 90 days'), ...later.map(row)],
            if (a.missing.isNotEmpty) ...[
              const WSectionHeader('Missing'),
              for (final m in a.missing)
                WListRow(icon: PhosphorIconsRegular.question, title: m.title, subtitle: m.itemName, onTap: m.itemId == null ? null : () => context.push('/items/${m.itemId}')),
            ],
            const SizedBox(height: 12),
            Text('Once a month, nothing else. Turn it on or off in Reminders.', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          ]);
        },
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Support
// ---------------------------------------------------------------------------
class SupportScreen extends ConsumerStatefulWidget {
  const SupportScreen({super.key});
  @override
  ConsumerState<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends ConsumerState<SupportScreen> {
  String topic = 'general';
  final message = TextEditingController();
  bool diag = true, busy = false;
  SupportTicket? sent;

  Future<String> _diagnostics() async {
    final p = await PackageInfo.fromPlatform();
    final d = DeviceInfoPlugin();
    String device = Platform.operatingSystem;
    if (Platform.isIOS) {
      final i = await d.iosInfo;
      device = '${i.utsname.machine} iOS ${i.systemVersion}';
    } else if (Platform.isAndroid) {
      final a = await d.androidInfo;
      device = '${a.model} Android ${a.version.release}';
    }
    return '\n\n— Diagnostics: app ${p.version} (${p.buildNumber}), $device';
  }

  Future<void> _send() async {
    if (message.text.trim().isEmpty) return showToast(context, 'Tell us what happened.');
    setState(() => busy = true);
    try {
      final body = message.text.trim() + (diag ? await _diagnostics() : '');
      final t = await ref.read(settingsRepositoryProvider).openTicket(subject: message.text.trim().split('\n').first.characters.take(80).toString(), category: topic, message: body);
      ref.invalidate(ticketsProvider);
      setState(() => sent = t);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    final tickets = ref.watch(ticketsProvider).value ?? const <SupportTicket>[];
    if (sent != null) {
      return WScreen(title: 'Help & support', bottom: WButton.secondary('Done', onPressed: () => context.pop()), children: [
        const SizedBox(height: 30),
        Center(child: Icon(PhosphorIconsFill.checkCircle, size: 56, color: c.accent)),
        const SizedBox(height: 12),
        Text('Message sent', textAlign: TextAlign.center, style: context.t.headlineSmall),
        const SizedBox(height: 6),
        Text("We'll reply to ${me?.profile.email ?? 'your email'}, usually within 2 business days.", textAlign: TextAlign.center, style: TextStyle(color: c.textMuted)),
      ]);
    }
    return WScreen(
      title: 'Help & support',
      bottom: WButton('Send to support', loading: busy, onPressed: _send),
      children: [
        Text('How can we help?', style: context.t.titleLarge),
        const SizedBox(height: 10),
        WChoiceChips<String>(
          options: const [('general', 'Question'), ('bug', 'Something broke'), ('reminders', 'Reminders'), ('billing', 'Billing'), ('claims', 'Claims'), ('privacy', 'Privacy'), ('data_export', 'Export')],
          value: topic,
          onChanged: (v) => setState(() => topic = v),
        ),
        const SizedBox(height: 12),
        WField(label: 'Message', controller: message, hint: 'What happened, and what did you expect?', maxLines: 5),
        WSwitchRow(title: 'Include diagnostics', subtitle: 'App version and device. Never receipts, serial numbers or documents.', value: diag, onChanged: (v) => setState(() => diag = v)),
        Wrap(spacing: 4, children: [
          WButton.ghost('Request deletion on the web', onPressed: () => launchUrl(Uri.parse(AppConfig.webDeletionUrl), mode: LaunchMode.externalApplication)),
          WButton.ghost('Email us', onPressed: () => launchUrl(Uri(scheme: 'mailto', path: AppConfig.supportEmail))),
        ]),
        if (tickets.isNotEmpty) ...[
          const WSectionHeader('Your messages'),
          for (final t in tickets) WListRow(icon: PhosphorIconsRegular.chatText, title: t.subject, subtitle: '${titleCase(t.status)} · ${fmtDate(t.createdAt)}', caret: false),
        ],
      ],
    );
  }
}
