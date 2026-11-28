import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/tokens.dart';
import '../../core/widgets/buttons.dart';
import 'guide_avatar.dart';

/// Marks a real part of the UI so the guide can spotlight it by [id].
class GuideTarget extends StatefulWidget {
  const GuideTarget({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  static final _mounted = <String, List<BuildContext>>{};

  /// The most recently mounted, visible element with this id.
  static BuildContext? find(String id) {
    final list = _mounted[id];
    if (list == null) return null;
    for (final c in list.reversed) {
      if (!c.mounted) continue;
      final box = c.findRenderObject();
      if (box is RenderBox && box.attached && box.hasSize) return c;
    }
    return null;
  }

  @override
  State<GuideTarget> createState() => _GuideTargetState();
}

class _GuideTargetState extends State<GuideTarget> {
  @override
  void initState() {
    super.initState();
    GuideTarget._mounted.putIfAbsent(widget.id, () => []).add(context);
  }

  @override
  void dispose() {
    GuideTarget._mounted[widget.id]?.remove(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// One step of a walkthrough: spotlight [target] (if present) and explain it.
class GuideStep {
  const GuideStep(this.text, {this.target, this.title});
  final String text;
  final String? target;
  final String? title;
}

/// Runs a step-by-step walkthrough over whatever screen is showing.
class GuideSpotlight {
  static OverlayEntry? _entry;

  static bool get running => _entry != null;

  /// Shows [steps] one at a time; completes when finished or skipped.
  /// Pass [overlay] when [context] sits above the app's overlay (e.g. the
  /// navigator's own context).
  static Future<void> run(
    BuildContext context,
    List<GuideStep> steps, {
    String? heading,
    OverlayState? overlay,
  }) async {
    if (steps.isEmpty) return;
    stop();
    overlay ??= Overlay.of(context, rootOverlay: true);
    final done = Completer<void>();
    _entry = OverlayEntry(
      builder: (_) => _SpotlightRunner(
        steps: steps,
        heading: heading,
        onDone: () {
          stop();
          if (!done.isCompleted) done.complete();
        },
      ),
    );
    overlay.insert(_entry!);
    return done.future;
  }

  static void stop() {
    _entry?.remove();
    _entry = null;
  }
}

class _SpotlightRunner extends StatefulWidget {
  const _SpotlightRunner({
    required this.steps,
    required this.onDone,
    this.heading,
  });
  final List<GuideStep> steps;
  final VoidCallback onDone;
  final String? heading;
  @override
  State<_SpotlightRunner> createState() => _SpotlightRunnerState();
}

class _SpotlightRunnerState extends State<_SpotlightRunner>
    with TickerProviderStateMixin {
  int _i = 0;
  Rect? _from, _to;
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _show(0));
  }

  @override
  void dispose() {
    _zoom.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _show(int i) async {
    final step = widget.steps[i];
    Rect? target;
    final ctx = step.target == null ? null : GuideTarget.find(step.target!);
    if (ctx != null) {
      // Bring it on screen first (it may be further down a list).
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.35,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
      ).catchError((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      if (!mounted || !ctx.mounted) return;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box != null && box.attached && box.hasSize) {
        target = (box.localToGlobal(Offset.zero) & box.size).inflate(8);
      }
    }
    if (!mounted) return;
    final screen = MediaQuery.of(context).size;
    setState(() {
      _i = i;
      // Zoom in from the whole screen on the first step, then glide between parts.
      _from = _to ?? (Offset.zero & screen).inflate(40);
      _to = target;
    });
    _zoom.forward(from: 0);
  }

  void _next() {
    if (_i + 1 >= widget.steps.length) {
      widget.onDone();
    } else {
      _show(_i + 1);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    final screen = MediaQuery.of(context).size;
    final pad = MediaQuery.of(context).padding;
    final step = widget.steps[_i];
    final last = _i == widget.steps.length - 1;
    // Back ends the walkthrough (and leaves the screen underneath alone).
    return BackButtonListener(
      onBackButtonPressed: () async {
        widget.onDone();
        return true;
      },
      child: Material(
        type: MaterialType.transparency,
        child: AnimatedBuilder(
          animation: Listenable.merge([_zoom, _pulse]),
          builder: (context, _) {
            final t = Curves.easeOutCubic.transform(_zoom.value);
            final hole = _to == null ? null : Rect.lerp(_from ?? _to, _to, t);
            // Bubble goes below the target when it sits in the top half, above otherwise.
            final below = hole != null && hole.center.dy < screen.height * 0.5;
            final bubble = _Bubble(
              title: step.title ?? widget.heading,
              text: step.text,
              index: _i,
              count: widget.steps.length,
              last: last,
              onNext: _next,
              onSkip: widget.onDone,
            );
            return Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _next,
                    child: CustomPaint(
                      painter: _HolePainter(
                        hole: hole,
                        dim: Colors.black.withValues(
                          alpha: 0.66 * (_to == null ? 1 : math.max(t, 0.3)),
                        ),
                        pulse: _pulse.value,
                        ring: c.accent,
                      ),
                    ),
                  ),
                ),
                if (hole == null)
                  Positioned(
                    left: 20,
                    right: 20,
                    top: screen.height * 0.32,
                    child: Opacity(opacity: t, child: bubble),
                  )
                else if (below)
                  Positioned(
                    left: 16,
                    right: 16,
                    top: math.min(
                      hole.bottom + 16,
                      screen.height - pad.bottom - 220,
                    ),
                    child: Opacity(opacity: t, child: bubble),
                  )
                else
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: math.min(
                      screen.height - hole.top + 16,
                      screen.height - pad.top - 220,
                    ),
                    child: Opacity(opacity: t, child: bubble),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.text,
    required this.index,
    required this.count,
    required this.last,
    required this.onNext,
    required this.onSkip,
    this.title,
  });
  final String? title;
  final String text;
  final int index, count;
  final bool last;
  final VoidCallback onNext, onSkip;

  @override
  Widget build(BuildContext context) {
    final c = context.w;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.accentRing),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const GuideAvatar(size: 44),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(
                        title!,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                    if (title != null) const SizedBox(height: 4),
                    Text(
                      text,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: c.text,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Progress dots.
              for (var d = 0; d < count; d++)
                Container(
                  width: d == index ? 16 : 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    color: d == index ? c.accent : c.divider,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              const Spacer(),
              if (!last)
                WButton.ghost('Skip', expand: false, onPressed: onSkip),
              const SizedBox(width: 4),
              WButton(
                last ? 'Got it' : 'Next',
                expand: false,
                compact: true,
                onPressed: onNext,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HolePainter extends CustomPainter {
  _HolePainter({
    required this.hole,
    required this.dim,
    required this.pulse,
    required this.ring,
  });
  final Rect? hole;
  final Color dim, ring;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size);
    if (hole == null) {
      canvas.drawPath(path, Paint()..color = dim);
      return;
    }
    final rr = RRect.fromRectAndRadius(hole!, const Radius.circular(16));
    path.addRRect(rr);
    canvas.drawPath(path, Paint()..color = dim);
    // Solid focus ring plus a ring that grows and fades, drawing the eye.
    canvas.drawRRect(
      rr,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    final grow = 4 + pulse * 14;
    canvas.drawRRect(
      RRect.fromRectAndRadius(hole!.inflate(grow), Radius.circular(16 + grow)),
      Paint()
        ..color = ring.withValues(alpha: (1 - pulse) * 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _HolePainter old) =>
      old.hole != hole || old.pulse != pulse || old.dim != dim;
}
