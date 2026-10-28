import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/models.dart';
import 'departure_ticket.dart';

/// "Plus que 3 jours", or null for an offer without an end date.
String? offerCountdown(Offer offer, DateTime now) {
  final end = offer.endsAt;
  if (end == null) return null;
  return switch (daysUntil(end, now)) {
    < 0 => null,
    0 => 'Se termine aujourd’hui',
    1 => 'Plus qu’un jour',
    final d => 'Plus que $d jours',
  };
}

/// A promotion that is meant to be noticed: a warm gradient with a light sweep, a slow glow and a
/// pulsing "OFFRE" tag. The pulse takes 2.4 s, far below flicker rates, and stops completely when
/// the phone asks to remove animations.
class OfferBanner extends StatefulWidget {
  const OfferBanner({super.key, required this.offer, this.onTap});

  final Offer offer;

  /// Opens the order flow: the offer is only useful if one tap gets her to a new cart.
  final VoidCallback? onTap;

  @override
  State<OfferBanner> createState() => _OfferBannerState();
}

class _OfferBannerState extends State<OfferBanner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  // White text must stay readable on both ends of the gradient (contrast ≥ 4.5:1).
  static const _from = Color(0xFF9D174D);
  static const _to = Color(0xFFC2410C);
  static const _glow = Color(0xFFFB923C);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final offer = widget.offer;
    final countdown = offerCountdown(offer, DateTime.now());
    return Semantics(
      button: widget.onTap != null,
      label: 'Offre : ${offer.title}. ${offer.message}${countdown == null ? '' : '. $countdown'}',
      excludeSemantics: true,
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;
          final pulse = 0.5 - 0.5 * math.cos(2 * math.pi * t); // 0 → 1 → 0, smooth
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: const LinearGradient(colors: [_from, _to], begin: Alignment.topLeft, end: Alignment.bottomRight),
              boxShadow: [
                BoxShadow(color: _glow.withOpacity(0.25 + 0.45 * pulse), blurRadius: 10 + 16 * pulse, spreadRadius: 1 + 2 * pulse),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Stack(children: [
                Positioned.fill(child: IgnorePointer(child: _Sweep(progress: t))),
                Material(
                  type: MaterialType.transparency,
                  child: InkWell(
                    onTap: widget.onTap,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Transform.scale(
                          scale: 1 + 0.08 * pulse,
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(color: AppColors.mango, borderRadius: BorderRadius.circular(20)),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.local_fire_department_rounded, size: 16, color: Color(0xFF3B0A1F)),
                              SizedBox(width: 4),
                              Text('OFFRE', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1, color: Color(0xFF3B0A1F))),
                            ]),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(offer.title, style: display(24, color: Colors.white)),
                        if (offer.message.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(offer.message, style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.3)),
                        ],
                        if (countdown != null) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            const Icon(Icons.timer_outlined, size: 16, color: Colors.white),
                            const SizedBox(width: 6),
                            Text(countdown, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 14)),
                          ]),
                        ],
                        if (widget.onTap != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
                            child: const Row(mainAxisSize: MainAxisSize.min, children: [
                              Text('J’en profite', style: TextStyle(fontWeight: FontWeight.w800, color: _to)),
                              SizedBox(width: 6),
                              Icon(Icons.arrow_forward_rounded, size: 18, color: _to),
                            ]),
                          ),
                        ],
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          );
        },
      ),
    );
  }
}

/// A soft diagonal highlight crossing the card once per cycle.
class _Sweep extends StatelessWidget {
  const _Sweep({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          return Transform.translate(
            offset: Offset(-0.4 * w + 1.4 * w * progress, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Transform(
                transform: Matrix4.skewX(-0.35),
                child: Container(
                  width: w * 0.22,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [Colors.white.withOpacity(0), Colors.white.withOpacity(0.28), Colors.white.withOpacity(0)]),
                  ),
                ),
              ),
            ),
          );
        },
      );
}
