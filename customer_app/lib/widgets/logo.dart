import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Flariane mark: a stylised "F" on a deep-teal → gold gradient tile, with a small
/// gold "spark" at the end of the top bar (the parcel arriving).
class FlarianeLogo extends StatelessWidget {
  const FlarianeLogo({super.key, this.size = 72, this.withWordmark = false});

  final double size;
  final bool withWordmark;

  @override
  Widget build(BuildContext context) {
    final mark = SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _MarkPainter(), child: const SizedBox.expand()),
    );
    if (!withWordmark) return Semantics(label: 'Flariane', child: mark);
    return Semantics(
      label: 'Flariane',
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        mark,
        SizedBox(height: size * 0.18),
        ShaderMask(
          shaderCallback: (r) => const LinearGradient(colors: [Color(0xFF0F5F5C), Color(0xFF2A9D8F), Color(0xFFC9A227)]).createShader(r),
          child: Text(
            'Flariane',
            style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: Colors.white),
          ),
        ),
      ]),
    );
  }
}

class _MarkPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final tile = RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(w * 0.28));

    // Tile: diagonal teal gradient with a soft glow.
    canvas.drawShadow(Path()..addRRect(tile), const Color(0xFF0F5F5C), w * 0.06, false);
    canvas.drawRRect(
      tile,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B4F4C), Color(0xFF14807A), Color(0xFF2A9D8F)],
        ).createShader(Offset.zero & s),
    );
    // Sheen across the top-left.
    canvas.save();
    canvas.clipRRect(tile);
    canvas.drawCircle(
      Offset(w * 0.1, w * 0.05),
      w * 0.7,
      Paint()..color = Colors.white.withOpacity(0.08),
    );
    canvas.restore();

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
    canvas.drawLine(Offset(w * 0.36, w * 0.27), Offset(w * 0.36, w * 0.75), white); // stem
    canvas.drawLine(Offset(w * 0.36, w * 0.27), Offset(w * 0.64, w * 0.27), white); // top bar
    canvas.drawLine(Offset(w * 0.36, w * 0.5), Offset(w * 0.56, w * 0.5), white..strokeWidth = w * 0.11); // middle bar
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
    canvas.drawPath(spark..close(), Paint()..color = const Color(0xFFE9C46A));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Brand header used on every screen: logo + "Flariane" wordmark, with the page name below.
class FlarianeHeader extends StatelessWidget implements PreferredSizeWidget {
  const FlarianeHeader({super.key, this.subtitle, this.actions, this.showBack = true});

  final String? subtitle;
  final List<Widget>? actions;
  final bool showBack;

  @override
  Size get preferredSize => const Size.fromHeight(70); // toolbar 68 + gradient rule 2

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return AppBar(
      toolbarHeight: 68,
      automaticallyImplyLeading: showBack,
      titleSpacing: showBack ? 0 : 16,
      title: Row(children: [
        const FlarianeLogo(size: 38),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            ShaderMask(
              shaderCallback: (r) => const LinearGradient(colors: [Color(0xFF0F5F5C), Color(0xFF2A9D8F), Color(0xFFC9A227)]).createShader(r),
              child: const Text('Flariane', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
            if (subtitle != null)
              Text(subtitle!, style: TextStyle(fontSize: 13, color: muted), overflow: TextOverflow.ellipsis),
          ]),
        ),
      ]),
      actions: actions,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(2),
        child: Container(
          height: 2,
          decoration: const BoxDecoration(
            gradient: LinearGradient(colors: [Color(0xFF0F5F5C), Color(0xFF2A9D8F), Color(0xFFE9C46A)]),
          ),
        ),
      ),
    );
  }
}
