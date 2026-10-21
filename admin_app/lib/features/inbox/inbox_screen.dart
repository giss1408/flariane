import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../order/order_screen.dart';

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

final inboxProvider = FutureProvider.autoDispose.family<List<OrderSummary>, String>(
  (ref, tab) => ref.watch(adminApiProvider).inbox(tab),
);

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
        body: TabBarView(children: [for (final t in inboxTabs) _OrderList(tab: t.key)]),
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
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: list.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => OrderTile(order: list[i], onReturn: () => ref.invalidate(inboxProvider(tab))),
              ),
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
