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
import '../domain/items.dart';
import 'item_ui.dart';
import 'items_providers.dart';

/// Add or edit one coverage record (manufacturer, retailer, extended, card benefit…).
class CoverageEditScreen extends ConsumerWidget {
  const CoverageEditScreen({super.key, required this.itemId, this.warrantyId, this.suggestion});
  final String itemId;
  final String? warrantyId;
  final Map<String, dynamic>? suggestion;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(itemDetailProvider(itemId));
    return d.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => WScreen(title: 'Coverage', children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox())]),
      data: (item) {
        final w = warrantyId == null ? null : item.warranties.where((x) => x.id == warrantyId).firstOrNull;
        return _CoverageForm(item: item, existing: w, suggestion: suggestion);
      },
    );
  }
}

class _CoverageForm extends ConsumerStatefulWidget {
  const _CoverageForm({required this.item, this.existing, this.suggestion});
  final ItemDetail item;
  final Warranty? existing;
  final Map<String, dynamic>? suggestion;
  @override
  ConsumerState<_CoverageForm> createState() => _CoverageFormState();
}

class _CoverageFormState extends ConsumerState<_CoverageForm> {
  late final w = widget.existing;
  late final s = widget.suggestion;
  late String type = w?.coverageType ?? s?['coverage_type']?.toString() ?? 'manufacturer';
  late final provider = TextEditingController(text: w?.provider ?? s?['provider_name']?.toString() ?? widget.item.summary.brand ?? '');
  late String kind = w?.termKind ?? s?['term_kind']?.toString() ?? 'duration';
  late final months = TextEditingController(text: '${w?.durationMonths ?? s?['duration_months'] ?? 12}');
  late String anchor = w?.startAnchor ?? 'purchase_date';
  late DateTime? customStart = parseDate(w?.startDate);
  late DateTime? endDate = parseDate(w?.endDate);
  late final conditions = TextEditingController(text: w?.conditions ?? s?['conditions_summary']?.toString() ?? '');
  late String certainty = w?.certainty ?? (s != null ? 'estimated' : 'user_confirmed');
  late bool acceptEstimate = w?.estimateAccepted ?? s != null;
  late final policy = TextEditingController(text: w?.policyNumber ?? '');
  late final termsUrl = TextEditingController(text: w?.termsUrl ?? s?['source_url']?.toString() ?? '');
  late final notes = TextEditingController(text: w?.notes ?? '');
  bool saving = false;

  DateTime? get _anchorDate => switch (anchor) {
        'purchase_date' => parseDate(widget.item.summary.purchaseDate),
        'delivery_date' => parseDate(widget.item.deliveryDate),
        'custom' => customStart,
        _ => null,
      };

  DateTime? get _calcEnd {
    final a = _anchorDate;
    final m = int.tryParse(months.text);
    if (a == null || m == null) return null;
    final lastDay = DateTime(a.year, a.month + m + 1, 0).day;
    return DateTime(a.year, a.month + m, a.day > lastDay ? lastDay : a.day);
  }

  String get _reminderLine {
    if (kind == 'unknown') return 'No reminder will be set.';
    if (kind == 'lifetime') return 'No expiry reminders for lifetime coverage.';
    if (certainty == 'estimated' && !acceptEstimate) return 'No reminder until you accept the estimate.';
    return 'Reminders before it ends, at your usual alert time.';
  }

  Future<void> _save() async {
    setState(() => saving = true);
    String? t(TextEditingController c) => c.text.trim().isEmpty ? null : c.text.trim();
    final body = <String, dynamic>{
      'coverage_type': type,
      'provider_name': t(provider),
      'term_kind': kind,
      'date_certainty': kind == 'unknown' ? 'unknown' : certainty,
      'start_anchor': kind == 'duration' ? anchor : null,
      'start_date': kind == 'duration' && anchor == 'custom' ? isoDate(customStart) : null,
      'duration_months': kind == 'duration' ? int.tryParse(months.text) : null,
      'end_date': kind == 'fixed_date' ? isoDate(endDate) : null,
      'conditional_terms': t(conditions),
      'accept_estimate': certainty == 'estimated' ? acceptEstimate : null,
      'policy_number': t(policy),
      'terms_url': t(termsUrl),
      'notes': t(notes),
      'source_kind': s != null && w == null ? 'reference_suggestion' : 'user_entry',
      if (s?['source_reference_id'] != null && w == null) 'source_reference_id': s!['source_reference_id'],
    }..removeWhere((k, v) => v == null && w == null);
    try {
      final repo = ref.read(itemsRepositoryProvider);
      if (w == null) {
        await repo.addWarranty(widget.item.summary.id, body);
      } else {
        await repo.updateWarranty(w!.id, body, version: w!.version);
      }
      ref.refreshItems(itemId: widget.item.summary.id);
      if (mounted) {
        context.pop();
        showToast(context, 'Coverage saved');
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(context, title: 'Remove this coverage?', message: 'Its reminders are cancelled. The item and documents stay.', confirm: 'Remove', destructive: true);
    if (!ok) return;
    try {
      await ref.read(itemsRepositoryProvider).deleteWarranty(w!.id);
      ref.refreshItems(itemId: widget.item.summary.id);
      if (mounted) context.pop();
    } catch (e) {
      if (mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return WScreen(
      title: w == null ? 'Add coverage' : 'Edit coverage',
      close: true,
      actions: [if (w != null) WIconButton(PhosphorIconsRegular.trash, tooltip: 'Remove', onPressed: _delete)],
      bottom: WButton('Save coverage', loading: saving, onPressed: _save),
      children: [
        Text(widget.item.summary.name, style: TextStyle(color: c.textMuted)),
        Text('What protects it?', style: context.t.titleLarge),
        if (s != null) ...[
          const SizedBox(height: 10),
          WNote('Suggested from ${s!['provider_name'] ?? 'reference'} information${s!['last_verified_at'] == null ? '' : ', checked ${fmtDate(s!['last_verified_at'])}'}. Confirm your actual terms.',
              icon: PhosphorIconsRegular.lightbulb),
        ],
        const SizedBox(height: 14),
        WChoiceChips<String>(label: 'Type', options: [for (final e in coverageTypeLabels.entries) (e.key, e.value)], value: type, onChanged: (v) => setState(() => type = v)),
        const SizedBox(height: 10),
        WField(label: 'Provider', controller: provider, hint: 'e.g. LG'),
        WChoiceChips<String>(
          label: 'How long does it last?',
          options: const [('duration', 'Months'), ('fixed_date', 'End date'), ('lifetime', 'Lifetime'), ('conditional', 'Conditional'), ('unknown', 'Unknown')],
          value: kind,
          onChanged: (v) => setState(() => kind = v),
        ),
        const SizedBox(height: 10),
        if (kind == 'duration') ...[
          WField(label: 'Months', controller: months, keyboardType: TextInputType.number, onChanged: (_) => setState(() {})),
          WChoiceChips<String>(
            label: 'Counts from',
            options: const [('purchase_date', 'Purchase'), ('delivery_date', 'Delivery'), ('custom', 'Another date')],
            value: anchor,
            onChanged: (v) => setState(() => anchor = v),
          ),
          if (anchor == 'custom') WDateField(label: 'Start date', value: customStart, onChanged: (v) => setState(() => customStart = v)),
          const SizedBox(height: 8),
          WKeyValue('Calculated end date', _calcEnd == null ? 'Add the ${anchor == 'delivery_date' ? 'delivery' : 'start'} date' : fmtDate(_calcEnd),
              note: 'Month-end dates clamp (Jan 31 + 1 month → Feb 28/29).'),
        ],
        if (kind == 'fixed_date') WDateField(label: 'End date (as written in the terms)', value: endDate, onChanged: (v) => setState(() => endDate = v)),
        if (kind == 'lifetime') WNote('Lifetime is stored without an end date, not as a far-off year. Note any conditions below.'),
        if (kind == 'conditional' || kind == 'lifetime') WField(label: 'Conditions', controller: conditions, hint: 'e.g. 10 years on motor if registered', maxLines: 2),
        if (kind == 'unknown') WNote('No reminder will be set. The item stays under Missing info until you add terms.'),
        if (kind != 'unknown') ...[
          const SizedBox(height: 10),
          WChoiceChips<String>(
            label: 'How sure is this?',
            options: const [('document_verified', 'From a document'), ('user_confirmed', 'I confirmed it'), ('estimated', 'Estimate')],
            value: certainty,
            onChanged: (v) => setState(() => certainty = v),
          ),
          if (certainty == 'estimated')
            WCheckRow(
              value: acceptEstimate,
              onChanged: (v) => setState(() => acceptEstimate = v),
              title: 'Use this estimated date for reminders',
              subtitle: 'It will be labeled Estimated everywhere it appears.',
            ),
          const SizedBox(height: 8),
          WField(label: 'Policy or contract number', controller: policy),
          WField(label: 'Terms link', controller: termsUrl, keyboardType: TextInputType.url, hint: 'https://'),
          WField(label: 'Notes', controller: notes, maxLines: 3),
          Row(children: [
            Icon(PhosphorIconsRegular.bell, size: 16, color: c.textSubtle),
            const SizedBox(width: 6),
            Expanded(child: Text(_reminderLine, style: TextStyle(fontSize: 12.5, color: c.textSubtle))),
          ]),
        ],
      ],
    );
  }
}
