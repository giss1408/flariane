import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/attention.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import 'inbox_screen.dart';

/// Not filtered by store: a payment waiting for confirmation must never be hidden.
final paymentsToConfirmProvider =
    FutureProvider.autoDispose<List<OrderSummary>>((ref) => ref.watch(adminApiProvider).inbox('to_confirm'));

/// Customers who say they paid and sent the screenshot: check the money arrived, then confirm.
class PaymentsToConfirmBanner extends ConsumerWidget {
  const PaymentsToConfirmBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(attentionProvider).valueOrNull?.counts['payments_to_confirm'] ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: const Icon(Icons.payments_rounded, color: AppColors.warning),
          title: Text('$count paiement${count > 1 ? 's' : ''} à confirmer', style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('Vérifie ton Wave / Orange / Moov, puis confirme'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PaymentsToConfirmScreen()));
            ref.invalidate(attentionProvider);
          },
        ),
      ),
    );
  }
}

class PaymentsToConfirmScreen extends ConsumerWidget {
  const PaymentsToConfirmScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(paymentsToConfirmProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Paiements à confirmer')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(paymentsToConfirmProvider.future),
        child: orders.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [ErrorView(e, onRetry: () => ref.invalidate(paymentsToConfirmProvider))]),
          data: (list) => list.isEmpty
              ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Aucun paiement à confirmer.'))])
              : ListView(padding: const EdgeInsets.all(12), children: [
                  const WarningBox('Ouvre la commande, regarde la capture, vérifie le montant dans ton application, puis touche « Confirmer le paiement ».'),
                  const SizedBox(height: 10),
                  for (final o in list)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: OrderTile(order: o, onReturn: () => ref.invalidate(paymentsToConfirmProvider)),
                    ),
                ]),
        ),
      ),
    );
  }
}
