import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/errors/failure.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/domain/account.dart';
import '../../account/presentation/account_providers.dart';
import '../domain/capture.dart';
import 'capture_providers.dart';
import 'upload_flow.dart';

enum CaptureMode { scanReceipt, upload, manual, productLabel }

Future<void> showAddSheet(BuildContext context) async {
  final mode = await showWSheet<CaptureMode>(context, builder: (ctx) => const _AddSheet());
  if (mode == null || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  await startCapture(context, container, mode);
}

class _AddSheet extends ConsumerWidget {
  const _AddSheet();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final me = ref.watch(meProvider).value;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Add a purchase', style: context.t.titleLarge),
      const SizedBox(height: 4),
      Text(
        me == null ? 'Receipts, invoices and order confirmations all work.' : me.aiLine,
        style: TextStyle(fontSize: 13, color: c.textMuted),
      ),
      const SizedBox(height: 12),
      _Option(icon: PhosphorIconsRegular.scan, title: 'Scan receipt', subtitle: 'AI reads the store, date, items and price for you to review', onTap: () => Navigator.pop(context, CaptureMode.scanReceipt)),
      _Option(icon: PhosphorIconsRegular.uploadSimple, title: 'Upload image or PDF', subtitle: 'From Photos or Files, including e-receipts', onTap: () => Navigator.pop(context, CaptureMode.upload)),
      _Option(icon: PhosphorIconsRegular.pencilSimpleLine, title: 'Enter manually', subtitle: 'No receipt needed; always free', onTap: () => Navigator.pop(context, CaptureMode.manual)),
      _Option(
        icon: PhosphorIconsRegular.barcode,
        title: 'Scan product label',
        subtitle: 'Read brand, model and serial from the label',
        tag: 'Beta',
        onTap: () => Navigator.pop(context, CaptureMode.productLabel),
      ),
    ]);
  }
}

class _Option extends StatelessWidget {
  const _Option({required this.icon, required this.title, required this.subtitle, required this.onTap, this.tag});
  final IconData icon;
  final String title, subtitle;
  final String? tag;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(WRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          IconTile(icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text)),
                if (tag != null) ...[const SizedBox(width: 8), WTag(tag!, kind: WTagKind.outline)],
              ]),
              Text(subtitle, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Sheet shown when Free item additions are paused.
Future<void> showLimitSheet(BuildContext context, Me me) => showWSheet<void>(context, builder: (ctx) {
      final c = ctx.w;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(PhosphorIconsRegular.lockSimple, size: 32, color: c.accent),
        const SizedBox(height: 10),
        Text("You've reached ${me.usage.itemsLimit} items on Free", style: ctx.t.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: 6),
        Text('Everything you saved stays viewable, exportable and reminded. Pro adds unlimited items, more AI reads and assembled claim packs.',
            textAlign: TextAlign.center, style: TextStyle(color: c.textMuted, height: 1.45)),
        const SizedBox(height: 16),
        WButton('See Pro', onPressed: () {
          Navigator.pop(ctx);
          context.push('/settings/paywall');
        }),
        const SizedBox(height: 8),
        WButton.secondary('Not now', onPressed: () => Navigator.pop(ctx)),
      ]);
    });

/// Runs a capture flow from anywhere (Home, Items, deep links).
Future<void> startCapture(BuildContext context, ProviderContainer container, CaptureMode mode) async {
  Me? me;
  try {
    me = await container.read(meProvider.future);
  } catch (_) {}
  if (!context.mounted) return;
  if (me != null && me.usage.additionsPaused) {
    await showLimitSheet(context, me);
    return;
  }
  if (mode == CaptureMode.manual) {
    context.push('/capture/manual');
    return;
  }
  final usesAi = mode != CaptureMode.upload || (me?.profile.aiConsent ?? false);
  if (usesAi && me != null) {
    if (!me.profile.aiConsent) {
      context.push('/capture/ai-consent?mode=${mode.name}');
      return;
    }
    if (me.profile.aiSuspended || me.usage.aiLeft <= 0) {
      context.push('/capture/ai-limit?mode=${mode.name}');
      return;
    }
  }
  await pickUploadAndScan(context, container, mode, aiAllowed: usesAi);
}

/// Pick → upload → (scan | manual with the document attached).
Future<void> pickUploadAndScan(BuildContext context, ProviderContainer container, CaptureMode mode, {required bool aiAllowed}) async {
  final label = mode == CaptureMode.productLabel;
  PickSource? source = switch (mode) { CaptureMode.scanReceipt || CaptureMode.productLabel => PickSource.camera, _ => null };
  source ??= await showWSheet<PickSource>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Upload', style: ctx.t.titleLarge),
        const SizedBox(height: 8),
        WListRow(icon: PhosphorIconsRegular.image, title: 'Choose from photos', onTap: () => Navigator.pop(ctx, PickSource.gallery)),
        WListRow(icon: PhosphorIconsRegular.filePdf, title: 'Choose a file (PDF or image)', onTap: () => Navigator.pop(ctx, PickSource.files)),
      ]));
  if (source == null || !context.mounted) return;
  PickedFile? f;
  try {
    f = await pickFile(source);
  } catch (e) {
    if (context.mounted) showUploadIssue(context, e);
    return;
  }
  if (f == null || !context.mounted) return;
  final up = await _upload(context, container, f, label ? 'product_photo' : 'receipt');
  if (up == null || !context.mounted) return;
  final heic = f.mime == 'image/heic' || f.mime == 'image/heif';
  if (!aiAllowed || heic) {
    if (heic && aiAllowed) showToast(context, 'HEIC photos are stored but not read by AI. Enter the details below.');
    context.push('/capture/manual?attachment=${up.attachmentId}');
    return;
  }
  try {
    final job = await container.read(captureRepositoryProvider).startScan(
          attachmentId: up.attachmentId,
          feature: label ? 'product_label_extraction' : 'receipt_extraction',
          idempotencyKey: ApiClient.newIdempotencyKey(),
        );
    if (context.mounted) context.push('/capture/scan/${job.id}?attachment=${up.attachmentId}');
  } on Failure catch (e) {
    if (!context.mounted) return;
    if (e.isQuota || e.code.startsWith('ai_')) {
      context.push('/capture/ai-limit?mode=${mode.name}&attachment=${up.attachmentId}&reason=${e.code}');
    } else {
      showFailure(context, e);
      context.push('/capture/manual?attachment=${up.attachmentId}');
    }
  }
}

Future<UploadedFile?> _upload(BuildContext context, ProviderContainer container, PickedFile f, String type) async {
  final key = ApiClient.newIdempotencyKey();
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const PopScope(
      canPop: false,
      child: AlertDialog(content: Row(children: [SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4)), SizedBox(width: 16), Text('Uploading securely…')])),
    ),
  );
  try {
    final up = await container.read(captureRepositoryProvider).upload(bytes: f.bytes, filename: f.name, mime: f.mime, fileType: type, idempotencyKey: key);
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    return up;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
      showUploadIssue(context, e);
    }
    return null;
  }
}
