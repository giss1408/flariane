import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';
import '../../widgets/wax.dart';
import '../account/account_screen.dart';
import 'new_order_screen.dart';
import 'order_screen.dart';

const _finished = {'PICKED_UP', 'CANCELLED', 'REFUNDED'};

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
    final name = ref.watch(meProvider).valueOrNull?.displayName?.split(' ').first;

    Future<void> newOrder() async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NewOrderScreen()));
      ref.invalidate(ordersProvider);
    }

    Future<void> open(String orderRef) async {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderRef: orderRef)));
      ref.invalidate(ordersProvider);
    }

    final list = orders.valueOrNull ?? const <OrderSummary>[];
    final active = list.where((o) => !_finished.contains(o.status)).toList();

    return Scaffold(
      appBar: FlarianeHeader(
        showBack: false,
        actions: [
          IconButton(
            tooltip: 'Mon compte',
            icon: const Icon(Icons.person_outline_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(ordersProvider.future),
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 32), children: [
          Text(name == null ? 'Salut 👋' : 'Salut $name 👋', style: display(28)),
          const SizedBox(height: 4),
          Text(
            active.isEmpty ? 'Qu’est-ce qui te fait envie cette semaine ?' : 'Voici où en sont tes colis.',
            style: const TextStyle(color: AppColors.muted, fontSize: 15),
          ),
          const SizedBox(height: 16),
          _WaxHero(onTap: newOrder),
          if (active.isNotEmpty) ...[
            const SizedBox(height: 24),
            Text(active.length == 1 ? 'Ta commande en cours' : 'Tes commandes en cours', style: display(20, weight: FontWeight.w700)),
            const SizedBox(height: 10),
            for (final o in active.take(3))
              Padding(padding: const EdgeInsets.only(bottom: 10), child: _ActiveOrderCard(order: o, onTap: () => open(o.ref))),
          ],
          const SizedBox(height: 24),
          Text('Comment ça marche', style: display(20, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          const _Steps(),
          const SizedBox(height: 20),
          const _TrustStrip(),
          const SizedBox(height: 24),
          Text('Mes commandes', style: display(20, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          ...orders.when(
            loading: () => [const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))],
            error: (e, _) => [ErrorView(e, onRetry: () => ref.invalidate(ordersProvider))],
            data: (all) => all.isEmpty
                ? [const _EmptyOrders()]
                : [for (final o in all) Padding(padding: const EdgeInsets.only(bottom: 8), child: _OrderRow(order: o, onTap: () => open(o.ref)))],
          ),
        ]),
      ),
    );
  }
}

class _WaxHero extends StatelessWidget {
  const _WaxHero({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: CustomPaint(
          painter: WaxPainter(),
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
            // A plum scrim on the left keeps the text readable over the pattern.
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [AppColors.plum.withOpacity(0.78), AppColors.plum.withOpacity(0.15)],
                stops: const [0.35, 1],
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Ton panier SHEIN,\nlivré à Abidjan', style: display(30, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('Devis en FCFA, paiement Wave, retrait près de chez toi',
                  style: TextStyle(color: Color(0xFFFFE3EE), fontSize: 14)),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: onTap,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.mango,
                  foregroundColor: AppColors.plum,
                  minimumSize: const Size(0, 50),
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                ),
                icon: const Icon(Icons.shopping_bag_rounded),
                label: const Text('Envoyer mon panier'),
              ),
            ]),
          ),
        ),
      );
}

/// Seven-segment progress bar (devis → retiré), lagoon-mint fill.
class ProgressSegments extends StatelessWidget {
  const ProgressSegments({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final current = stepIndex(status);
    return Row(children: [
      for (var i = 0; i < steps.length; i++)
        Expanded(
          child: Container(
            height: 6,
            margin: EdgeInsets.only(right: i == steps.length - 1 ? 0 : 4),
            decoration: BoxDecoration(
              color: i <= current ? AppColors.mint : AppColors.lilac,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
    ]);
  }
}

class _ActiveOrderCard extends StatelessWidget {
  const _ActiveOrderCard({required this.order, required this.onTap});

  final OrderSummary order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final nudge = switch (order.status) {
      'QUOTED' => 'Ton devis t’attend',
      'AWAITING_PAYMENT' => 'Paiement à finaliser',
      'READY_FOR_PICKUP' => 'Ton colis t’attend au point de retrait',
      _ => null,
    };
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(color: AppColors.lilac, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.inventory_2_rounded, color: AppColors.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(statusLabels[order.status] ?? order.status, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  Text(order.ref, style: const TextStyle(color: AppColors.muted)),
                ]),
              ),
              if (order.totalXof != null) Text(fcfa(order.totalXof), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 14),
            ProgressSegments(status: order.status),
            if (nudge != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(20)),
                child: Text(nudge, style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w700, fontSize: 13)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Steps extends StatelessWidget {
  const _Steps();

  static const _items = [
    (Icons.favorite_rounded, 'Remplis ton panier', 'dans l’app SHEIN, comme d’hab'),
    (Icons.ios_share_rounded, 'Partage-le', 'Panier, Partager, puis Flariane'),
    (Icons.receipt_long_rounded, 'Reçois ton devis', 'en FCFA, sur WhatsApp'),
    (Icons.local_mall_rounded, 'Récupère ton colis', 'payé avec Wave, retiré à Abidjan'),
  ];
  static const _tints = [AppColors.lilac, Color(0xFFFFE3EE), AppColors.warningBg, Color(0xFFD9F7EE)];

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 150,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _items.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (context, i) {
            final (icon, title, sub) = _items[i];
            return Container(
              width: 156,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: _tints[i], borderRadius: BorderRadius.circular(22)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('${i + 1}', style: display(26, color: AppColors.primary)),
                  const Spacer(),
                  Icon(icon, color: AppColors.plum),
                ]),
                const Spacer(),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(sub, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
              ]),
            );
          },
        ),
      );
}

class _TrustStrip extends StatelessWidget {
  const _TrustStrip();

  @override
  Widget build(BuildContext context) {
    Widget item(IconData icon, String text) => Expanded(
          child: Column(children: [
            Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.primary),
            ),
            const SizedBox(height: 6),
            Text(text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      decoration: BoxDecoration(color: AppColors.lilac.withOpacity(0.6), borderRadius: BorderRadius.circular(22)),
      child: Row(children: [
        item(Icons.account_balance_wallet_rounded, 'Paiement\nWave sécurisé'),
        item(Icons.chat_rounded, 'Suivi sur\nWhatsApp'),
        item(Icons.storefront_rounded, 'Retrait\nà Abidjan'),
      ]),
    );
  }
}

class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order, required this.onTap});

  final OrderSummary order;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = switch (order.status) {
      'PICKED_UP' => AppColors.success,
      'CANCELLED' || 'REFUNDED' || 'REFUND_PENDING' => AppColors.muted,
      'QUOTED' || 'AWAITING_PAYMENT' || 'READY_FOR_PICKUP' => AppColors.mango,
      _ => AppColors.primary,
    };
    return Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: CircleAvatar(radius: 6, backgroundColor: color),
        minLeadingWidth: 12,
        title: Text(order.ref, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text('${statusLabels[order.status] ?? order.status}, le ${date(order.createdAt)}'),
        trailing: Text(fcfa(order.totalXof), style: const TextStyle(fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _EmptyOrders extends StatelessWidget {
  const _EmptyOrders();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppColors.lilac, width: 2),
        ),
        child: const Column(children: [
          Icon(Icons.shopping_bag_outlined, size: 36, color: AppColors.primary),
          SizedBox(height: 8),
          Text('Pas encore de commande', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          SizedBox(height: 4),
          Text('Partage ton premier panier SHEIN pour recevoir ton devis.', textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ]),
      );
}
