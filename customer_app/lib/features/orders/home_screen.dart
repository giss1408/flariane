import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';
import '../account/account_screen.dart';
import 'new_order_screen.dart';
import 'order_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A share from the SHEIN app opens the new-order screen directly.
    ref.listen(sharedTextProvider, (_, text) {
      if (text != null) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewOrderScreen()));
      }
    });
    final orders = ref.watch(ordersProvider);
    return Scaffold(
      appBar: FlarianeHeader(
        subtitle: 'Mes commandes',
        showBack: false,
        actions: [
          IconButton(
            tooltip: 'Compte',
            icon: const Icon(Icons.person_outline_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(ordersProvider.future),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            icon: const Icon(Icons.add_shopping_cart_rounded),
            label: const Text('Envoyer mon panier SHEIN'),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewOrderScreen()));
              ref.invalidate(ordersProvider);
            },
          ),
          const SizedBox(height: 12),
          const _HowTo(),
          const SizedBox(height: 20),
          ...orders.when(
            loading: () => [const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))],
            error: (e, _) => [ErrorView(e, onRetry: () => ref.invalidate(ordersProvider))],
            data: (list) => list.isEmpty
                ? [const Center(child: Text('Aucune commande pour le moment.'))]
                : [
                    for (final o in list)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Card(
                          child: ListTile(
                            title: Text(o.ref, style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: Text('${statusLabels[o.status] ?? o.status} · ${date(o.createdAt)}'),
                            trailing: Text(fcfa(o.totalXof)),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderRef: o.ref)));
                              ref.invalidate(ordersProvider);
                            },
                          ),
                        ),
                      ),
                  ],
          ),
        ]),
      ),
    );
  }
}

class _HowTo extends StatelessWidget {
  const _HowTo();

  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Comment ça marche', style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 8),
            Text('1. Remplissez votre panier dans l’app SHEIN'),
            Text('2. Panier → Partager → Flariane (ou copiez le lien)'),
            Text('3. Recevez votre devis en FCFA, payez avec Wave'),
            Text('4. Retirez votre colis à Abidjan'),
          ]),
        ),
      );
}

