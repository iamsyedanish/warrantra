import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Pip, the in-app guide: a small purple shield (from the Warrantra logo) with a
/// friendly face. Blinks now and then; drawn in code so it scales cleanly.
class GuideAvatar extends StatefulWidget {
  const GuideAvatar({super.key, this.size = 56, this.animate = true});
  final double size;
  final bool animate;

  static const name = 'Pip';

  @override
  State<GuideAvatar> createState() => _GuideAvatarState();
}

class _GuideAvatarState extends State<GuideAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void initState() {
    super.initState();
    if (widget.animate) _blink.repeat();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${GuideAvatar.name}, your guide',
      image: true,
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: _blink,
          builder: (_, _) {
            // Eyes close briefly near the end of each cycle.
            final t = _blink.value;
            final open = t > 0.94 ? (1 - math.sin((t - 0.94) / 0.06 * math.pi)).clamp(0.08, 1.0) : 1.0;
            return CustomPaint(painter: _PipPainter(eyeOpen: open.toDouble()));
          },
        ),
      ),
    );
  }
}

class _PipPainter extends CustomPainter {
  _PipPainter({required this.eyeOpen});
  final double eyeOpen;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    // Shield body.
    final shield = Path()
      ..moveTo(w * 0.5, h * 0.05)
      ..lineTo(w * 0.88, h * 0.19)
      ..lineTo(w * 0.88, h * 0.47)
      ..cubicTo(w * 0.88, h * 0.72, w * 0.71, h * 0.89, w * 0.5, h * 0.96)
      ..cubicTo(w * 0.29, h * 0.89, w * 0.12, h * 0.72, w * 0.12, h * 0.47)
      ..lineTo(w * 0.12, h * 0.19)
      ..close();
    canvas.drawShadow(shield, const Color(0xFF2B2741), w * 0.04, false);
    canvas.drawPath(
      shield,
      Paint()
        ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF9A8AF0), Color(0xFF5B49C2)])
            .createShader(Offset.zero & size),
    );
    // Lighter inner panel, like the logo.
    final inner = Path()
      ..moveTo(w * 0.5, h * 0.14)
      ..lineTo(w * 0.79, h * 0.25)
      ..lineTo(w * 0.79, h * 0.47)
      ..cubicTo(w * 0.79, h * 0.66, w * 0.66, h * 0.80, w * 0.5, h * 0.86)
      ..cubicTo(w * 0.34, h * 0.80, w * 0.21, h * 0.66, w * 0.21, h * 0.47)
      ..lineTo(w * 0.21, h * 0.25)
      ..close();
    canvas.drawPath(inner, Paint()..color = Colors.white.withValues(alpha: 0.16));

    // Eyes.
    final white = Paint()..color = Colors.white;
    final pupil = Paint()..color = const Color(0xFF231C4A);
    for (final x in [0.38, 0.62]) {
      final c = Offset(w * x, h * 0.44);
      canvas.save();
      canvas.translate(c.dx, c.dy);
      canvas.scale(1, eyeOpen);
      canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: w * 0.15, height: h * 0.17), white);
      canvas.drawCircle(Offset(w * 0.012, h * 0.018), w * 0.045, pupil);
      canvas.drawCircle(Offset(-w * 0.006, -h * 0.012), w * 0.016, white);
      canvas.restore();
    }
    // Cheeks.
    final blush = Paint()..color = const Color(0xFFFFA6C9).withValues(alpha: 0.55);
    canvas.drawCircle(Offset(w * 0.28, h * 0.58), w * 0.04, blush);
    canvas.drawCircle(Offset(w * 0.72, h * 0.58), w * 0.04, blush);
    // Smile.
    canvas.drawArc(
      Rect.fromCenter(center: Offset(w * 0.5, h * 0.57), width: w * 0.2, height: h * 0.14),
      0.15 * math.pi,
      0.7 * math.pi,
      false,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * 0.035
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _PipPainter old) => old.eyeOpen != eyeOpen;
}
