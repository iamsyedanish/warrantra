import 'package:flutter/material.dart';
import '../../../core/errors/failure.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../domain/capture.dart';
import 'capture_providers.dart';
import 'manual_screen.dart';

class ProductResultScreen extends ConsumerWidget {
  const ProductResultScreen({super.key, required this.scanId, this.attachmentId});
  final String scanId;
  final String? attachmentId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scan = ref.watch(scanProvider(scanId));
    return scan.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Check what we read', children: [ErrorView(failure: e is Failure ? e : Failure.unknown, onRetry: () => ref.invalidate(scanProvider(scanId)))]),
      data: (job) => job.label == null
          ? WScreen(title: 'Check what we read', children: const [WNote('Nothing to review. Enter the item manually.')])
          : _Form(label: job.label!, attachmentId: attachmentId ?? job.attachmentId),
    );
  }
}

class _Form extends StatefulWidget {
  const _Form({required this.label, this.attachmentId});
  final LabelDraft label;
  final String? attachmentId;
  @override
  State<_Form> createState() => _FormState();
}

class _FormState extends State<_Form> {
  late final l = widget.label;
  late final brand = TextEditingController(text: l.brand.value ?? '');
  late final model = TextEditingController(text: l.model.value ?? '');
  late final serial = TextEditingController(text: l.serial.value ?? '');
  late final name = TextEditingController(text: l.productName.value ?? [l.brand.value, l.model.value].whereType<String>().join(' '));
  bool accept = false;

  String _ev(DraftField f) => f.found ? (f.evidence == null ? 'On the label' : '“${f.evidence}”') : 'Not found, left empty';

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final s = l.suggestions.isEmpty ? null : l.suggestions.first;
    return WScreen(
      title: 'Check what we read',
      actions: const [Padding(padding: EdgeInsets.only(right: 8), child: WTag('Beta', kind: WTagKind.outline))],
      bottom: WButton('Continue to purchase details', onPressed: () {
        context.pushReplacement('/capture/manual',
            extra: ManualPrefill(
              name: name.text.trim(),
              brand: brand.text.trim(),
              model: model.text.trim(),
              serial: serial.text.trim(),
              categorySlug: l.category,
              warranty: accept && s != null ? {...s.raw, 'prompt': s.prompt} : null,
              attachmentIds: [?widget.attachmentId],
              source: 'product_scan',
            ));
      }),
      children: [
        Text("Nothing is saved until you confirm. Correct anything that doesn't match the label.", style: TextStyle(color: c.textMuted)),
        const SizedBox(height: 14),
        WField(label: 'Brand', controller: brand, helper: _ev(l.brand)),
        WField(label: 'Model', controller: model, helper: _ev(l.model)),
        WField(label: 'Serial', controller: serial, helper: _ev(l.serial)),
        WField(label: 'Product name', controller: name),
        if (l.category != null) WKeyValue('Category', l.category!.replaceAll('_', ' & '), note: 'Suggested — change it if it is wrong'),
        if (s != null) ...[
          const SizedBox(height: 8),
          WCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text('Suggested coverage', style: TextStyle(fontWeight: FontWeight.w600, color: c.text)),
                const Spacer(),
                const CertBadge('estimated'),
              ]),
              const SizedBox(height: 6),
              Text(s.prompt, style: TextStyle(color: c.textMuted, height: 1.4)),
              if (l.disclaimer != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(l.disclaimer!, style: TextStyle(fontSize: 12, color: c.textSubtle))),
              const SizedBox(height: 6),
              WCheckRow(value: accept, onChanged: (v) => setState(() => accept = v), title: 'Save as an estimate (you can confirm it later)'),
            ]),
          ),
        ],
        const SizedBox(height: 10),
        WNote("The label doesn't show when or where you bought it. Add the purchase date next.", icon: PhosphorIconsRegular.info),
        for (final w in l.warnings) Padding(padding: const EdgeInsets.only(top: 6), child: WNote(w, icon: PhosphorIconsRegular.warningCircle)),
      ],
    );
  }
}
