import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/store_badge.dart';
import '../order/order_screen.dart';
import 'verifications_screen.dart';

class InboxTab {
  const InboxTab(this.key, this.label);

  final String key;
  final String label;
}

const inboxTabs = [
  InboxTab('to_quote', 'À chiffrer'),
  InboxTab('quoted', 'Devis envoyés'),
  InboxTab('to_buy', 'À acheter'),
  InboxTab('to_ship', 'À expédier'),
  InboxTab('in_transit', 'En route'),
  InboxTab('pickups', 'Retraits'),
  InboxTab('done', 'Terminées'),
];

/// null = both stores.
final storeFilterProvider = StateProvider<String?>((_) => null);

final inboxProvider = FutureProvider.autoDispose.family<List<OrderSummary>, String>(
  (ref, tab) => ref.watch(adminApiProvider).inbox(tab, store: ref.watch(storeFilterProvider)),
);

/// What must happen next for orders in each tab: every step is explicit.
const _tabNotices = {
  'to_quote': 'Ouvrez chaque commande et envoyez le devis (capture du panier + prix).',
  'to_buy': 'Payées : achetez le panier sur SHEIN/Temu puis enregistrez l’achat.',
  'to_ship': 'Achetées : ajoutez chaque commande à une expédition (bouton « Ajouter à une expédition »), puis marquez l’expédition comme partie.',
  'in_transit': 'En route : à l’arrivée, ouvrez l’expédition et touchez « Arrivée à Abidjan ».',
  'pickups': 'Arrivées : marquez « Prête au retrait » pour envoyer le code, puis validez le retrait avec le code.',
};

/// Quote requests older than this during opening hours are highlighted.
const overdueAfter = Duration(hours: 2);

class InboxScreen extends ConsumerWidget {
  const InboxScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: inboxTabs.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Commandes'),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Filtrer par magasin',
              icon: Icon(ref.watch(storeFilterProvider) == null ? Icons.filter_list_rounded : Icons.filter_alt_rounded),
              onSelected: (v) => ref.read(storeFilterProvider.notifier).state = v == 'ALL' ? null : v,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'ALL', child: Text('SHEIN et Temu')),
                PopupMenuItem(value: 'SHEIN', child: Text('SHEIN seulement')),
                PopupMenuItem(value: 'TEMU', child: Text('Temu seulement')),
              ],
            ),
            IconButton(
              tooltip: 'Rechercher une référence',
              icon: const Icon(Icons.search_rounded),
              onPressed: () => showSearch(context: context, delegate: _RefSearch(ref)),
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final t in inboxTabs) Tab(text: t.label)],
          ),
        ),
        body: Column(children: [
          if (ref.watch(sessionProvider).me?.canOperate ?? false) const VerificationsBanner(),
          Expanded(child: TabBarView(children: [for (final t in inboxTabs) _OrderList(tab: t.key)])),
        ]),
      ),
    );
  }
}

class _OrderList extends ConsumerWidget {
  const _OrderList({required this.tab});

  final String tab;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orders = ref.watch(inboxProvider(tab));
    return RefreshIndicator(
      onRefresh: () => ref.refresh(inboxProvider(tab).future),
      child: orders.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ListView(children: [ErrorView(e, onRetry: () => ref.invalidate(inboxProvider(tab)))]),
        data: (list) => list.isEmpty
            ? ListView(children: const [
                SizedBox(height: 120),
                Center(child: Text('Rien ici pour le moment.')),
              ])
            : ListView(padding: const EdgeInsets.all(12), children: [
                if (_tabNotices[tab] != null) ...[WarningBox(_tabNotices[tab]!), const SizedBox(height: 10)],
                for (final o in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: OrderTile(order: o, onReturn: () => ref.invalidate(inboxProvider(tab))),
                  ),
              ]),
      ),
    );
  }
}

class OrderTile extends StatelessWidget {
  const OrderTile({super.key, required this.order, this.onReturn});

  final OrderSummary order;
  final VoidCallback? onReturn;

  @override
  Widget build(BuildContext context) {
    final overdue = order.status == 'QUOTE_REQUESTED' && DateTime.now().difference(order.statusChangedAt.toLocal()) > overdueAfter;
    return Card(
      shape: overdue
          ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.warning, width: 1.5))
          : null,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () async {
          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: order.id)));
          onReturn?.call();
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  StoreBadge(order.store, small: true),
                  const SizedBox(width: 8),
                  Text(order.publicRef, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  if (order.hasChangeRequest) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.edit_note_rounded, size: 20, color: AppColors.warning, semanticLabel: 'Modification demandée'),
                  ],
                ]),
                const SizedBox(height: 4),
                Text(
                  '${order.customerName ?? 'Client'} · ${ago(order.statusChangedAt)}',
                  style: TextStyle(color: overdue ? AppColors.warning : AppColors.muted),
                ),
                if (order.shipmentLabel != null) ...[
                  const SizedBox(height: 4),
                  Row(children: [
                    const Icon(Icons.local_shipping_outlined, size: 16, color: AppColors.muted),
                    const SizedBox(width: 4),
                    Flexible(child: Text(order.shipmentLabel!, style: const TextStyle(color: AppColors.muted), overflow: TextOverflow.ellipsis)),
                  ]),
                ],
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              StatusChip(order.status),
              const SizedBox(height: 6),
              Text(fcfa(order.totalXof), style: const TextStyle(fontWeight: FontWeight.w600)),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _RefSearch extends SearchDelegate<void> {
  _RefSearch(this.ref) : super(searchFieldLabel: 'FLR-…');

  final WidgetRef ref;

  @override
  List<Widget> buildActions(BuildContext context) =>
      [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];

  @override
  Widget buildLeading(BuildContext context) =>
      IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, null));

  @override
  Widget buildResults(BuildContext context) => buildSuggestions(context);

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim();
    if (q.length < 3) return const Center(child: Text('Tapez au moins 3 caractères'));
    return FutureBuilder<List<OrderSummary>>(
      future: ref.read(adminApiProvider).inbox('all', search: q),
      builder: (context, snap) {
        if (snap.hasError) return ErrorView(snap.error!, onRetry: () => query = query);
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final list = snap.data!;
        if (list.isEmpty) return const Center(child: Text('Aucune commande'));
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: list.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => OrderTile(order: list[i]),
        );
      },
    );
  }
}
