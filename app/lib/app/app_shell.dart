import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../core/theme/tokens.dart';
import '../features/capture/presentation/add_sheet.dart';
import 'device_registration.dart';

/// Bottom tabs (Home, Items, Vault, Settings) with the center Add button.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;
  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => registerDevice(ref));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final i = widget.shell.currentIndex;
    Widget tab(int index, IconData icon, IconData active, String label) {
      final on = i == index;
      return Expanded(
        child: InkWell(
          onTap: () => widget.shell.goBranch(index, initialLocation: index == i),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            // Scales down instead of overflowing with very large text settings.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(on ? active : icon, color: on ? c.accent : c.textSubtle, size: 24),
                const SizedBox(height: 3),
                Text(label, maxLines: 1, style: TextStyle(fontSize: 11, color: on ? c.accent : c.textSubtle, fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
              ]),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: widget.shell,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.divider))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            tab(0, PhosphorIconsRegular.house, PhosphorIconsFill.house, 'Home'),
            tab(1, PhosphorIconsRegular.package, PhosphorIconsFill.package, 'Items'),
            Expanded(
              child: Center(
                child: Semantics(
                  button: true,
                  label: 'Add purchase',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(14),
                    onTap: () => showAddSheet(context),
                    child: Container(
                      width: 48,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.accentSoft,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: c.accent, width: 1.4),
                      ),
                      child: Icon(PhosphorIconsRegular.plus, color: c.accentSoftText, size: 24),
                    ),
                  ),
                ),
              ),
            ),
            tab(2, PhosphorIconsRegular.vault, PhosphorIconsFill.vault, 'Vault'),
            tab(3, PhosphorIconsRegular.gear, PhosphorIconsFill.gear, 'Settings'),
          ]),
          ),
        ),
      ),
    );
  }
}
