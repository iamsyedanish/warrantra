import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/scaffold.dart';
import '../../account/presentation/account_providers.dart';
import '../../capture/presentation/add_sheet.dart';
import '../domain/items.dart';
import 'item_ui.dart';
import 'items_providers.dart';

const _statusFilters = <(String?, String)>[
  (null, 'All'),
  ('return_soon', 'Return soon'),
  ('registration_pending', 'Registration'),
  ('active_coverage', 'Covered'),
  ('unconfirmed', 'Unconfirmed'),
  ('expired_coverage', 'Expired'),
];

const _sorts = <(String, String)>[
  ('coverage_urgency', 'Most urgent'),
  ('created_at', 'Recently added'),
  ('purchase_date', 'Purchase date'),
  ('value', 'Price'),
  ('name', 'Name'),
];

class ItemsScreen extends ConsumerStatefulWidget {
  const ItemsScreen({super.key});
  @override
  ConsumerState<ItemsScreen> createState() => _ItemsScreenState();
}

class _ItemsScreenState extends ConsumerState<ItemsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(itemsQueryProvider).q;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _setQuery(ItemQuery q) => ref.read(itemsQueryProvider.notifier).set(q);

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final q = ref.watch(itemsQueryProvider);
    final items = ref.watch(itemsListProvider);
    final me = ref.watch(meProvider).value;
    return Scaffold(
      body: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 0),
            child: Row(children: [
              Expanded(child: Text('My items', style: context.t.headlineMedium)),
              PopupMenuButton<String>(
                tooltip: 'Sort',
                icon: Icon(PhosphorIconsRegular.sortAscending, color: c.text),
                initialValue: q.sort,
                onSelected: (s) => _setQuery(q.copyWith(sort: s)),
                itemBuilder: (_) => [for (final (v, l) in _sorts) PopupMenuItem(value: v, child: Text(l))],
              ),
              PopupMenuButton<String>(
                tooltip: 'Show',
                icon: Icon(PhosphorIconsRegular.funnel, color: c.text),
                onSelected: (v) => switch (v) {
                  'archived' => _setQuery(q.copyWith(archived: q.archived == 'true' ? 'false' : 'true')),
                  'past' => _setQuery(q.copyWith(lifecycle: q.lifecycle == 'owned' ? 'any' : 'owned')),
                  _ => context.push('/portfolio'),
                },
                itemBuilder: (_) => [
                  CheckedPopupMenuItem(value: 'archived', checked: q.archived == 'true', child: const Text('Archived items')),
                  CheckedPopupMenuItem(value: 'past', checked: q.lifecycle != 'owned', child: const Text('Include returned, sold, gifted')),
                  const PopupMenuItem(value: 'portfolio', child: Text('Portfolio summary')),
                ],
              ),
            ]),
          ),
          if (me != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 2, 20, 8),
              child: Text(me.plan.isPro ? '${me.usage.itemsUsed} items' : me.itemsLine, style: TextStyle(fontSize: 13, color: c.textMuted)),
            ),
          if (me != null && !me.plan.isPro)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: WCard(
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${me.itemsLine} on Free', style: TextStyle(fontWeight: FontWeight.w500, color: c.text)),
                      const SizedBox(height: 6),
                      WProgressBar(me.usage.itemsLimit == 0 ? 0 : (me.usage.itemsUsed / me.usage.itemsLimit).clamp(0, 1).toDouble()),
                      const SizedBox(height: 4),
                      Text('Returned and archived items count too.', style: TextStyle(fontSize: 12, color: c.textSubtle)),
                    ]),
                  ),
                  const SizedBox(width: 12),
                  WButton.secondary('See Pro', expand: false, compact: true, onPressed: () => context.push('/settings/paywall')),
                ]),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search name, brand, model or store',
                prefixIcon: Icon(PhosphorIconsRegular.magnifyingGlass, color: c.textSubtle, size: 20),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(PhosphorIconsRegular.x, size: 18, color: c.textSubtle),
                        onPressed: () {
                          _search.clear();
                          _setQuery(q.copyWith(q: ''));
                          setState(() {});
                        }),
              ),
              onChanged: (v) {
                setState(() {});
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () => _setQuery(ref.read(itemsQueryProvider).copyWith(q: v.trim())));
              },
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
              for (final (v, l) in _statusFilters)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(l),
                    selected: q.status == v,
                    onSelected: (_) => _setQuery(v == null ? q.copyWith(clearStatus: true) : q.copyWith(status: v)),
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(itemsListProvider);
                await ref.read(itemsListProvider.future);
              },
              child: AsyncBody<List<ItemSummary>>(
                value: items,
                onRetry: () => ref.invalidate(itemsListProvider),
                data: (list) {
                  if (list.isEmpty) {
                    final filtered = q.q.isNotEmpty || q.status != null || q.archived == 'true';
                    return ListView(padding: const EdgeInsets.all(20), children: [
                      WEmpty(
                        icon: filtered ? PhosphorIconsRegular.magnifyingGlass : PhosphorIconsRegular.package,
                        title: filtered ? 'No matching items' : 'No items yet',
                        message: filtered ? 'Try a different search or filter.' : 'Scan a receipt or add a purchase by hand.',
                        action: filtered ? null : WButton('Add purchase', icon: PhosphorIconsRegular.plus, expand: false, onPressed: () => showAddSheet(context)),
                      ),
                    ]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 110),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => ItemCard(list[i]),
                  );
                },
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class ItemCard extends StatelessWidget {
  const ItemCard(this.item, {super.key});
  final ItemSummary item;

  String _coverageLine() {
    if (item.coverageCount == 0) return 'Coverage unknown';
    final s = parseDate(item.purchaseDate), e = parseDate(item.nearestCoverageEnd);
    if (s != null && e != null) {
      final months = ((e.difference(s).inDays) / 30.4).round();
      final term = months % 12 == 0 && months >= 12 ? '${months ~/ 12}-year' : '$months-month';
      return '$term coverage${item.coverageCount > 1 ? ' + ${item.coverageCount - 1} more' : ''}';
    }
    return item.nearestCoverageEnd == null ? 'Lifetime or open-ended coverage' : 'Coverage until ${fmtDate(item.nearestCoverageEnd)}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final (status, urgent) = itemStatus(item);
    final returnSoon = (daysUntil(item.nextReturnDeadline) ?? -1) >= 0;
    final start = parseDate(item.purchaseDate), end = parseDate(item.nearestCoverageEnd);
    double? progress;
    if (start != null && end != null && end.isAfter(start)) {
      progress = (DateTime.now().difference(start).inDays / end.difference(start).inDays).clamp(0, 1).toDouble();
    }
    final left = daysUntil(item.nearestCoverageEnd);
    final overline = [item.brand, if (item.lifecycle != 'owned') lifecycleLabels[item.lifecycle]].whereType<String>().join(' · ');
    return WCard(
      onTap: () => context.push('/items/${item.id}'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (overline.isNotEmpty)
                Text(overline.toUpperCase(), style: TextStyle(fontSize: 10.5, letterSpacing: 1, fontWeight: FontWeight.w600, color: c.accent)),
              const SizedBox(height: 2),
              Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500, color: c.text, height: 1.25)),
            ]),
          ),
          const SizedBox(width: 10),
          Icon(itemIcon(category: item.categorySlug, name: item.name), size: 22, color: c.textMuted),
        ]),
        const SizedBox(height: 10),
        if (returnSoon) ...[
          Row(children: [
            Icon(PhosphorIconsRegular.arrowUUpLeft, size: 15, color: urgent ? c.accent : c.textMuted),
            const SizedBox(width: 6),
            Expanded(child: Text(status, style: TextStyle(fontSize: 13.5, fontWeight: urgent ? FontWeight.w600 : FontWeight.w400, color: urgent ? c.accentSoftText : c.textMuted))),
          ]),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(child: Text(_coverageLine(), style: TextStyle(fontSize: 13.5, color: c.textMuted))),
          if (item.hasUnconfirmedCoverage) const CertBadge('estimated'),
          if (!item.hasReceipt) ...[const SizedBox(width: 6), const WTag('No receipt', kind: WTagKind.outline)],
        ]),
        if (progress != null) ...[
          const SizedBox(height: 10),
          WProgressBar(progress),
          const SizedBox(height: 8),
          Row(children: [
            Text(left == null ? '' : left < 0 ? 'Ended' : '$left days left', style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
            const Spacer(),
            Text(fmtDate(item.nearestCoverageEnd), style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
          ]),
        ] else if (!returnSoon && status != _coverageLine()) ...[
          const SizedBox(height: 6),
          Text(status, style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
        ],
      ]),
    );
  }
}
