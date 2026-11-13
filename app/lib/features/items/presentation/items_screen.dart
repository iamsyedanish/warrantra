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
              Expanded(child: Text('Items', style: context.t.headlineMedium)),
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
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
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

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final (status, urgent) = itemStatus(item);
    final sub = [item.brand, item.retailer, if (item.purchaseDate != null) fmtDate(item.purchaseDate)].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return WCard(
      onTap: () => context.push('/items/${item.id}'),
      child: Row(children: [
        IconTile(itemIcon(category: item.categorySlug, name: item.name), size: 44),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w500, color: c.text)),
            if (sub.isNotEmpty) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: c.textMuted)),
            const SizedBox(height: 4),
            Row(children: [
              Icon(urgent ? PhosphorIconsFill.warningCircle : PhosphorIconsRegular.clock, size: 13, color: urgent ? c.urgent : c.textSubtle),
              const SizedBox(width: 4),
              Flexible(child: Text(status, style: TextStyle(fontSize: 12, color: urgent ? c.urgent : c.textSubtle, fontWeight: urgent ? FontWeight.w600 : FontWeight.w400))),
              if (!item.hasReceipt) ...[const SizedBox(width: 8), const WTag('No receipt', kind: WTagKind.outline)],
            ]),
          ]),
        ),
        if (item.price != null) Text(fmtMoney(item.price, currency: item.currency), style: TextStyle(fontSize: 13.5, color: c.textMuted)),
      ]),
    );
  }
}
