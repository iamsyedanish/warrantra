import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failure.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/tokens.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../items/presentation/items_providers.dart';
import '../domain/capture.dart';
import 'capture_providers.dart';

enum PickSource { camera, gallery, files }

class PickedFile {
  const PickedFile(this.bytes, this.name, this.mime);
  final Uint8List bytes;
  final String name, mime;
}

String? mimeFor(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.jpg') || n.endsWith('.jpeg')) return 'image/jpeg';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.heic')) return 'image/heic';
  if (n.endsWith('.heif')) return 'image/heif';
  if (n.endsWith('.pdf')) return 'application/pdf';
  return null;
}

/// Picks a photo or file. Throws a [Failure] with a friendly message for
/// unsupported or oversized files, so the caller can show the upload-issue screen.
Future<PickedFile?> pickFile(PickSource source) async {
  if (source == PickSource.files) {
    final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['jpg', 'jpeg', 'png', 'heic', 'heif', 'pdf']);
    if (r.isEmpty) return null;
    final f = r.first;
    final bytes = await f.xFile.readAsBytes();
    return _validate(PickedFile(bytes, f.name, mimeFor(f.name) ?? ''));
  }
  final picker = ImagePicker();
  XFile? x;
  try {
    x = await picker.pickImage(source: source == PickSource.camera ? ImageSource.camera : ImageSource.gallery, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
  } catch (_) {
    // No camera (e.g. simulator): fall back to the photo library.
    if (source == PickSource.camera) x = await picker.pickImage(source: ImageSource.gallery, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
  }
  if (x == null) return null;
  final bytes = await x.readAsBytes();
  final name = x.name.isEmpty ? 'photo.jpg' : x.name;
  return _validate(PickedFile(bytes, name, mimeFor(name) ?? x.mimeType ?? 'image/jpeg'));
}

PickedFile _validate(PickedFile f) {
  if (!AppConfig.allowedMime.contains(f.mime)) {
    throw const Failure('unsupported_type', 'Warrantra stores JPEG, PNG, HEIC and PDF files.');
  }
  if (f.bytes.length > AppConfig.maxFileBytes) {
    throw const Failure('file_too_large', 'This file is larger than 10 MB. Try a smaller photo or a PDF export.');
  }
  return f;
}

/// Uploads with a blocking progress dialog; returns null if it failed (and shows why).
Future<UploadedFile?> uploadWithProgress(BuildContext context, WidgetRef ref, PickedFile f, {required String fileType}) async {
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
    final up = await ref.read(captureRepositoryProvider).upload(bytes: f.bytes, filename: f.name, mime: f.mime, fileType: fileType, idempotencyKey: key);
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

void showUploadIssue(BuildContext context, Object e) {
  final f = e is Failure ? e : Failure.unknown;
  context.push('/capture/upload-issue', extra: f);
}

/// "Add document" from an item: choose source and type, upload, link.
Future<void> addDocumentToItem(BuildContext context, WidgetRef ref, String itemId) async {
  final choice = await showWSheet<(PickSource, String)>(context, builder: (ctx) => const _DocSourceSheet());
  if (choice == null || !context.mounted) return;
  PickedFile? f;
  try {
    f = await pickFile(choice.$1);
  } catch (e) {
    if (context.mounted) showUploadIssue(context, e);
    return;
  }
  if (f == null || !context.mounted) return;
  final up = await uploadWithProgress(context, ref, f, fileType: choice.$2);
  if (up == null) return;
  try {
    final role = switch (choice.$2) { 'receipt' => 'receipt', 'warranty_card' => 'warranty_card', 'manual' => 'manual', 'product_photo' => 'product_photo', 'registration' => 'registration', _ => 'document' };
    await ref.read(captureRepositoryProvider).linkToItem(up.attachmentId, itemId, role: role);
    ref.refreshItems(itemId: itemId);
    if (context.mounted) showToast(context, up.duplicateOf != null ? 'Added. You already had this exact file in your vault.' : 'Document added');
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}

class _DocSourceSheet extends StatefulWidget {
  const _DocSourceSheet();
  @override
  State<_DocSourceSheet> createState() => _DocSourceSheetState();
}

class _DocSourceSheetState extends State<_DocSourceSheet> {
  String type = 'receipt';
  static const types = [('receipt', 'Receipt'), ('warranty_card', 'Warranty'), ('manual', 'Manual'), ('product_photo', 'Photo'), ('registration', 'Registration'), ('other', 'Other')];

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Add a document', style: context.t.titleLarge),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (v, l) in types) ChoiceChip(label: Text(l), selected: type == v, onSelected: (_) => setState(() => type = v)),
      ]),
      const SizedBox(height: 12),
      WListRow(icon: PhosphorIconsRegular.camera, title: 'Take a photo', onTap: () => Navigator.pop(context, (PickSource.camera, type))),
      WListRow(icon: PhosphorIconsRegular.image, title: 'Choose from photos', onTap: () => Navigator.pop(context, (PickSource.gallery, type))),
      WListRow(icon: PhosphorIconsRegular.filePdf, title: 'Choose a file (PDF)', onTap: () => Navigator.pop(context, (PickSource.files, type))),
      const SizedBox(height: 4),
      Text('JPEG, PNG, HEIC or PDF up to 10 MB. Files are private to you.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
    ]);
  }
}
