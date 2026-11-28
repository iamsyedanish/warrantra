import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import 'plan_screens.dart' show proBenefits;

const _night = Color(0xFF0D0A22);
const _deep = Color(0xFF241A5E);
const _violet = Color(0xFF8A78EA);
const _gold = Color(0xFFF2C46D);

/// The moment Pro is bought: a lock opens, the Pro badge lands, and what was
/// just unlocked is listed. Returns when the person carries on.
Future<void> showProUnlocked(BuildContext context, {String? period}) {
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 350),
    reverseTransitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (_, _, _) => ProUnlockedScreen(period: period),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  ));
}

class ProUnlockedScreen extends StatefulWidget {
  const ProUnlockedScreen({super.key, this.period});
  final String? period;
  @override
  State<ProUnlockedScreen> createState() => _ProUnlockedScreenState();
}

class _ProUnlockedScreenState extends State<ProUnlockedScreen> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  late final AnimationController _ambient = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();
  final _sparks = List.generate(28, (i) {
    final r = math.Random(i * 7 + 3);
    return (angle: (i / 28) * 2 * math.pi + r.nextDouble() * 0.3, reach: 0.55 + r.nextDouble() * 0.45, size: 1.5 + r.nextDouble() * 2.5, gold: r.nextBool());
  });

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) {
        _intro.value = 1;
        return;
      }
      _intro.forward();
      Future.delayed(const Duration(milliseconds: 250), HapticFeedback.selectionClick);
      Future.delayed(const Duration(milliseconds: 1000), HapticFeedback.heavyImpact);
    });
  }

  @override
  void dispose() {
    _intro.dispose();
    _ambient.dispose();
    super.dispose();
  }

  /// Progress of [_intro] within [a]..[b], eased.
  double _seg(double a, double b, [Curve curve = Curves.easeOutCubic]) => curve.transform(((_intro.value - a) / (b - a)).clamp(0.0, 1.0));

  String get _planLine => switch (widget.period) {
        'annual' => 'Yearly plan, billed through Google Play. Manage or cancel any time in your Play account.',
        'monthly' => 'Monthly plan, billed through Google Play. Manage or cancel any time in your Play account.',
        _ => 'Billed through your store account. Manage or cancel any time there.',
      };

  @override
  Widget build(BuildContext context) {
    // Short screens list fewer, so the button stays in view.
    final unlocked = proBenefits.where((b) => !b.soon).take(MediaQuery.sizeOf(context).height < 760 ? 3 : 5).toList();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _night,
        body: AnimatedBuilder(
          animation: Listenable.merge([_intro, _ambient]),
          builder: (context, _) {
            final open = _seg(0.06, 0.28, Curves.easeInOutBack);
            final lockOut = _seg(0.28, 0.38, Curves.easeIn);
            final badgeIn = _seg(0.30, 0.52, Curves.elasticOut);
            final burst = _seg(0.30, 0.70, Curves.easeOutQuart);
            final glow = _seg(0.30, 0.60);
            final title = _seg(0.46, 0.60);
            final button = _seg(0.86, 1.0);
            return Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: const Alignment(0, -0.45), radius: 1.1, colors: [Color.lerp(_night, _deep, glow)!, _night]),
              ),
              child: SafeArea(
                child: LayoutBuilder(builder: (context, box) {
                  final stage = math.min(240.0, box.maxHeight * 0.34).clamp(150.0, 240.0);
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: box.maxHeight),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 440),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              SizedBox(
                                width: stage * 1.4,
                                height: stage,
                                child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
                                  // Slow light rays behind the badge.
                                  Opacity(
                                    opacity: glow * 0.9,
                                    child: Transform.rotate(angle: _ambient.value * 2 * math.pi, child: CustomPaint(size: Size.square(stage * 1.4), painter: _RaysPainter())),
                                  ),
                                  CustomPaint(size: Size.square(stage * 1.4), painter: _BurstPainter(burst, _sparks)),
                                  if (lockOut < 1)
                                    Opacity(
                                      opacity: 1 - lockOut,
                                      child: Transform.scale(scale: 1 - 0.35 * lockOut, child: CustomPaint(size: Size.square(stage * 0.55), painter: _LockPainter(open))),
                                    ),
                                  if (badgeIn > 0) Transform.scale(scale: badgeIn, child: _Badge(size: stage * 0.5, shimmer: _ambient.value)),
                                ]),
                              ),
                              const SizedBox(height: 8),
                              _Rise(
                                t: title,
                                child: Column(children: [
                                  const Text('PRO UNLOCKED',
                                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, letterSpacing: 3.2, color: _gold)),
                                  const SizedBox(height: 10),
                                  const Text('Everything in Warrantra\nis now open to you',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 26, height: 1.2, fontWeight: FontWeight.w700, color: Colors.white)),
                                  const SizedBox(height: 10),
                                  Text(_planLine,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(fontSize: 13.5, height: 1.45, color: Colors.white.withValues(alpha: 0.62))),
                                ]),
                              ),
                              const SizedBox(height: 22),
                              for (var i = 0; i < unlocked.length; i++)
                                _Rise(
                                  t: _seg(0.58 + i * 0.055, 0.70 + i * 0.055),
                                  child: _UnlockRow(icon: unlocked[i].icon, text: unlocked[i].title),
                                ),
                              const SizedBox(height: 22),
                              _Rise(
                                t: button,
                                child: SizedBox(
                                  width: double.infinity,
                                  height: 54,
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor: Colors.white,
                                      foregroundColor: _night,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                    ),
                                    onPressed: button > 0.5 ? () => Navigator.of(context).pop() : null,
                                    child: const Text('Start using Pro'),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Fades and lifts a child in as [t] goes 0 → 1.
class _Rise extends StatelessWidget {
  const _Rise({required this.t, required this.child});
  final double t;
  final Widget child;
  @override
  Widget build(BuildContext context) => Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child));
}

class _UnlockRow extends StatelessWidget {
  const _UnlockRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(children: [
        Icon(icon, size: 20, color: _violet),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: Colors.white))),
        const Icon(PhosphorIconsFill.lockKeyOpen, size: 17, color: _gold),
      ]),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.size, required this.shimmer});
  final double size, shimmer;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.3),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF9F8CF7), Color(0xFF4E33C2)]),
        border: Border.all(color: _gold.withValues(alpha: 0.9), width: 2),
        boxShadow: [BoxShadow(color: _violet.withValues(alpha: 0.55), blurRadius: size * 0.45, spreadRadius: 2)],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.3),
        child: Stack(alignment: Alignment.center, children: [
          // A glint that passes across the badge now and then.
          Positioned.fill(
            child: FractionalTranslation(
              translation: Offset(-1.5 + ((shimmer * 4) % 1) * 3, 0),
              child: Transform.rotate(
                angle: 0.5,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.28), Colors.white.withValues(alpha: 0)]),
                  ),
                ),
              ),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(PhosphorIconsFill.crownSimple, color: Colors.white, size: size * 0.42),
            Text('PRO', style: TextStyle(color: _gold, fontWeight: FontWeight.w800, letterSpacing: size * 0.04, fontSize: size * 0.15)),
          ]),
        ]),
      ),
    );
  }
}

/// A padlock whose shackle swings open as [open] goes 0 → 1.
class _LockPainter extends CustomPainter {
  _LockPainter(this.open);
  final double open;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    // Shackle.
    final shackle = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.09
      ..strokeCap = StrokeCap.round
      ..shader = const LinearGradient(colors: [Color(0xFFE9E6F7), Color(0xFFA7A1C9)]).createShader(Offset.zero & size);
    final pivot = Offset(s * 0.68, s * 0.47);
    canvas.save();
    canvas.translate(0, -s * 0.12 * open);
    canvas.translate(pivot.dx, pivot.dy);
    canvas.rotate(-0.6 * open);
    canvas.translate(-pivot.dx, -pivot.dy);
    final path = Path()
      ..moveTo(s * 0.32, s * 0.47)
      ..lineTo(s * 0.32, s * 0.3)
      ..arcToPoint(Offset(s * 0.68, s * 0.3), radius: Radius.circular(s * 0.18))
      ..lineTo(s * 0.68, s * 0.47);
    canvas.drawPath(path, shackle);
    canvas.restore();
    // Body.
    final body = RRect.fromRectAndRadius(Rect.fromLTWH(s * 0.18, s * 0.44, s * 0.64, s * 0.48), Radius.circular(s * 0.1));
    canvas.drawRRect(body, Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF6D58C), Color(0xFFC9932F)]).createShader(body.outerRect));
    // Keyhole.
    final key = Paint()..color = const Color(0xFF5A3D0E);
    canvas.drawCircle(Offset(s * 0.5, s * 0.63), s * 0.055, key);
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(s * 0.5, s * 0.72), width: s * 0.045, height: s * 0.12), Radius.circular(s * 0.02)), key);
  }

  @override
  bool shouldRepaint(covariant _LockPainter old) => old.open != open;
}

/// A ring and sparks thrown out from the centre as [t] goes 0 → 1.
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.t, this.sparks);
  final double t;
  final List<({double angle, double reach, double size, bool gold})> sparks;
  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    final max = size.shortestSide / 2;
    final fade = 1 - t;
    canvas.drawCircle(
      c,
      max * (0.25 + 0.7 * t),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5 * fade + 0.5
        ..color = _gold.withValues(alpha: 0.7 * fade),
    );
    for (final s in sparks) {
      final d = max * (0.22 + s.reach * 0.75 * t);
      final p = c + Offset(math.cos(s.angle), math.sin(s.angle)) * d;
      canvas.drawCircle(p, s.size * (0.4 + fade), Paint()..color = (s.gold ? _gold : Colors.white).withValues(alpha: fade));
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) => old.t != t;
}

/// Soft light rays radiating from the centre.
class _RaysPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final paint = Paint()..shader = RadialGradient(colors: [_violet.withValues(alpha: 0.35), _violet.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: c, radius: r));
    const n = 12;
    for (var i = 0; i < n; i++) {
      final a = i * 2 * math.pi / n;
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + r * math.cos(a - 0.09), c.dy + r * math.sin(a - 0.09))
        ..lineTo(c.dx + r * math.cos(a + 0.09), c.dy + r * math.sin(a + 0.09))
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}
