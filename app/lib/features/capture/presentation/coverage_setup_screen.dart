import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../items/presentation/items_providers.dart';
import 'review_screen.dart';

/// Step 2 of 2: everything starts unknown; the user picks what they were told.
class CoverageSetupScreen extends ConsumerStatefulWidget {
  const CoverageSetupScreen({super.key, required this.args});
  final CoverageSetupArgs args;
  @override
  ConsumerState<CoverageSetupScreen> createState() => _CoverageSetupScreenState();
}

class _Choice {
  String coverage = 'unknown';
  String returns = 'unknown';
}

class _CoverageSetupScreenState extends ConsumerState<CoverageSetupScreen> {
  late final choices = {for (final id in widget.args.itemIds) id: _Choice()};
  bool saving = false;

  Future<void> _save() async {
    setState(() => saving = true);
    final repo = ref.read(itemsRepositoryProvider);
    try {
      for (final e in choices.entries) {
        final ch = e.value;
        final sugg = ref.read(suggestionsProvider(e.key)).value;
        if (ch.coverage == 'suggested') {
          final w = Map<String, dynamic>.from((sugg?['warranties'] as List).first as Map);
          await repo.addWarranty(e.key, {
            'coverage_type': 'manufacturer',
            'provider_name': w['provider_name'],
            'term_kind': w['term_kind'] ?? 'duration',
            'duration_months': w['duration_months'],
            'start_anchor': 'purchase_date',
            'date_certainty': 'estimated',
            'accept_estimate': true,
            'source_kind': 'reference_suggestion',
            'source_reference_id': w['source_reference_id'],
          });
        } else if (ch.coverage != 'unknown') {
          await repo.addWarranty(e.key, {
            'coverage_type': 'manufacturer',
            'term_kind': ch.coverage == 'lifetime' ? 'lifetime' : 'duration',
            if (ch.coverage != 'lifetime') 'duration_months': int.parse(ch.coverage),
            'start_anchor': 'purchase_date',
            'date_certainty': ch.coverage == 'lifetime' ? 'user_confirmed' : 'estimated',
            'accept_estimate': true,
            'source_kind': 'user_entry',
          });
        }
        if (ch.returns == 'suggested') {
          final r = Map<String, dynamic>.from((sugg?['return_policies'] as List).first as Map);
          await repo.addReturnWindow(e.key, {
            'retailer_name': r['retailer_name'],
            'terms_state': 'suggested',
            'policy_anchor': r['policy_anchor'] ?? 'purchase_date',
            'window_days': r['window_days'],
            'deadline_basis': r['deadline_basis'] ?? 'request_by',
            'date_certainty': 'estimated',
            'accept_estimate': true,
            'source_kind': 'reference_suggestion',
            'source_reference_id': r['source_reference_id'],
          });
        } else if (ch.returns != 'unknown') {
          await repo.addReturnWindow(e.key, {
            'retailer_name': widget.args.retailer?.isEmpty ?? true ? null : widget.args.retailer,
            'terms_state': 'known',
            'policy_anchor': 'purchase_date',
            'window_days': int.parse(ch.returns),
            'deadline_basis': 'request_by',
            'date_certainty': 'user_confirmed',
            'source_kind': 'user_entry',
          });
        }
      }
      ref.refreshItems();
      if (!mounted) return;
      showToast(context, 'Saved ${choices.length} item${choices.length == 1 ? '' : 's'}');
      if (choices.length == 1) {
        context.pushReplacement('/items/${choices.keys.first}');
      } else {
        context.go('/items');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return WScreen(
      title: 'Coverage & returns · Step 2 of 2',
      onBack: () => context.go('/home'),
      bottom: WButton('Save', loading: saving, onPressed: _save),
      children: [
        Text('Everything starts as unknown. Accept a suggestion only if it matches what you were told.', style: TextStyle(color: c.textMuted, height: 1.45)),
        for (final w in widget.args.warnings) Padding(padding: const EdgeInsets.only(top: 8), child: WNote(w, icon: PhosphorIconsRegular.warningCircle)),
        if (widget.args.mentions.isNotEmpty) ...[
          const WSectionHeader('Found on the receipt — not confirmed'),
          for (final m in widget.args.mentions) Padding(padding: const EdgeInsets.only(bottom: 6), child: WNote(m, icon: PhosphorIconsRegular.quotes)),
        ],
        for (final id in widget.args.itemIds) _ItemCard(itemId: id, choice: choices[id]!, onChanged: () => setState(() {})),
        const SizedBox(height: 8),
        Row(children: [
          Icon(PhosphorIconsRegular.stack, size: 16, color: c.textSubtle),
          const SizedBox(width: 6),
          Text('Saved together: 1 purchase, ${widget.args.itemIds.length} item${widget.args.itemIds.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
        ]),
      ],
    );
  }
}

class _ItemCard extends ConsumerWidget {
  const _ItemCard({required this.itemId, required this.choice, required this.onChanged});
  final String itemId;
  final _Choice choice;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final item = ref.watch(itemDetailProvider(itemId)).value;
    final sugg = ref.watch(suggestionsProvider(itemId)).value;
    final ws = (sugg?['warranties'] as List?) ?? const [];
    final rs = (sugg?['return_policies'] as List?) ?? const [];
    final w0 = ws.isEmpty ? null : Map<String, dynamic>.from(ws.first as Map);
    final r0 = rs.isEmpty ? null : Map<String, dynamic>.from(rs.first as Map);
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: WCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item?.summary.name ?? 'Item', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: c.text)),
          const SizedBox(height: 10),
          if (w0 != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                  'Suggested: ${w0['duration_months'] ?? ''}${w0['duration_months'] == null ? w0['term_kind'] : '-month'} warranty from ${w0['provider_name']}${w0['last_verified_at'] == null ? '' : ', checked ${fmtDate(w0['last_verified_at'])}'}. Not confirmed for this purchase.',
                  style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            ),
          WChoiceChips<String>(
            label: 'Coverage',
            options: [('unknown', 'Unknown'), if (w0 != null) ('suggested', 'Use suggestion'), ('12', '1 year'), ('24', '2 years'), ('36', '3 years'), ('lifetime', 'Lifetime')],
            value: choice.coverage,
            onChanged: (v) {
              choice.coverage = v;
              onChanged();
            },
          ),
          if (choice.coverage != 'unknown' && choice.coverage != 'lifetime')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(children: [const CertBadge('estimated'), const SizedBox(width: 6), Text('Saved as Estimated', style: TextStyle(fontSize: 12, color: c.textSubtle))]),
            ),
          const SizedBox(height: 12),
          if (r0 != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('Suggested: ${r0['retailer_name']} usually allows ${r0['window_days']} days. Check your receipt or the store.', style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            ),
          WChoiceChips<String>(
            label: '${item?.summary.retailer ?? 'Store'} return window',
            options: [('unknown', 'Unknown'), if (r0 != null) ('suggested', 'Use suggestion'), ('14', '14 days'), ('30', '30 days'), ('60', '60 days'), ('90', '90 days')],
            value: choice.returns,
            onChanged: (v) {
              choice.returns = v;
              onChanged();
            },
          ),
        ]),
      ),
    );
  }
}
