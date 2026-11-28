import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../theme/tokens.dart';

/// A branded spinner: an icon in a soft tile with an arc orbiting around it.
class WOrbitLoader extends StatefulWidget {
  const WOrbitLoader({super.key, this.size = 72, this.icon = PhosphorIconsFill.shieldCheck});
  final double size;
  final IconData icon;
  @override
  State<WOrbitLoader> createState() => _WOrbitLoaderState();
}

class _WOrbitLoaderState extends State<WOrbitLoader> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final s = widget.size;
    return SizedBox.square(
      dimension: s,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, child) => Stack(alignment: Alignment.center, children: [
          // Soft breathing halo.
          Container(
            width: s * (0.78 + 0.06 * math.sin(_spin.value * 2 * math.pi)),
            height: s * (0.78 + 0.06 * math.sin(_spin.value * 2 * math.pi)),
            decoration: BoxDecoration(shape: BoxShape.circle, color: c.accent.withValues(alpha: 0.12)),
          ),
          Transform.rotate(
            angle: _spin.value * 2 * math.pi,
            child: CustomPaint(size: Size.square(s), painter: _ArcPainter(c.accent)),
          ),
          child!,
        ]),
        child: Container(
          width: s * 0.5,
          height: s * 0.5,
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF8A78EA), Color(0xFF5640B8)]),
            borderRadius: BorderRadius.circular(s * 0.16),
          ),
          child: Icon(widget.icon, color: Colors.white, size: s * 0.28),
        ),
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = SweepGradient(colors: [color.withValues(alpha: 0), color], stops: const [0.15, 1]).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.06
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(size.width * 0.05), 0, math.pi * 1.6, false, paint);
  }

  @override
  bool shouldRepaint(covariant _ArcPainter old) => old.color != color;
}

/// The card shown while something blocking happens (uploading, saving).
class WBusyCard extends StatelessWidget {
  const WBusyCard({super.key, required this.title, this.subtitle, this.icon = PhosphorIconsFill.shieldCheck});
  final String title;
  final String? subtitle;
  final IconData icon;
  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Center(
      child: Material(
        color: c.surface,
        borderRadius: BorderRadius.circular(24),
        elevation: 0,
        child: Container(
          width: 280,
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 24),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: c.divider),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 30, offset: const Offset(0, 12))],
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            WOrbitLoader(size: 84, icon: icon),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: c.text)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(fontSize: 13.5, height: 1.4, color: c.textMuted)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Shows [WBusyCard] over the app until the returned callback is called.
VoidCallback showBusyDialog(BuildContext context, {required String title, String? subtitle, IconData icon = PhosphorIconsFill.shieldCheck}) {
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  showGeneralDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, _, _) => PopScope(canPop: false, child: WBusyCard(title: title, subtitle: subtitle, icon: icon)),
    transitionBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
    ),
  ).whenComplete(() => open = false);
  return () {
    if (open && nav.mounted) {
      open = false;
      nav.pop();
    }
  };
}

/// A receipt with a light sweeping down it, for "reading your receipt".
class WScanAnimation extends StatefulWidget {
  const WScanAnimation({super.key, this.height = 150, this.icon = PhosphorIconsRegular.receipt});
  final double height;
  final IconData icon;
  @override
  State<WScanAnimation> createState() => _WScanAnimationState();
}

class _WScanAnimationState extends State<WScanAnimation> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))..repeat(reverse: true);

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final h = widget.height, w = h * 0.74;
    Widget line(double width, {bool strong = false}) => Container(
          width: width,
          height: 6,
          margin: const EdgeInsets.only(bottom: 7),
          decoration: BoxDecoration(color: strong ? c.text.withValues(alpha: 0.55) : c.textSubtle.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(3)),
        );
    return SizedBox(
      height: h + 16,
      child: Center(
        child: AnimatedBuilder(
          animation: _sweep,
          builder: (context, _) {
            final t = Curves.easeInOut.transform(_sweep.value);
            return Stack(clipBehavior: Clip.none, children: [
              // The receipt.
              Container(
                width: w,
                height: h,
                padding: const EdgeInsets.fromLTRB(14, 16, 14, 12),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: c.divider),
                  boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.15), blurRadius: 24, offset: const Offset(0, 8))],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(widget.icon, size: 16, color: c.accent),
                    const SizedBox(width: 6),
                    Expanded(child: line(w * 0.35, strong: true)),
                  ]),
                  const SizedBox(height: 8),
                  line(w * 0.7),
                  line(w * 0.55),
                  line(w * 0.62),
                  const Spacer(),
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [line(w * 0.25, strong: true), line(w * 0.18, strong: true)]),
                ]),
              ),
              // The scanning light.
              Positioned(
                left: -6,
                right: -6,
                top: 6 + t * (h - 18),
                child: Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: c.accent,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [BoxShadow(color: c.accent.withValues(alpha: 0.8), blurRadius: 12, spreadRadius: 1)],
                  ),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
