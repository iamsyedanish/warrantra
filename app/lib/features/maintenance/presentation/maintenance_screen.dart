import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../../core/theme/tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/widgets/buttons.dart';
import '../../../core/widgets/display.dart';
import '../../../core/widgets/inputs.dart';
import '../../../core/widgets/scaffold.dart';
import '../../home/presentation/home_providers.dart';
import '../../items/presentation/items_providers.dart';
import '../domain/maintenance.dart';
import 'maintenance_providers.dart';

class MaintenanceScreen extends ConsumerWidget {
  const MaintenanceScreen({super.key, this.itemId});
  final String? itemId;

  Future<void> _addTask(BuildContext context, WidgetRef ref) async {
    final title = TextEditingController();
    String unit = 'month';
    final every = TextEditingController(text: '3');
    DateTime? next = DateTime.now().add(const Duration(days: 30));
    String basis = 'user_preference';
    final ok = await showWSheet<bool>(context, builder: (ctx) => StatefulBuilder(
          builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Add a recurring task', style: ctx.t.titleLarge),
            const SizedBox(height: 10),
            WField(label: 'Task', controller: title, hint: 'e.g. Clean the filter'),
            Row(children: [
              SizedBox(width: 80, child: WField(label: 'Every', controller: every, keyboardType: TextInputType.number)),
              const SizedBox(width: 10),
              Expanded(child: WChoiceChips<String>(options: const [('week', 'Weeks'), ('month', 'Months'), ('year', 'Years')], value: unit, onChanged: (v) => set(() => unit = v))),
            ]),
            WDateField(label: 'Next due', value: next, onChanged: (v) => set(() => next = v)),
            WChoiceChips<String>(
              label: 'Why',
              options: const [('user_preference', 'My routine'), ('manufacturer_recommended', 'Maker recommends'), ('warranty_terms_stated', 'Warranty terms say so')],
              value: basis,
              onChanged: (v) => set(() => basis = v),
            ),
            const SizedBox(height: 12),
            WButton('Save task', onPressed: () => Navigator.pop(ctx, title.text.trim().isNotEmpty)),
          ]),
        ));
    if (ok != true) return;
    try {
      await ref.read(maintenanceRepositoryProvider).addTask({
        'title': title.text.trim(),
        'item_id': ?itemId,
        'recurrence_unit': unit,
        'recurrence_interval': int.tryParse(every.text) ?? 1,
        'next_due_on': isoDate(next),
        'requirement_basis': basis,
        'reminder_enabled': true,
      });
      ref.invalidate(tasksProvider(itemId));
      ref.invalidate(actionCenterProvider);
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  Future<void> _addRecord(BuildContext context, WidgetRef ref) async {
    final provider = TextEditingController();
    final desc = TextEditingController();
    final cost = TextEditingController();
    DateTime? date = DateTime.now();
    String type = 'repair';
    final ok = await showWSheet<bool>(context, builder: (ctx) => StatefulBuilder(
          builder: (ctx, set) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Add a service record', style: ctx.t.titleLarge),
            const SizedBox(height: 10),
            WChoiceChips<String>(
              options: const [('repair', 'Repair'), ('maintenance', 'Maintenance'), ('inspection', 'Inspection'), ('installation', 'Installation'), ('warranty_service', 'Warranty service')],
              value: type,
              onChanged: (v) => set(() => type = v),
            ),
            const SizedBox(height: 8),
            WDateField(label: 'Date', value: date, onChanged: (v) => set(() => date = v), allowClear: false),
            WField(label: 'Provider', controller: provider),
            WField(label: 'What was done', controller: desc, maxLines: 2),
            WField(label: 'Cost', controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true)),
            WButton('Save record', onPressed: () => Navigator.pop(ctx, true)),
          ]),
        ));
    if (ok != true || itemId == null) return;
    try {
      final money = normalizeMoney(cost.text);
      await ref.read(maintenanceRepositoryProvider).addRecord({
        'item_id': itemId,
        'service_date': isoDate(date ?? DateTime.now()),
        'service_type': type,
        if (provider.text.trim().isNotEmpty) 'provider_name': provider.text.trim(),
        if (desc.text.trim().isNotEmpty) 'description': desc.text.trim(),
        if (money != null) ...{'cost_amount': money, 'cost_currency': 'USD'},
      });
      ref.invalidate(serviceRecordsProvider(itemId!));
    } catch (e) {
      if (context.mounted) showFailure(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.w;
    final tasks = ref.watch(tasksProvider(itemId));
    final item = itemId == null ? null : ref.watch(itemDetailProvider(itemId!)).value;
    final records = itemId == null ? null : ref.watch(serviceRecordsProvider(itemId!));
    return WScreen(title: 'Service & maintenance', children: [
      if (item != null) Text(item.summary.name, style: TextStyle(color: c.textMuted)),
      Text('Upkeep', style: context.t.titleLarge),
      WSectionHeader('Recurring tasks', action: 'Add', actionIcon: PhosphorIconsRegular.plus, onAction: () => _addTask(context, ref)),
      AsyncBody<List<MaintenanceTask>>(
        value: tasks,
        data: (ts) => ts.isEmpty
            ? Text('No tasks yet.', style: TextStyle(color: c.textMuted))
            : Column(children: [
                for (final t in ts)
                  WListRow(
                    icon: PhosphorIconsRegular.circle,
                    title: t.title,
                    subtitle: '${t.every}${t.nextDue == null ? '' : ' · next ${fmtDayShort(t.nextDue)}'}${t.basis == 'manufacturer_recommended' ? ' · maker recommends' : t.basis == 'warranty_terms_stated' ? ' · warranty terms' : ''}',
                    caret: false,
                    trailing: TextButton(
                      onPressed: () async {
                        try {
                          await ref.read(maintenanceRepositoryProvider).completeTask(t.id, date: isoDate(DateTime.now())!);
                          ref.invalidate(tasksProvider(itemId));
                          if (itemId != null) ref.invalidate(serviceRecordsProvider(itemId!));
                          ref.invalidate(actionCenterProvider);
                          if (context.mounted) showToast(context, 'Done. Next one scheduled.');
                        } catch (e) {
                          if (context.mounted) showFailure(context, e);
                        }
                      },
                      child: const Text('Done'),
                    ),
                  ),
              ]),
      ),
      const SizedBox(height: 6),
      Text("These are reminders, not requirements. Skipping one isn't assumed to affect coverage.", style: TextStyle(fontSize: 12.5, color: c.textSubtle)),
      if (records != null) ...[
        WSectionHeader('Service history', action: 'Add', actionIcon: PhosphorIconsRegular.plus, onAction: () => _addRecord(context, ref)),
        AsyncBody<List<ServiceRecord>>(
          value: records,
          data: (rs) => rs.isEmpty
              ? Text('No service records yet.', style: TextStyle(color: c.textMuted))
              : Column(children: [
                  for (final r in rs)
                    WListRow(
                      icon: PhosphorIconsRegular.toolbox,
                      title: titleCase(r.type),
                      subtitle: [fmtDate(r.date), if (r.provider != null) r.provider!, if (r.cost != null) fmtMoney(r.cost, currency: r.currency ?? 'USD'), if (r.description != null) r.description!].join(' · '),
                      caret: false,
                    ),
                ]),
        ),
      ],
    ]);
  }
}
