import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../../capture/presentation/capture_providers.dart';
import '../../capture/presentation/upload_flow.dart';
import '../../items/domain/items.dart';
import '../../items/presentation/item_ui.dart';
import '../../items/presentation/items_providers.dart';
import '../domain/vault.dart';
import 'vault_providers.dart';

const _types = <(String?, String)>[(null, 'All'), ('receipt', 'Receipts'), ('warranty_card', 'Warranties'), ('manual', 'Manuals'), ('product_photo', 'Photos'), ('claim_evidence', 'Claim evidence'), ('other', 'Other')];
String typeLabel(String t) => switch (t) {
      'receipt' => 'Receipt',
      'warranty_card' => 'Warranty',
      'manual' => 'Manual',
      'product_photo' => 'Photo',
      'registration' => 'Registration',
      'claim_evidence' => 'Claim evidence',
      'service_record' => 'Service record',
      _ => 'Document',
    };

class VaultScreen extends ConsumerWidget {
  const VaultScreen({super.key});

  Future<void> _upload(BuildContext context, WidgetRef ref) async {
    final src = await showWSheet<PickSource>(context, builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Upload to vault', style: ctx.t.titleLarge),
          const SizedBox(height: 8),
          WListRow(icon: PhosphorIconsRegular.camera, title: 'Take a photo', onTap: () => Navigator.pop(ctx, PickSource.camera)),
          WListRow(icon: PhosphorIconsRegular.image, title: 'Choose from photos', onTap: () => Navigator.pop(ctx, PickSource.gallery)),
          WListRow(icon: PhosphorIconsRegular.filePdf, title: 'Choose a file', onTap: () => Navigator.pop(ctx, PickSource.files)),
        ]));
    if (src == null || !context.mounted) return;
    PickedFile? f;
    try {
      f = await pickFile(src);
    } catch (e) {
      if (context.mounted) showUploadIssue(context, e);
      return;
    }
    if (f == null || !context.mounted) return;
    final up = await uploadWithProgress(context, ref, f, fileType: f.mime == 'application/pdf' ? 'other' : 'receipt');
    if (up == null) return;
    ref.invalidate(vaultProvider);
    ref.invalidate(meProvider);
    if (context.mounted) {
      showToast(context, up.duplicateOf != null ? 'Saved. You already had this exact file.' : 'Saved to your vault');
      context.push('/vault/${up.attachmentId}');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final docs = ref.watch(vaultProvider);
    final filter = ref.watch(vaultFilterProvider);
    final me = ref.watch(meProvider).value;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(vaultProvider);
            await ref.read(vaultProvider.future);
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 110), children: [
            Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Vault', style: context.t.headlineMedium),
                  Text('${docs.value?.length ?? '…'} documents · private to your account', style: TextStyle(fontSize: 13, color: c.textMuted)),
                ]),
              ),
              WButton.secondary('Upload', icon: PhosphorIconsRegular.uploadSimple, expand: false, compact: true, onPressed: () => _upload(context, ref)),
            ]),
            if (me != null) ...[
              const SizedBox(height: 12),
              WCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('Storage', style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('${fmtBytes(me.usage.storageUsed)} of ${fmtBytes(me.usage.storageLimit)}',
                          textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.textMuted)),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  WProgressBar(me.usage.storageLimit == 0 ? 0 : (me.usage.storageUsed / me.usage.storageLimit).clamp(0, 1).toDouble()),
                  const SizedBox(height: 6),
                  Text('A receipt linked to several items counts once.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
                ]),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              height: 36,
              child: ListView(scrollDirection: Axis.horizontal, children: [
                for (final (v, l) in _types)
                  Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(l), selected: filter == v, onSelected: (_) => ref.read(vaultFilterProvider.notifier).set(v))),
              ]),
            ),
            const SizedBox(height: 8),
            AsyncBody<List<VaultDoc>>(
              value: docs,
              onRetry: () => ref.invalidate(vaultProvider),
              data: (list) => list.isEmpty
                  ? const WEmpty(
                      icon: PhosphorIconsRegular.vault,
                      title: 'Your purchase documents will live here',
                      message: 'Receipts and warranty documents you attach to purchases appear here automatically.',
                    )
                  : Column(children: [
                      for (final d in list)
                        WListRow(
                          icon: docIcon(d.fileType, d.mime),
                          title: d.filename ?? typeLabel(d.fileType),
                          subtitle: [
                            typeLabel(d.fileType),
                            if (d.size != null) fmtBytes(d.size),
                            if (d.pages != null && d.isPdf) '${d.pages} pp',
                            if (d.held) 'Held for review' else if (d.itemIds.isEmpty && d.claimIds.isEmpty) 'Not linked' else 'Linked to ${d.itemIds.length + d.claimIds.length}',
                          ].join(' · '),
                          onTap: () => context.push('/vault/${d.id}'),
                        ),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class DocViewerScreen extends ConsumerWidget {
  const DocViewerScreen({super.key, required this.id});
  final String id;

  Future<File> _download(WidgetRef ref, VaultDoc d) async {
    final url = await ref.read(vaultRepositoryProvider).url(d.id, download: true);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${d.filename ?? 'document'}');
    await Dio().download(url, file.path);
    return file;
  }

  Future<void> _share(BuildContext context, WidgetRef ref, VaultDoc d) async {
    try {
      final f = await _download(ref, d);
      await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: d.mime)]));
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, VaultDoc d) async {
    final repo = ref.read(vaultRepositoryProvider);
    DocImpact? impact;
    try {
      impact = await repo.impact(d.id);
    } catch (_) {}
    if (!context.mounted) return;
    final lines = <String>[
      if (impact != null) ...[
        for (final (_, n) in impact.items) '• Removed from $n',
        if (impact.purchases > 0) '• Removed from ${impact.purchases} purchase record${impact.purchases == 1 ? '' : 's'}',
        for (final (_, n) in impact.claims) '• Removed from the claim for $n',
        if (impact.warrantySources > 0) '• Coverage that cites it keeps its dates but loses the source',
      ],
    ];
    final ok = await confirmDialog(context,
        title: 'Delete this document?',
        message: '${lines.isEmpty ? 'It is not linked to anything.' : lines.join('\n')}\n\nThe file is permanently deleted and cannot be recovered.',
        confirm: 'Delete document',
        destructive: true,
        icon: PhosphorIconsRegular.trash);
    if (!ok) return;
    try {
      await repo.delete(d.id, confirm: true);
      ref.invalidate(vaultProvider);
      ref.invalidate(meProvider);
      ref.refreshItems();
      if (context.mounted) {
        context.pop();
        showToast(context, 'Document deleted');
      }
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  Future<void> _linkItem(BuildContext context, WidgetRef ref, VaultDoc d) async {
    final items = await ref.read(itemsRepositoryProvider).list(const ItemQuery(sort: 'name'));
    if (!context.mounted) return;
    final picked = await showWSheet<ItemSummary>(context, builder: (ctx) => ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Link to an item', style: ctx.t.titleLarge),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final it in items) WListRow(icon: itemIcon(category: it.categorySlug, name: it.name), title: it.name, subtitle: it.retailer, onTap: () => Navigator.pop(ctx, it)),
              ]),
            ),
          ]),
        ));
    if (picked == null) return;
    try {
      final role = switch (d.fileType) { 'receipt' || 'warranty_card' || 'manual' || 'product_photo' || 'registration' => d.fileType, _ => 'document' };
      await ref.read(captureRepositoryProvider).linkToItem(d.id, picked.id, role: role);
      ref.invalidate(docImpactProvider(d.id));
      ref.invalidate(vaultProvider);
      ref.refreshItems(itemId: picked.id);
      if (context.mounted) showToast(context, 'Linked to ${picked.name}');
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final doc = ref.watch(vaultDocProvider(id));
    return doc.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Document', children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox(), onRetry: () => ref.invalidate(vaultDocProvider(id)))]),
      data: (d) {
        final impact = ref.watch(docImpactProvider(id)).value;
        return WScreen(
          actions: [if (!d.held) WIconButton(PhosphorIconsRegular.shareNetwork, tooltip: 'Share', onPressed: () => _share(context, ref, d))],
          bottom: Row(children: [
            if (!d.held) ...[
              Expanded(child: WButton.secondary('Original', icon: PhosphorIconsRegular.downloadSimple, onPressed: () => _share(context, ref, d))),
              const SizedBox(width: 10),
            ],
            Expanded(child: WButton.secondary('Delete', icon: PhosphorIconsRegular.trash, onPressed: () => _delete(context, ref, d))),
          ]),
          children: [
            Text(typeLabel(d.fileType).toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: 1, color: c.textSubtle)),
            Text(d.filename ?? typeLabel(d.fileType), style: context.t.titleLarge),
            Text([if (d.size != null) fmtBytes(d.size), if (d.pages != null) '${d.pages} page${d.pages == 1 ? '' : 's'}', 'added ${fmtDate(d.createdAt)}'].join(' · '),
                style: TextStyle(fontSize: 13, color: c.textMuted)),
            const SizedBox(height: 8),
            Wrap(spacing: 6, children: [
              if (!d.held) const WTag('Type verified', icon: PhosphorIconsRegular.shieldCheck),
              const WTag('Private', icon: PhosphorIconsRegular.lockSimple),
              if (d.held) const WTag('Held for review', kind: WTagKind.danger),
            ]),
            const SizedBox(height: 14),
            if (d.held)
              const WNote("This file contains content we don't allow, so it is not shown or stored. You can delete the record.", icon: PhosphorIconsRegular.shieldWarning)
            else
              _Preview(doc: d),
            const WSectionHeader('Linked to'),
            if (impact == null)
              const LinearProgressIndicator()
            else ...[
              if (!impact.linked) Text('Not linked to any item yet.', style: TextStyle(color: c.textMuted)),
              for (final (iid, n) in impact.items) WListRow(icon: PhosphorIconsRegular.package, title: n, onTap: () => context.push('/items/$iid')),
              for (final (cid, n) in impact.claims) WListRow(icon: PhosphorIconsRegular.chatCircleText, title: 'Claim · $n', onTap: () => context.push('/claims/$cid')),
            ],
            if (!d.held) Align(alignment: Alignment.centerLeft, child: WButton.ghost('Link to another item', icon: PhosphorIconsRegular.linkSimple, onPressed: () => _linkItem(context, ref, d))),
          ],
        );
      },
    );
  }
}

class _Preview extends ConsumerWidget {
  const _Preview({required this.doc});
  final VaultDoc doc;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final heic = doc.mime == 'image/heic' || doc.mime == 'image/heif';
    if (!doc.isImage || heic) {
      return WCard(
        onTap: () async {
          final url = await ref.read(vaultRepositoryProvider).url(doc.id);
          await launchUrl(Uri.parse(url), mode: LaunchMode.inAppBrowserView);
        },
        child: SizedBox(
          height: 160,
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(doc.isPdf ? PhosphorIconsRegular.filePdf : PhosphorIconsRegular.image, size: 44, color: c.accent),
              const SizedBox(height: 8),
              Text(doc.isPdf ? 'Open PDF' : 'Open image', style: TextStyle(color: c.accent, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      );
    }
    final url = ref.watch(docPreviewUrlProvider(doc.id));
    return ClipRRect(
      borderRadius: BorderRadius.circular(WRadius.md),
      child: Container(
        color: c.surface,
        constraints: const BoxConstraints(minHeight: 200, maxHeight: 520),
        child: url.when(
          loading: () => const SizedBox(height: 240, child: Center(child: CircularProgressIndicator())),
          error: (_, _) => const SizedBox(height: 120, child: Center(child: Text('Preview unavailable'))),
          data: (u) => InteractiveViewer(child: Image.network(u, fit: BoxFit.contain, errorBuilder: (_, _, _) => const SizedBox(height: 120, child: Center(child: Text('Preview unavailable'))))),
        ),
      ),
    );
  }
}
