import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../../core/theme/tokens.dart';

/// A small drawn picture of a Warrantra screen with one part outlined and a
/// pointing hand on it. Drawn from the app's own colours, so it follows light
/// and dark mode and never goes stale like a screenshot.
class GuideIllustration extends StatefulWidget {
  const GuideIllustration({super.key, required this.target, this.height = 150});

  /// A GuideTarget id, e.g. 'items.search'.
  final String target;
  final double height;

  /// True when there is a picture for [target].
  static bool has(String? target) => target != null && _screenFor(target) != null;

  @override
  State<GuideIllustration> createState() => _GuideIllustrationState();
}

class _GuideIllustrationState extends State<GuideIllustration> with SingleTickerProviderStateMixin {
  late final AnimationController _tap = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();

  @override
  void dispose() {
    _tap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final screen = _screenFor(widget.target);
    if (screen == null) return const SizedBox.shrink();
    return Semantics(
      image: true,
      label: 'Picture of the screen with the part to tap highlighted',
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: c.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.divider),
        ),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, box.maxHeight);
          final hit = screen.firstWhere((e) => e.id == widget.target);
          final r = hit.rect(size);
          return AnimatedBuilder(
            animation: _tap,
            builder: (context, _) {
              final t = _tap.value;
              // The hand moves in, presses (scales down), and lifts.
              final press = t < 0.5 ? 0.0 : math.sin((t - 0.5) / 0.5 * math.pi);
              final ring = (t * 1.6) % 1.0;
              return Stack(children: [
                for (final e in screen) e.build(context, size, highlighted: e.id == widget.target),
                // Pulsing ring around the highlighted part.
                Positioned.fromRect(
                  rect: r.inflate(3 + ring * 6),
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10 + ring * 6),
                        border: Border.all(color: c.accent.withValues(alpha: (1 - ring) * 0.7), width: 2),
                      ),
                    ),
                  ),
                ),
                // Pointing hand.
                Positioned(
                  left: (r.center.dx - 6).clamp(0, size.width - 30),
                  top: (r.center.dy + 2 - press * 4).clamp(0, size.height - 30),
                  child: Transform.scale(
                    scale: 1 - press * 0.12,
                    child: Icon(PhosphorIconsFill.handPointing, size: 28, color: c.text, shadows: [Shadow(color: c.bg, blurRadius: 6)]),
                  ),
                ),
              ]);
            },
          );
        }),
      ),
    );
  }
}

/// One drawn element of a mini screen, placed by fractions of the picture.
class _El {
  const _El(this.id, this.l, this.t, this.w, this.h, this.kind, {this.label, this.icon});
  final String id;
  final double l, t, w, h;
  final _K kind;
  final String? label;
  final IconData? icon;

  Rect rect(Size s) => Rect.fromLTWH(l * s.width, t * s.height, w * s.width, h * s.height);

  Widget build(BuildContext context, Size s, {required bool highlighted}) {
    final c = context.w;
    final r = rect(s);
    final ring = highlighted ? Border.all(color: c.accent, width: 2) : null;
    Widget child;
    switch (kind) {
      case _K.title:
        child = Align(
          alignment: Alignment.centerLeft,
          child: Text(label ?? '', maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(fontSize: r.height * 0.62, fontWeight: FontWeight.w600, color: c.text, height: 1)),
        );
      case _K.label:
        child = Align(
          alignment: Alignment.centerLeft,
          child: Text((label ?? '').toUpperCase(), maxLines: 1, overflow: TextOverflow.clip, style: TextStyle(fontSize: 8, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: c.textSubtle)),
        );
      case _K.card:
        child = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), border: ring ?? Border.all(color: c.divider)),
          child: Row(children: [
            if (icon != null) ...[
              Container(
                width: math.min(22, r.height * 0.6),
                height: math.min(22, r.height * 0.6),
                decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(6)),
                child: Icon(icon, size: math.min(13, r.height * 0.36), color: c.accent),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(label ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w500, color: c.text)),
            ),
          ]),
        );
      case _K.field:
        child = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), border: ring ?? Border.all(color: c.divider)),
          child: Row(children: [
            Icon(icon ?? PhosphorIconsRegular.magnifyingGlass, size: 11, color: c.textSubtle),
            const SizedBox(width: 5),
            Expanded(child: Text(label ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.5, color: c.textSubtle))),
          ]),
        );
      case _K.chips:
        child = Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: ring),
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
          child: Row(children: [
            for (final (i, l) in (label ?? '').split('|').indexed)
              Container(
                margin: const EdgeInsets.only(right: 4),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: i == 0 ? c.accent : c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: i == 0 ? c.accent : c.divider),
                ),
                child: Text(l, style: TextStyle(fontSize: 8.5, fontWeight: FontWeight.w600, color: i == 0 ? c.onAccent : c.text)),
              ),
          ]),
        );
      case _K.button:
        child = Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.accent, borderRadius: BorderRadius.circular(8), border: ring),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) Icon(icon, size: 11, color: c.onAccent),
            if (icon != null && label != null) const SizedBox(width: 4),
            if (label != null) Text(label!, style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w600, color: c.onAccent)),
          ]),
        );
      case _K.icon:
        child = Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: ring),
          child: Icon(icon, size: math.min(16, r.height * 0.7), color: c.text),
        );
      case _K.hero:
        child = Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF7B67E3), Color(0xFF4B3CA8)]),
            borderRadius: BorderRadius.circular(10),
            border: ring,
          ),
          child: Text(label ?? '', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
        );
      case _K.meter:
        child = Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), border: ring ?? Border.all(color: c.divider)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            for (final (i, l) in (label ?? '').split('|').indexed) ...[
              Text(l, style: TextStyle(fontSize: 8.5, color: c.text)),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: [0.4, 0.15, 0.6][i % 3], minHeight: 4, color: c.accent, backgroundColor: c.accentSoft),
              ),
            ],
          ]),
        );
      case _K.tabs:
        child = Container(
          decoration: BoxDecoration(color: c.surface, border: Border(top: BorderSide(color: c.divider))),
        );
      case _K.tab:
        child = Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: ring),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 13, color: highlighted ? c.accent : c.textSubtle),
            if (label != null) Text(label!, style: TextStyle(fontSize: 7, color: highlighted ? c.accent : c.textSubtle)),
          ]),
        );
      case _K.add:
        child = Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(color: c.accentSoft, borderRadius: BorderRadius.circular(8), border: Border.all(color: c.accent, width: highlighted ? 2 : 1.2)),
          child: Icon(PhosphorIconsRegular.plus, size: 13, color: c.accentSoftText),
        );
      case _K.pip:
        child = Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(shape: BoxShape.circle, border: ring, color: const Color(0xFF7B67E3)),
          child: const Icon(PhosphorIconsFill.shieldCheck, size: 13, color: Colors.white),
        );
      case _K.sheet:
        child = Container(
          decoration: BoxDecoration(color: c.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(12)), border: Border.all(color: c.divider)),
        );
      case _K.toggle:
        child = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(8), border: ring ?? Border.all(color: c.divider)),
          child: Row(children: [
            Expanded(child: Text(label ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 9.5, color: c.text))),
            Text('9:00 AM', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: c.accent)),
          ]),
        );
      case _K.themes:
        child = Container(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: ring),
          padding: const EdgeInsets.all(2),
          child: Row(children: [
            for (final (i, bg) in [const Color(0xFFF6F6FC), const Color(0xFFF6F6FC), const Color(0xFF161826)].indexed)
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: i == 0 ? c.accent : c.divider, width: i == 0 ? 1.5 : 1),
                  ),
                  child: i == 0
                      ? ClipPath(clipper: _Half(), child: Container(color: const Color(0xFF161826)))
                      : null,
                ),
              ),
          ]),
        );
    }
    return Positioned.fromRect(rect: r, child: child);
  }
}

enum _K { title, label, card, field, chips, button, icon, hero, meter, tabs, tab, add, pip, sheet, toggle, themes }

class _Half extends CustomClipper<Path> {
  @override
  Path getClip(Size s) => Path()
    ..moveTo(s.width, 0)
    ..lineTo(s.width, s.height)
    ..lineTo(0, s.height)
    ..close();
  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

// --- Mini screens -----------------------------------------------------------

const _tabBar = <_El>[
  _El('tabs', 0, 0.82, 1, 0.18, _K.tabs),
  _El('nav.home', 0.03, 0.84, 0.17, 0.14, _K.tab, icon: PhosphorIconsRegular.house, label: 'Home'),
  _El('nav.items', 0.22, 0.84, 0.17, 0.14, _K.tab, icon: PhosphorIconsRegular.package, label: 'Items'),
  _El('nav.add', 0.43, 0.845, 0.14, 0.13, _K.add),
  _El('nav.vault', 0.61, 0.84, 0.17, 0.14, _K.tab, icon: PhosphorIconsRegular.vault, label: 'Vault'),
  _El('nav.settings', 0.80, 0.84, 0.17, 0.14, _K.tab, icon: PhosphorIconsRegular.gear, label: 'Settings'),
];

const _screens = <String, List<_El>>{
  'home': [
    _El('t', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Action Center'),
    _El('home.attention', 0.05, 0.2, 0.9, 0.17, _K.card, icon: PhosphorIconsRegular.arrowUUpLeft, label: 'Return window ends in 3 days'),
    _El('c2', 0.05, 0.4, 0.9, 0.14, _K.card, icon: PhosphorIconsRegular.clipboardText, label: 'Registration due in 12 days'),
    _El('home.recent', 0.05, 0.6, 0.6, 0.1, _K.label, label: 'Recent purchases'),
    ..._tabBar,
  ],
  'nav': [
    _El('t', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Action Center'),
    _El('c1', 0.05, 0.2, 0.9, 0.15, _K.card, icon: PhosphorIconsRegular.arrowUUpLeft, label: 'Return window ends soon'),
    _El('c2', 0.05, 0.4, 0.9, 0.15, _K.card, icon: PhosphorIconsRegular.shieldCheck, label: 'Coverage ends in 27 days'),
    _El('guide.button', 0.86, 0.64, 0.1, 0.14, _K.pip),
    ..._tabBar,
  ],
  'add': [
    _El('bg', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Action Center'),
    _El('sheet', 0, 0.2, 1, 0.8, _K.sheet),
    _El('st', 0.06, 0.26, 0.6, 0.09, _K.title, label: 'Add a purchase'),
    _El('add.scan', 0.06, 0.4, 0.88, 0.16, _K.card, icon: PhosphorIconsRegular.scan, label: 'Scan receipt'),
    _El('add.upload', 0.06, 0.59, 0.88, 0.16, _K.card, icon: PhosphorIconsRegular.uploadSimple, label: 'Upload image or PDF'),
    _El('add.manual', 0.06, 0.78, 0.88, 0.16, _K.card, icon: PhosphorIconsRegular.pencilSimpleLine, label: 'Enter manually'),
  ],
  'items': [
    _El('t', 0.05, 0.05, 0.5, 0.11, _K.title, label: 'My items'),
    _El('items.sort', 0.76, 0.04, 0.09, 0.13, _K.icon, icon: PhosphorIconsRegular.sortAscending),
    _El('f', 0.87, 0.04, 0.09, 0.13, _K.icon, icon: PhosphorIconsRegular.funnel),
    _El('items.search', 0.05, 0.22, 0.9, 0.14, _K.field, label: 'Search name, brand, model or store'),
    _El('items.filters', 0.05, 0.39, 0.9, 0.16, _K.chips, label: 'All|Return soon|Registration|Covered'),
    _El('i1', 0.05, 0.58, 0.9, 0.17, _K.card, icon: PhosphorIconsRegular.package, label: 'Bosch Series 6 Dishwasher'),
    _El('i2', 0.05, 0.79, 0.9, 0.17, _K.card, icon: PhosphorIconsRegular.cookingPot, label: 'Air fryer'),
  ],
  'item': [
    _El('t', 0.05, 0.05, 0.8, 0.11, _K.title, label: 'Bosch Series 6 Dishwasher'),
    _El('item.coverage', 0.05, 0.2, 0.9, 0.18, _K.card, icon: PhosphorIconsRegular.shieldCheck, label: 'Coverage · 3 years · ends Nov 2029'),
    _El('item.registration', 0.05, 0.43, 0.9, 0.16, _K.card, icon: PhosphorIconsRegular.clipboardText, label: 'Registration · by Dec 10'),
    _El('item.claims', 0.05, 0.64, 0.9, 0.16, _K.card, icon: PhosphorIconsRegular.lifebuoy, label: 'Claims & returns · Start'),
    _El('d', 0.05, 0.85, 0.9, 0.12, _K.card, icon: PhosphorIconsRegular.receipt, label: 'Receipt photo'),
  ],
  'vault': [
    _El('t', 0.05, 0.05, 0.4, 0.11, _K.title, label: 'Vault'),
    _El('vault.upload', 0.68, 0.05, 0.27, 0.13, _K.button, icon: PhosphorIconsRegular.uploadSimple, label: 'Upload'),
    _El('vault.filters', 0.05, 0.24, 0.9, 0.16, _K.chips, label: 'All|Receipts|Warranties|Manuals'),
    _El('vault.first', 0.05, 0.44, 0.9, 0.16, _K.card, icon: PhosphorIconsRegular.receipt, label: 'Receipt · Nov 26'),
    _El('v2', 0.05, 0.64, 0.9, 0.16, _K.card, icon: PhosphorIconsRegular.fileText, label: 'Warranty card'),
  ],
  'claims': [
    _El('claims.summary', 0.05, 0.08, 0.9, 0.3, _K.hero, label: '1 claim in progress'),
    _El('c1', 0.05, 0.46, 0.9, 0.2, _K.card, icon: PhosphorIconsRegular.chatCircleText, label: 'Samsung TV · Warranty repair'),
  ],
  'reminders': [
    _El('t', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Reminders'),
    _El('reminders.time', 0.05, 0.22, 0.9, 0.16, _K.toggle, label: 'Time of day'),
    _El('reminders.kinds', 0.05, 0.46, 0.9, 0.3, _K.card, icon: PhosphorIconsRegular.arrowUUpLeft, label: 'Return windows · 1 week, 3 days, 1 day'),
  ],
  'plan': [
    _El('t', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Plan & usage'),
    _El('plan.usage', 0.05, 0.2, 0.9, 0.42, _K.meter, label: 'Items|Storage|AI reads'),
    _El('plan.pro', 0.05, 0.72, 0.9, 0.15, _K.button, label: 'See everything in Pro'),
  ],
  'settings': [
    _El('t', 0.05, 0.05, 0.6, 0.1, _K.title, label: 'Settings'),
    _El('s1', 0.05, 0.2, 0.9, 0.14, _K.card, icon: PhosphorIconsRegular.bell, label: 'Reminders'),
    _El('l', 0.05, 0.42, 0.5, 0.08, _K.label, label: 'Appearance'),
    _El('settings.appearance', 0.05, 0.52, 0.9, 0.3, _K.themes),
  ],
  'signin': [
    _El('t', 0.05, 0.05, 0.7, 0.1, _K.title, label: 'Sign-in methods'),
    _El('signin.list', 0.05, 0.22, 0.9, 0.4, _K.card, icon: PhosphorIconsRegular.key, label: 'Email ✓   ·   Google: Add'),
  ],
};

List<_El>? _screenFor(String target) {
  // Tour targets on the tab bar use the plain Home picture.
  if (target.startsWith('nav.') || target == 'guide.button') return _screens['nav'];
  for (final s in _screens.values) {
    if (s.any((e) => e.id == target)) return s;
  }
  return null;
}
