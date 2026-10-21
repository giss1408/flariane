import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/theme.dart';

/// Days left until [departure], counted in calendar days from [today].
int daysUntil(DateTime departure, DateTime today) =>
    DateTime(departure.year, departure.month, departure.day)
        .difference(DateTime(today.year, today.month, today.day))
        .inDays;

String countdownLabel(int days) => switch (days) {
      0 => 'C’est aujourd’hui',
      1 => 'Demain',
      _ => 'J-$days',
    };

/// Boarding-pass style card: mango stub with the countdown, perforation, then the date.
class DepartureTicket extends StatelessWidget {
  const DepartureTicket(
      {super.key, required this.departure, required this.onTap, this.today});

  final DateTime departure;
  final VoidCallback onTap;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final days = daysUntil(departure, today ?? DateTime.now());
    final urgent = days <= 3;
    return Semantics(
      button: true,
      label:
          'Prochain départ le ${DateFormat('d MMMM', 'fr').format(departure)}, commander',
      child: GestureDetector(
        onTap: onTap,
        child: ClipPath(
          clipper: _TicketClipper(stubWidth: 96),
          child: Container(
            constraints: const BoxConstraints(minHeight: 112),
            color: Colors.white,
            child: IntrinsicHeight(
              child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 96,
                      color: urgent ? AppColors.primary : AppColors.mango,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        countdownLabel(days),
                        textAlign: TextAlign.center,
                        style: display(days > 1 ? 30 : 18,
                            color: urgent ? Colors.white : AppColors.plum),
                      ),
                    ),
                    CustomPaint(
                        size: const Size(2, double.infinity),
                        painter: _Perforation()),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Row(children: [
                                Icon(Icons.flight_takeoff_rounded,
                                    size: 18, color: AppColors.primary),
                                SizedBox(width: 6),
                                Flexible(
                                    child: Text('Prochain départ',
                                        style: TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 13))),
                              ]),
                              const SizedBox(height: 2),
                              Text(DateFormat('d MMMM', 'fr').format(departure),
                                  style: display(24)),
                              const SizedBox(height: 2),
                              Text(
                                urgent
                                    ? 'Dernière chance, commande vite !'
                                    : 'Commande vite pour être dans ce colis !',
                                softWrap: true,
                                style: TextStyle(
                                    color: urgent
                                        ? AppColors.primary
                                        : AppColors.plum,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13.5),
                              ),
                            ]),
                      ),
                    ),
                    const Padding(
                        padding: EdgeInsets.only(right: 10),
                        child: Icon(Icons.chevron_right_rounded,
                            color: AppColors.muted)),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rounded ticket with two half-circle notches where stub and body meet.
class _TicketClipper extends CustomClipper<Path> {
  _TicketClipper({required this.stubWidth});

  final double stubWidth;

  @override
  Path getClip(Size size) {
    const r = 22.0, notch = 10.0;
    final body = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(r)));
    final notches = Path()
      ..addOval(
          Rect.fromCircle(center: Offset(stubWidth + 1, 0), radius: notch))
      ..addOval(Rect.fromCircle(
          center: Offset(stubWidth + 1, size.height), radius: notch));
    return Path.combine(PathOperation.difference, body, notches);
  }

  @override
  bool shouldReclip(covariant _TicketClipper oldClipper) =>
      oldClipper.stubWidth != stubWidth;
}

class _Perforation extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = AppColors.lilac
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (var y = 14.0; y < size.height - 12; y += 9) {
      canvas.drawLine(Offset(1, y), Offset(1, y + 4), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
