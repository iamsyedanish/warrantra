import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../domain/capture.dart';
import 'add_sheet.dart';
import 'capture_providers.dart';

CaptureMode _mode(String? m) => CaptureMode.values.firstWhere((e) => e.name == m, orElse: () => CaptureMode.scanReceipt);

/// Centered "statement" layout used by consent, limit and failure screens.
class _Statement extends StatelessWidget {
  const _Statement({required this.icon, required this.title, required this.body, this.points = const [], required this.actions, this.link});
  final IconData icon;
  final String title, body;
  final List<(IconData, String, String)> points;
  final List<Widget> actions;
  final Widget? link;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return WScreen(
      close: true,
      bottom: Column(mainAxisSize: MainAxisSize.min, children: [for (final a in actions) Padding(padding: const EdgeInsets.only(bottom: 8), child: a)]),
      children: [
        const SizedBox(height: 12),
        Center(child: IconTile(icon, size: 64, emphasis: true)),
        const SizedBox(height: 18),
        Text(title, textAlign: TextAlign.center, style: context.t.headlineSmall),
        const SizedBox(height: 10),
        Text(body, textAlign: TextAlign.center, style: TextStyle(color: c.textMuted, height: 1.5)),
        const SizedBox(height: 18),
        for (final (i, t, b) in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(i, color: c.accent, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t, style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                  Text(b, style: TextStyle(fontSize: 13.5, height: 1.45, color: c.textMuted)),
                ]),
              ),
            ]),
          ),
        ?link,
      ],
    );
  }
}

class AiConsentScreen extends ConsumerStatefulWidget {
  const AiConsentScreen({super.key, this.mode});
  final String? mode;
  @override
  ConsumerState<AiConsentScreen> createState() => _AiConsentScreenState();
}

class _AiConsentScreenState extends ConsumerState<AiConsentScreen> {
  bool busy = false;

  Future<void> _allow() async {
    setState(() => busy = true);
    try {
      await ref.read(accountRepositoryProvider).setAiConsent(true);
      ref.invalidate(meProvider);
      if (!mounted) return;
      final container = ProviderScope.containerOf(context, listen: false);
      context.pop();
      final root = rootNavigatorKey.currentContext;
      if (root != null && root.mounted) await pickUploadAndScan(root, container, _mode(widget.mode), aiAllowed: true);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).value;
    return _Statement(
      icon: PhosphorIconsRegular.sparkle,
      title: 'Read receipts with AI?',
      body: 'To fill in merchant, date, lines and totals, the image is sent through our servers to a third-party AI provider.',
      points: [
        (PhosphorIconsRegular.paperPlaneTilt, "What's sent", 'The image or PDF pages you choose. Not your name, email or other items.'),
        (PhosphorIconsRegular.eye, 'You review everything', "Nothing is saved until you confirm. Fields it can't find stay empty."),
        (PhosphorIconsRegular.coins, 'Allowance', "${me?.aiLine ?? 'Your plan includes AI reads'}. Failed reads and retries don't count."),
      ],
      link: Center(
        child: TextButton(
          onPressed: () => launchUrl(Uri.parse(AppConfig.privacyUrl), mode: LaunchMode.externalApplication),
          child: const Text('Provider and retention details'),
        ),
      ),
      actions: [
        WButton('Allow AI reading', loading: busy, onPressed: _allow),
        WButton.secondary('Enter manually instead', onPressed: () => context.pushReplacement('/capture/manual')),
      ],
    );
  }
}

class AiLimitScreen extends ConsumerWidget {
  const AiLimitScreen({super.key, this.attachmentId, this.reason});
  final String? attachmentId, reason;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value;
    final manual = '/capture/manual${attachmentId == null ? '' : '?attachment=$attachmentId'}';
    final paused = reason == 'ai_disabled' || reason == 'ai_global_budget_exhausted';
    final suspended = reason == 'ai_suspended' || (me?.profile.aiSuspended ?? false);
    final (title, body, icon) = switch (reason) {
      _ when paused => (
          'AI reading is paused',
          "We've paused AI receipt reading while we look into a problem. Manual entry and all your records work as normal. No allowance is used.",
          PhosphorIconsRegular.pauseCircle
        ),
      _ when suspended => (
          'AI reading is paused on this account',
          'Repeated uploads that were not receipts or product labels paused AI on this account. Manual entry still works. Contact support if this is a mistake.',
          PhosphorIconsRegular.pauseCircle
        ),
      'ai_email_verification_required' => ('Confirm your email first', 'Confirm your email address to use AI reading. Manual entry works right away.', PhosphorIconsRegular.envelopeSimple),
      'ai_rate_limited' || 'ai_free_tier_busy' => ('Too many reads right now', 'Please wait a little and try again. Manual entry always works.', PhosphorIconsRegular.hourglass),
      _ => ('No AI reads left', "${me?.aiLine ?? 'Your AI allowance is used up'}. Manual entry still works, and nothing you've saved is affected.", PhosphorIconsRegular.sparkle),
    };
    return _Statement(icon: icon, title: title, body: body, actions: [
      WButton('Enter manually', onPressed: () => context.pushReplacement(manual)),
      if (suspended) WButton.secondary('Contact support', onPressed: () => context.pushReplacement('/settings/support')),
      if (!paused && !suspended && !(me?.plan.isPro ?? true)) WButton.ghost('Pro includes 20 a month', onPressed: () => context.pushReplacement('/settings/paywall')),
    ]);
  }
}

class UploadIssueScreen extends StatelessWidget {
  const UploadIssueScreen({super.key, required this.failure});
  final Failure failure;
  @override
  Widget build(BuildContext context) {
    final reason = failure.details?['reason']?.toString() ?? failure.code;
    final storage = failure.isQuota && failure.details?['resource'] == 'storage_bytes';
    final (icon, title) = switch (reason) {
      _ when storage => (PhosphorIconsRegular.hardDrives, 'Your storage is full'),
      'file_too_large' || 'too_large' => (PhosphorIconsRegular.fileX, 'This file is too large'),
      'unsupported_type' || 'mime_mismatch' => (PhosphorIconsRegular.fileDashed, "This file type isn't supported"),
      'pdf_active_content' || 'quarantined' => (PhosphorIconsRegular.shieldWarning, "We couldn't safely open this file"),
      'offline' => (PhosphorIconsRegular.wifiSlash, "You're offline"),
      _ => (PhosphorIconsRegular.warningCircle, "This file couldn't be added"),
    };
    final body = storage
        ? "New uploads are paused. Everything you've stored stays available and exportable. You can still save the purchase without the file."
        : '${failure.message} We check the file contents, not just its name.';
    return _Statement(icon: icon, title: title, body: body, actions: [
      if (storage) WButton('Get more storage with Pro', onPressed: () => context.pushReplacement('/settings/paywall')),
      WButton(storage ? 'Save without the file' : 'Choose another file', kind: storage ? WButtonKind.secondary : WButtonKind.primary,
          onPressed: () => storage ? context.pushReplacement('/capture/manual') : context.pop()),
      if (storage) WButton.ghost('Manage documents', onPressed: () => context.go('/vault')),
      if (reason == 'pdf_active_content') WButton.ghost('Contact support', onPressed: () => context.pushReplacement('/settings/support')),
    ]);
  }
}

/// Polls a scan until it settles, showing the prototype's step list.
class ProcessingScreen extends ConsumerStatefulWidget {
  const ProcessingScreen({super.key, required this.scanId, this.attachmentId});
  final String scanId;
  final String? attachmentId;
  @override
  ConsumerState<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends ConsumerState<ProcessingScreen> {
  Timer? _timer;
  int _tick = 0;
  ScanJob? _job;
  bool _stopped = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_stopped) return;
    _tick++;
    try {
      final job = await ref.read(captureRepositoryProvider).scan(widget.scanId);
      if (!mounted) return;
      setState(() => _job = job);
      if (job.done) {
        _timer?.cancel();
        ref.invalidate(meProvider);
        final att = widget.attachmentId ?? job.attachmentId;
        if (job.state == 'succeeded') {
          final path = job.feature == 'product_label_extraction' ? '/capture/product/${job.id}' : '/capture/review/${job.id}';
          context.pushReplacement('$path${att == null ? '' : '?attachment=$att'}');
        } else {
          context.pushReplacement('/capture/failed?code=${job.errorCode ?? job.state}${att == null ? '' : '&attachment=$att'}');
        }
      } else if (_tick > 60) {
        _timer?.cancel();
        context.pushReplacement('/capture/failed?code=timeout${att(job)}');
      }
    } catch (_) {
      // transient: keep polling
    }
  }

  String att(ScanJob j) => (widget.attachmentId ?? j.attachmentId) == null ? '' : '&attachment=${widget.attachmentId ?? j.attachmentId}';

  Future<void> _stop() async {
    _stopped = true;
    _timer?.cancel();
    try {
      await ref.read(captureRepositoryProvider).discardScan(widget.scanId);
    } catch (_) {}
    if (mounted) context.pushReplacement('/capture/manual${widget.attachmentId == null ? '' : '?attachment=${widget.attachmentId}'}');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final state = _job?.state ?? 'queued';
    final steps = ['Uploaded securely', 'Reading the document', 'Checking every value against the text', 'Preparing your review'];
    final active = switch (state) { 'queued' => 1, 'processing' => _tick < 4 ? 1 : 2, _ => 3 };
    final label = _job?.feature == 'product_label_extraction';
    return WScreen(
      showBack: false,
      bottom: WButton.ghost('Stop and enter manually', onPressed: _stop),
      children: [
        const SizedBox(height: 40),
        Center(child: WTag('1 action reserved', kind: WTagKind.accent, icon: PhosphorIconsRegular.sparkle)),
        const SizedBox(height: 14),
        Text(label ? 'Reading the label' : 'Reading your receipt', textAlign: TextAlign.center, style: context.t.headlineSmall),
        const SizedBox(height: 8),
        Text('If this fails, the action is released and nothing is used.', textAlign: TextAlign.center, style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 28),
        WCard(
          child: Column(children: [
            for (final (i, s) in steps.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  if (i < active)
                    Icon(PhosphorIconsFill.checkCircle, color: c.accent, size: 22)
                  else if (i == active)
                    SizedBox(width: 22, height: 22, child: Padding(padding: const EdgeInsets.all(2), child: CircularProgressIndicator(strokeWidth: 2.2, color: c.accent)))
                  else
                    Icon(PhosphorIconsRegular.circle, color: c.textSubtle, size: 22),
                  const SizedBox(width: 12),
                  Text(s, style: TextStyle(color: i <= active ? c.text : c.textSubtle)),
                ]),
              ),
          ]),
        ),
      ],
    );
  }
}

class ScanFailedScreen extends ConsumerWidget {
  const ScanFailedScreen({super.key, this.code, this.attachmentId});
  final String? code, attachmentId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider).value;
    final rejected = code == 'not_a_receipt' || code == 'not_a_product_label';
    final (title, body) = switch (code) {
      'not_a_receipt' => ("This doesn't look like a receipt", 'Upload a receipt, invoice or order confirmation, or enter the purchase by hand. Uploads that are not receipts still use an AI read.'),
      'not_a_product_label' => ("This doesn't look like a product label", 'Photograph the rating plate or box label with the model number, or enter the item by hand.'),
      'heic_not_supported_for_ai' => ("AI can't read HEIC photos", 'The photo is saved. Enter the details by hand, or retake it as JPEG.'),
      'image_too_large_for_ai' => ('This image is too large to read', 'Try a closer, smaller photo. Your action was released.'),
      'timeout' => ('This is taking longer than usual', 'You can enter the details now. If the read finishes, it will not be saved without your review.'),
      _ => ("We couldn't read this receipt", 'Your action was released${me == null ? '' : ': ${me.aiLine}'}.'),
    };
    final keep = attachmentId == null ? '' : '?attachment=$attachmentId';
    return _Statement(icon: rejected ? PhosphorIconsRegular.fileX : PhosphorIconsRegular.warningCircle, title: title, body: body, actions: [
      WButton(attachmentId == null ? 'Enter manually' : 'Enter manually · keep the photo', onPressed: () => context.pushReplacement('/capture/manual$keep')),
      WButton.secondary('Try another photo', onPressed: () async {
        final container = ProviderScope.containerOf(context, listen: false);
        context.pop();
        final root = rootNavigatorKey.currentContext;
        if (root != null && root.mounted) await startCapture(root, container, code == 'not_a_product_label' ? CaptureMode.productLabel : CaptureMode.scanReceipt);
      }),
    ]);
  }
}
