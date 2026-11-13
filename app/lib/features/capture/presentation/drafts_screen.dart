import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../domain/capture.dart';
import 'capture_providers.dart';

/// Drafts from the share sheet, uploads and email forwards, waiting for review.
class DraftsScreen extends ConsumerWidget {
  const DraftsScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final drafts = ref.watch(captureDraftsProvider);
    return WScreen(title: 'Drafts to review', children: [
      Text('Nothing here is saved to your items until you review it.', style: TextStyle(color: c.textMuted)),
      const SizedBox(height: 12),
      AsyncBody<List<CaptureDraftSummary>>(
        value: drafts,
        onRetry: () => ref.invalidate(captureDraftsProvider),
        data: (list) {
          final open = list.where((d) => d.state != 'discarded' && d.state != 'converted').toList();
          if (open.isEmpty) return const WEmpty(icon: PhosphorIconsRegular.tray, title: 'No drafts', message: 'Files you share to Warrantra or forward by email appear here.');
          return Column(children: [
            for (final d in open)
              WListRow(
                icon: d.source == 'email_forward' ? PhosphorIconsRegular.envelopeSimple : PhosphorIconsRegular.shareNetwork,
                title: d.title ?? 'Shared document',
                subtitle: '${titleCase(d.state)} · ${fmtDate(d.createdAt)}',
                onTap: () {
                  final att = d.attachmentIds.isEmpty ? '' : '?attachment=${d.attachmentIds.first}';
                  if (d.scanJobId != null && d.state == 'ready_for_review') {
                    context.push('/capture/review/${d.scanJobId}$att');
                  } else {
                    context.push('/capture/manual$att');
                  }
                },
                trailing: IconButton(
                  icon: const Icon(PhosphorIconsRegular.x, size: 18),
                  onPressed: () async {
                    await ref.read(captureRepositoryProvider).discardDraft(d.id);
                    ref.invalidate(captureDraftsProvider);
                  },
                ),
              ),
          ]);
        },
      ),
    ]);
  }
}
