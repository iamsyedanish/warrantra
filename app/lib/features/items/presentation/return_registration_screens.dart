import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../domain/items.dart';
import 'item_ui.dart';
import 'items_providers.dart';

Widget _loadItem(WidgetRef ref, String itemId, String title, Widget Function(ItemDetail) build) {
  final d = ref.watch(itemDetailProvider(itemId));
  return d.when(
    loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
    error: (e, _) => WScreen(title: title, children: [AsyncBody<void>(value: AsyncError(e, StackTrace.empty), data: (_) => const SizedBox(), onRetry: () => ref.invalidate(itemDetailProvider(itemId)))]),
    data: build,
  );
}

// ---------------------------------------------------------------------------
// Return tracker
// ---------------------------------------------------------------------------
class ReturnTrackScreen extends ConsumerWidget {
  const ReturnTrackScreen({super.key, required this.itemId, required this.returnId});
  final String itemId, returnId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _loadItem(ref, itemId, 'Return', (item) {
        final r = item.returns.where((x) => x.id == returnId).firstOrNull;
        if (r == null) return WScreen(title: 'Return', children: const [WNote('This return window no longer exists.')]);
        return _ReturnTrack(item: item, r: r);
      });
}

const _steps = ['not_started', 'initiated', 'shipped', 'received_by_merchant', 'refunded'];
const _stepLabels = ['Window open', 'Return started', 'Shipped or dropped off', 'Store received it', 'Refund received'];
const _ctas = {'not_started': 'I started the return', 'initiated': 'I shipped it back', 'shipped': 'The store received it', 'received_by_merchant': 'Refund received'};

class _ReturnTrack extends ConsumerStatefulWidget {
  const _ReturnTrack({required this.item, required this.r});
  final ItemDetail item;
  final ReturnWindow r;
  @override
  ConsumerState<_ReturnTrack> createState() => _ReturnTrackState();
}

class _ReturnTrackState extends ConsumerState<_ReturnTrack> {
  bool busy = false;
  late final rma = TextEditingController(text: widget.r.rma ?? '');
  late final tracking = TextEditingController(text: widget.r.tracking ?? '');

  Future<void> _patch(Map<String, dynamic> body, {String? toast}) async {
    setState(() => busy = true);
    try {
      await ref.read(itemsRepositoryProvider).updateReturnWindow(widget.r.id, body, version: widget.r.version);
      ref.refreshItems(itemId: widget.item.summary.id);
      if (mounted && toast != null) showToast(context, toast);
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _advance() async {
    final r = widget.r;
    final next = _steps[_steps.indexOf(r.state) + 1];
    await _patch({
      'return_state': next,
      if (rma.text.trim().isNotEmpty) 'rma_number': rma.text.trim(),
      if (tracking.text.trim().isNotEmpty) 'tracking_reference': tracking.text.trim(),
    }, toast: next == 'initiated' ? 'Deadline reminders cancelled. Track it until the refund arrives.' : null);
    if (next == 'refunded' && mounted) {
      final record = await confirmDialog(context,
          title: 'Refund received',
          message: 'Mark the item as returned and record the refund amount in Outcomes?',
          confirm: 'Record outcome',
          icon: PhosphorIconsRegular.checkCircle);
      if (record && mounted) context.push('/outcomes/new?return=${r.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final r = widget.r;
    final s = widget.item.summary;
    final idx = _steps.contains(r.state) ? _steps.indexOf(r.state) : 0;
    final days = daysUntil(r.deadline);
    final finished = r.state == 'refunded';
    final ended = ['rejected', 'cancelled'].contains(r.state);
    return WScreen(
      title: 'Return · ${s.name}',
      actions: [
        PopupMenuButton<String>(
          icon: Icon(PhosphorIconsRegular.dotsThreeVertical, color: c.text),
          onSelected: (v) async {
            switch (v) {
              case 'edit':
                context.push('/items/${s.id}/return/${r.id}/edit');
              case 'rejected':
                await _patch({'return_state': 'rejected'}, toast: 'Marked as rejected by the store');
              case 'cancelled':
                await _patch({'return_state': 'cancelled'}, toast: 'Return cancelled');
              case 'dismiss':
                await _patch({'dismissed': true}, toast: "Hidden. You won't be reminded about this window.");
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit policy')),
            PopupMenuItem(value: 'rejected', child: Text('Store rejected it')),
            PopupMenuItem(value: 'cancelled', child: Text("I'm keeping it")),
            PopupMenuItem(value: 'dismiss', child: Text('Stop reminding me')),
          ],
        ),
      ],
      bottom: finished || ended
          ? WButton.secondary('View outcomes', onPressed: () => context.push('/outcomes'))
          : Column(mainAxisSize: MainAxisSize.min, children: [
              WButton(_ctas[r.state] ?? 'Next', loading: busy, onPressed: _advance),
              if (r.state == 'not_started' && r.retailer != null) ...[
                const SizedBox(height: 6),
                WButton.ghost('Find ${r.retailer} returns',
                    onPressed: () => launchUrl(Uri.parse('https://www.google.com/search?q=${Uri.encodeQueryComponent('${r.retailer} start a return')}'), mode: LaunchMode.externalApplication)),
              ],
            ]),
      children: [
        if (finished) ...[
          const WTag('Complete', kind: WTagKind.accent),
          const SizedBox(height: 6),
          Text('Refund received', style: context.t.headlineSmall),
          Text('Item marked returned. Record the amount in Outcomes if you like.', style: TextStyle(color: c.textMuted)),
        ] else if (ended) ...[
          WTag(returnStateLabel(r.state), kind: WTagKind.outline),
          const SizedBox(height: 6),
          Text(returnStateLabel(r.state), style: context.t.headlineSmall),
        ] else if (r.state == 'not_started') ...[
          if (days != null) WTag(days < 0 ? 'Window closed' : '${daysLeftLabel(days)} · inclusive', kind: days <= 3 ? WTagKind.urgent : WTagKind.neutral),
          const SizedBox(height: 6),
          Text(r.deadline == null ? 'Deadline unknown' : '${returnMeaning(r.deadlineBasis)} ${fmtDayShort(r.deadline)}', style: context.t.headlineSmall),
          Text([if (r.retailer != null) r.retailer!, if (r.windowDays != null) '${r.windowDays}-day window from ${returnAnchorLabel(r.anchor)}'].join(' · '), style: TextStyle(color: c.textMuted)),
        ] else ...[
          const WTag('In progress', kind: WTagKind.accent),
          const SizedBox(height: 6),
          Text(returnStateLabel(r.state), style: context.t.headlineSmall),
          Text('Deadline reminders are cancelled. Track it until the refund arrives.', style: TextStyle(color: c.textMuted)),
        ],
        const SizedBox(height: 16),
        WCard(
          child: Column(children: [
            for (final (i, label) in _stepLabels.indexed)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(children: [
                  Icon(i <= idx ? PhosphorIconsFill.checkCircle : i == idx + 1 ? PhosphorIconsRegular.circleDashed : PhosphorIconsRegular.circle,
                      color: i <= idx ? c.accent : c.textSubtle, size: 20),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: TextStyle(color: i <= idx ? c.text : c.textMuted))),
                ]),
              ),
          ]),
        ),
        if (!finished && !ended && r.state != 'not_started') ...[
          const SizedBox(height: 12),
          WField(label: 'RMA / return authorization', controller: rma),
          WField(label: 'Tracking number', controller: tracking),
        ],
        const WSectionHeader('Policy'),
        WCard(
          child: Column(children: [
            WKeyValue('Window counts from', titleCase(returnAnchorLabel(r.anchor))),
            WKeyValue('The deadline means', returnMeaning(r.deadlineBasis)),
            WKeyValue('Source', '', trailing: CertBadge(r.certainty, long: true)),
          ]),
        ),
        const SizedBox(height: 8),
        Text("A date-only deadline doesn't tell you the cutoff time. Check ${r.retailer ?? "the store"}'s terms if you're returning on the last day.",
            style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.4)),
        if ((r.returnQuantity ?? 0) > 0) ...[
          const SizedBox(height: 10),
          WNote('Returning ${r.returnQuantity} of ${widget.item.quantity}. Partial returns only affect the lines you select.'),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Return window editor
// ---------------------------------------------------------------------------
class ReturnEditScreen extends ConsumerWidget {
  const ReturnEditScreen({super.key, required this.itemId, this.returnId});
  final String itemId;
  final String? returnId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _loadItem(ref, itemId, 'Return window', (item) {
        final r = returnId == null ? null : item.returns.where((x) => x.id == returnId).firstOrNull;
        return _ReturnForm(item: item, r: r);
      });
}

class _ReturnForm extends ConsumerStatefulWidget {
  const _ReturnForm({required this.item, this.r});
  final ItemDetail item;
  final ReturnWindow? r;
  @override
  ConsumerState<_ReturnForm> createState() => _ReturnFormState();
}

class _ReturnFormState extends ConsumerState<_ReturnForm> {
  late final r = widget.r;
  late String mode = r == null ? 'days' : (r!.termsState == 'unknown' ? 'unknown' : (r!.windowDays != null ? 'days' : 'date'));
  late final days = TextEditingController(text: r?.windowDays?.toString() ?? '');
  late final retailer = TextEditingController(text: r?.retailer ?? widget.item.summary.retailer ?? '');
  late String anchor = r?.anchor == 'unknown' || r == null ? 'purchase_date' : r!.anchor;
  late DateTime? customAnchor = parseDate(r?.anchorDate);
  late DateTime? deadline = parseDate(r?.deadline);
  late String basis = r?.deadlineBasis ?? 'request_by';
  late String certainty = r?.certainty == 'unknown' || r == null ? 'user_confirmed' : r!.certainty;
  bool saving = false;

  DateTime? get _calc {
    final a = switch (anchor) {
      'purchase_date' => parseDate(widget.item.summary.purchaseDate),
      'delivery_date' => parseDate(widget.item.deliveryDate),
      _ => customAnchor,
    };
    final n = int.tryParse(days.text);
    if (a == null || n == null) return null;
    return a.add(Duration(days: n));
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final body = <String, dynamic>{
      'retailer_name': retailer.text.trim().isEmpty ? null : retailer.text.trim(),
      'terms_state': mode == 'unknown' ? 'unknown' : 'known',
      'policy_anchor': mode == 'days' ? anchor : 'unknown',
      'anchor_date': mode == 'days' && anchor == 'custom' ? isoDate(customAnchor) : null,
      'window_days': mode == 'days' ? int.tryParse(days.text) : null,
      'return_deadline': mode == 'date' ? isoDate(deadline) : null,
      'deadline_basis': basis,
      'date_certainty': mode == 'unknown' ? 'unknown' : certainty,
      if (certainty == 'estimated') 'accept_estimate': true,
      'source_kind': 'user_entry',
    };
    try {
      final repo = ref.read(itemsRepositoryProvider);
      if (r == null) {
        await repo.addReturnWindow(widget.item.summary.id, body);
      } else {
        await repo.updateReturnWindow(r!.id, body, version: r!.version);
      }
      ref.refreshItems(itemId: widget.item.summary.id);
      if (mounted) {
        context.pop();
        showToast(context, 'Return window saved');
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
    final calc = _calc;
    final left = daysUntil(calc);
    return WScreen(
      title: 'Return window',
      close: true,
      bottom: WButton('Save return window', loading: saving, onPressed: _save),
      children: [
        Text(widget.item.summary.name, style: TextStyle(color: c.textMuted)),
        Text('What does the store allow?', style: context.t.titleLarge),
        const SizedBox(height: 12),
        WField(label: 'Store', controller: retailer),
        WChoiceChips<String>(options: const [('days', 'Number of days'), ('date', 'A specific date'), ('unknown', 'Unknown')], value: mode, onChanged: (v) => setState(() => mode = v)),
        const SizedBox(height: 10),
        if (mode == 'days') ...[
          WField(label: 'Days in the window', controller: days, keyboardType: TextInputType.number, hint: "From the store's terms", onChanged: (_) => setState(() {})),
          WChoiceChips<String>(
            label: 'Counts from',
            options: const [('purchase_date', 'Purchase'), ('delivery_date', 'Delivery'), ('custom', 'Another date')],
            value: anchor,
            onChanged: (v) => setState(() => anchor = v),
          ),
          if (anchor == 'custom') WDateField(label: 'Start date', value: customAnchor, onChanged: (v) => setState(() => customAnchor = v)),
        ],
        if (mode == 'date') WDateField(label: 'Deadline', value: deadline, onChanged: (v) => setState(() => deadline = v)),
        if (mode == 'unknown') WNote("We won't assume 30 days. No reminder is set until you add the store's terms."),
        if (mode != 'unknown') ...[
          const SizedBox(height: 10),
          WChoiceChips<String>(
            label: 'The deadline means',
            options: const [('request_by', 'Start by'), ('postmark_by', 'Postmarked by'), ('merchant_receipt_by', 'Store receives by')],
            value: basis,
            onChanged: (v) => setState(() => basis = v),
          ),
          if (mode == 'days' && calc != null) ...[
            const SizedBox(height: 8),
            WKeyValue('Last day, inclusive', fmtDate(calc), note: left != null && left < 0 ? 'Already passed · no reminder will be set' : daysLeftLabel(left)),
          ],
          const SizedBox(height: 10),
          WChoiceChips<String>(
            label: 'Where is this from?',
            options: const [('document_verified', 'Receipt or policy'), ('user_confirmed', 'I confirmed it'), ('estimated', 'My best guess')],
            value: certainty,
            onChanged: (v) => setState(() => certainty = v),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
class RegistrationScreen extends ConsumerWidget {
  const RegistrationScreen({super.key, required this.itemId, this.registrationId});
  final String itemId;
  final String? registrationId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => _loadItem(ref, itemId, 'Registration', (item) {
        final g = registrationId == null ? null : item.registrations.where((x) => x.id == registrationId).firstOrNull;
        return _Registration(item: item, g: g);
      });
}

class _Registration extends ConsumerStatefulWidget {
  const _Registration({required this.item, this.g});
  final ItemDetail item;
  final Registration? g;
  @override
  ConsumerState<_Registration> createState() => _RegistrationState();
}

class _RegistrationState extends ConsumerState<_Registration> {
  late final g = widget.g;
  late String req = g?.requirement ?? 'optional';
  late final provider = TextEditingController(text: g?.provider ?? widget.item.summary.brand ?? '');
  late final url = TextEditingController(text: g?.url ?? '');
  late final reference = TextEditingController(text: g?.reference ?? '');
  late DateTime? deadline = parseDate(g?.deadline);
  bool busy = false;

  Future<void> _save(Map<String, dynamic> extra, {String? toast, bool pop = false}) async {
    setState(() => busy = true);
    final body = <String, dynamic>{
      'requirement_state': req,
      'provider_name': provider.text.trim().isEmpty ? null : provider.text.trim(),
      'registration_url': url.text.trim().isEmpty ? null : url.text.trim(),
      'deadline': isoDate(deadline),
      'deadline_certainty': deadline == null ? 'unknown' : 'user_confirmed',
      'confirmation_reference': reference.text.trim().isEmpty ? null : reference.text.trim(),
      'source_kind': 'user_entry',
      ...extra,
    };
    try {
      final repo = ref.read(itemsRepositoryProvider);
      if (g == null) {
        await repo.addRegistration(widget.item.summary.id, body);
      } else {
        await repo.updateRegistration(g!.id, body, version: g!.version);
      }
      ref.refreshItems(itemId: widget.item.summary.id);
      if (mounted) {
        if (toast != null) showToast(context, toast);
        if (pop || g == null) context.pop();
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final s = widget.item.summary;
    final done = g?.done ?? false;
    final serial = widget.item.serial;
    return WScreen(
      title: 'Registration · ${s.name}',
      bottom: done
          ? WButton.secondary('Undo', loading: busy, onPressed: () => _save({'status': 'not_started'}, toast: 'Marked as not registered'))
          : Column(mainAxisSize: MainAxisSize.min, children: [
              if (url.text.trim().isNotEmpty && g != null)
                WButton('Open ${provider.text.trim().isEmpty ? 'registration' : '${provider.text.trim()} registration'}', icon: PhosphorIconsRegular.arrowSquareOut, onPressed: () async {
                  await launchUrl(Uri.parse(url.text.trim()), mode: LaunchMode.externalApplication);
                  if (g!.status == 'not_started') await _save({'status': 'link_opened'});
                })
              else
                WButton(g == null ? 'Save reminder' : 'Save', loading: busy, onPressed: () => _save({}, toast: 'Saved')),
              if (g != null) ...[
                const SizedBox(height: 6),
                WButton.ghost('I already registered', onPressed: () => _save({'status': 'user_reported_complete'}, toast: 'Registration reminders cancelled')),
              ],
            ]),
      children: [
        if (done) ...[
          WTag('You confirmed · ${fmtDate(g!.completedAt)}', icon: PhosphorIconsRegular.userCheck, kind: WTagKind.accent),
          const SizedBox(height: 6),
          Text('Registered', style: context.t.headlineSmall),
          Text('Registration reminders are cancelled.', style: TextStyle(color: c.textMuted)),
        ] else ...[
          if (deadline != null) WTag('Reminder · ${fmtDayShort(deadline)}', icon: PhosphorIconsRegular.bell),
          const SizedBox(height: 6),
          Text(g == null ? 'Add a registration reminder' : 'Not registered yet', style: context.t.headlineSmall),
          if (g != null && deadline == null) Text("${provider.text.trim().isEmpty ? 'The provider' : provider.text.trim()} didn't give a deadline.", style: TextStyle(color: c.textMuted)),
        ],
        const SizedBox(height: 16),
        WChoiceChips<String>(
          label: 'Is registration needed?',
          options: const [('optional', 'Optional'), ('extra_benefit', 'Adds a benefit'), ('terms_stated_required', 'Terms say required'), ('unknown', 'Not sure')],
          value: req,
          onChanged: (v) => setState(() => req = v),
        ),
        const SizedBox(height: 8),
        Text("In the US, a full warranty can't depend on returning a registration card. Other warranties and benefits vary, so check what the terms say registration adds.",
            style: TextStyle(fontSize: 12.5, color: c.textSubtle, height: 1.4)),
        const SizedBox(height: 12),
        WField(label: 'Provider', controller: provider),
        WField(label: 'Registration link', controller: url, keyboardType: TextInputType.url, hint: 'https://', onChanged: (_) => setState(() {})),
        WDateField(label: 'Remind me by', value: deadline, onChanged: (v) => setState(() => deadline = v)),
        WField(label: 'Confirmation number', controller: reference, hint: 'Optional'),
        WKeyValue('Serial needed', serial == null ? 'Not recorded' : '${serial.substring(0, serial.length.clamp(0, 4))}${'•' * (serial.length - 4).clamp(0, 12)}'),
        if (g != null && !done) ...[
          const SizedBox(height: 8),
          WButton.ghost('Not applicable', onPressed: () => _save({'status': 'not_applicable'}, toast: 'Hidden', pop: true)),
        ],
      ],
    );
  }
}
