import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../order/order_screen.dart';

final dispatchProvider = FutureProvider.autoDispose<List<DispatchGroup>>((ref) => ref.watch(adminApiProvider).dispatch());

/// Parcels en route, arrived or ready, grouped by the customer's commune to plan the rounds.
class DispatchScreen extends ConsumerWidget {
  const DispatchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groups = ref.watch(dispatchProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Répartition par commune')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(dispatchProvider.future),
        child: groups.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [ErrorView(e, onRetry: () => ref.invalidate(dispatchProvider))]),
          data: (list) => list.isEmpty
              ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Aucun colis en route ou arrivé.'))])
              : ListView(padding: const EdgeInsets.all(12), children: [
                  for (final g in list) ...[
                    SectionTitle(g.commune, trailing: Text('${g.orders.length} colis')),
                    Card(
                      child: Column(children: [
                        for (final o in g.orders)
                          ListTile(
                            title: Text('${o.ref} · ${o.name ?? 'Cliente'}'),
                            subtitle: Text([
                              statusLabels[o.status] ?? o.status,
                              if (o.location != null) o.location!.quartier,
                              if (o.location?.landmark != null) o.location!.landmark!,
                            ].join('\n')),
                            isThreeLine: o.location?.landmark != null,
                            trailing: o.location?.mapsUrl == null
                                ? null
                                : IconButton(
                                    tooltip: 'Ouvrir dans Maps',
                                    icon: const Icon(Icons.map_rounded),
                                    onPressed: () => launchUrl(Uri.parse(o.location!.mapsUrl!), mode: LaunchMode.externalApplication),
                                  ),
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OrderScreen(orderId: o.id))),
                          ),
                      ]),
                    ),
                  ],
                ]),
        ),
      ),
    );
  }
}
