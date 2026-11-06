import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Flariane mark in the admin colours: the same "F" with a gold spark as the customer app, on a teal tile
/// (so the two apps are told apart at a glance on a phone).
class FlarianeLogo extends StatelessWidget {
  const FlarianeLogo({super.key, this.size = 72, this.withWordmark = false});

  final double size;
  final bool withWordmark;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox.square(
        dimension: size,
        child: const CustomPaint(painter: FlarianeMarkPainter()));
    if (!withWordmark) return Semantics(label: 'Flariane Admin', child: mark);
    return Semantics(
      label: 'Flariane Admin',
      child: ExcludeSemantics(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          mark,
          SizedBox(height: size * 0.16),
          Text('Flariane',
              style: TextStyle(
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.w800,
                  color: Theme.of(context).colorScheme.primary,
                  height: 1)),
          SizedBox(height: size * 0.04),
          Text('ADMIN',
              style: TextStyle(
                  fontSize: size * 0.15,
                  fontWeight: FontWeight.w700,
                  letterSpacing: size * 0.05,
                  color: AppColors.muted)),
        ]),
      ),
    );
  }
}

/// Draws the mark. `tile: false` draws only the F and the spark (launcher foreground);
/// `fullBleed: true` fills the whole square with no rounded corners or shadow (iOS icon).
class FlarianeMarkPainter extends CustomPainter {
  const FlarianeMarkPainter(
      {this.tile = true, this.fullBleed = false, this.shadow = true});

  final bool tile;
  final bool fullBleed;
  final bool shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    if (tile) {
      final shape = RRect.fromRectAndRadius(
          Offset.zero & size, Radius.circular(fullBleed ? 0 : w * 0.28));
      if (shadow && !fullBleed) {
        canvas.drawShadow(Path()..addRRect(shape), const Color(0xFF0F5F5C), w * 0.06, false);
      }
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF063B39), Color(0xFF0F5F5C), Color(0xFF2FA39A)],
          ).createShader(Offset.zero & size),
      );
      // Sheen across the top-left.
      canvas.save();
      canvas.clipRRect(shape);
      canvas.drawCircle(Offset(w * 0.1, w * 0.05), w * 0.7,
          Paint()..color = Colors.white.withOpacity(0.08));
      canvas.restore();
    }

    // The "F": a stem and two bars with rounded caps, slightly italic.
    canvas.save();
    canvas.translate(w * 0.5, w * 0.5);
    canvas.transform((Matrix4.identity()..setEntry(0, 1, -0.12)).storage);
    canvas.translate(-w * 0.5, -w * 0.5);
    final white = Paint()
      ..color = Colors.white
      ..strokeCap = StrokeCap.round
      ..strokeWidth = w * 0.13
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
        Offset(w * 0.36, w * 0.27), Offset(w * 0.36, w * 0.75), white); // stem
    canvas.drawLine(Offset(w * 0.36, w * 0.27), Offset(w * 0.64, w * 0.27),
        white); // top bar
    canvas.drawLine(Offset(w * 0.36, w * 0.5), Offset(w * 0.56, w * 0.5),
        white..strokeWidth = w * 0.11); // middle bar
    canvas.restore();

    // Gold spark.
    final c = Offset(w * 0.78, w * 0.24);
    final spark = Path();
    for (var i = 0; i < 8; i++) {
      final r = i.isEven ? w * 0.085 : w * 0.03;
      final a = -math.pi / 2 + i * math.pi / 4;
      final p = c + Offset(math.cos(a) * r, math.sin(a) * r);
      i == 0 ? spark.moveTo(p.dx, p.dy) : spark.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(spark..close(), Paint()..color = const Color(0xFFFFB020));
  }

  @override
  bool shouldRepaint(covariant FlarianeMarkPainter oldDelegate) =>
      oldDelegate.tile != tile ||
      oldDelegate.fullBleed != fullBleed ||
      oldDelegate.shadow != shadow;
}
