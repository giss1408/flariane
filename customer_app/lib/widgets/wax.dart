import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Wax-print inspired pattern (concentric "eyes" and petal rings, as on Ivorian pagne),
/// painted on a bissap→plum background. The one bold visual of the app.
class WaxPainter extends CustomPainter {
  WaxPainter({this.seed = 3});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size;
    final rect = Offset.zero & s;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFD81B60), AppColors.primary, Color(0xFF5B1048)],
        ).createShader(rect),
    );
    final rnd = math.Random(seed);
    final cell = s.height / 2.2;
    for (var y = -cell / 2; y < s.height + cell; y += cell) {
      for (var x = -cell / 2; x < s.width + cell; x += cell * 1.1) {
        final shift = ((y / cell).round().isOdd) ? cell * 0.55 : 0.0;
        _motif(canvas, Offset(x + shift, y), cell * 0.42, rnd.nextInt(3));
      }
    }
  }

  void _motif(Canvas c, Offset o, double r, int kind) {
    final mango = Paint()..color = AppColors.mango.withOpacity(0.85);
    final blush = Paint()..color = const Color(0xFFFFD6E5).withOpacity(0.22);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.12
      ..color = AppColors.mango.withOpacity(0.5);
    switch (kind) {
      case 0: // eye: rings + dot
        c.drawCircle(o, r, blush);
        c.drawCircle(o, r * 0.7, ring);
        c.drawCircle(o, r * 0.28, mango);
      case 1: // petal ring
        for (var i = 0; i < 8; i++) {
          final a = i * math.pi / 4;
          c.drawCircle(o + Offset(math.cos(a), math.sin(a)) * r * 0.65, r * 0.2, blush);
        }
        c.drawCircle(o, r * 0.22, Paint()..color = AppColors.mint.withOpacity(0.8));
      default: // half moon
        c.drawArc(Rect.fromCircle(center: o, radius: r * 0.8), math.pi, math.pi, true, blush);
        c.drawArc(Rect.fromCircle(center: o, radius: r * 0.45), math.pi, math.pi, true, mango);
    }
  }

  @override
  bool shouldRepaint(covariant WaxPainter oldDelegate) => oldDelegate.seed != seed;
}
