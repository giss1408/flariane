import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/format.dart';
import '../core/theme.dart';

void showError(BuildContext context, Object e) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toApiException(e).message)));

void showInfo(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class ErrorView extends StatelessWidget {
  const ErrorView(this.error, {super.key, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 40),
            const SizedBox(height: 12),
            Text(toApiException(error).message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: onRetry, child: const Text('Réessayer')),
          ]),
        ),
      );
}

class AmountRow extends StatelessWidget {
  const AmountRow(this.label, this.amount, {super.key, this.bold = false});

  final String label;
  final int amount;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.w800, fontSize: 18) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(fcfa(amount), style: style)]),
    );
  }
}

/// Vertical order tracker: past steps checked, current bold and coloured, future greyed.
class OrderStepper extends StatelessWidget {
  const OrderStepper({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final current = stepIndex(status);
    return Column(children: [
      for (final (i, (_, label)) in steps.indexed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(
              i < current ? Icons.check_circle_rounded : (i == current ? Icons.radio_button_checked : Icons.radio_button_off),
              color: i <= current ? context.pal.accent : context.pal.muted.withOpacity(0.5),
              semanticLabel: i < current ? 'terminé' : (i == current ? 'en cours' : 'à venir'),
            ),
            const SizedBox(width: 12),
            Text(label,
                style: TextStyle(
                  fontWeight: i == current ? FontWeight.w700 : FontWeight.w400,
                  color: i > current ? context.pal.muted : null,
                )),
          ]),
        ),
    ]);
  }
}
