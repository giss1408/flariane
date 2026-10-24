import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import 'dispatch_screen.dart';

final shipmentsProvider = FutureProvider.autoDispose<List<Shipment>>((ref) => ref.watch(adminApiProvider).shipments());

const shipmentStatusLabels = {'OPEN': 'En préparation', 'IN_TRANSIT': 'En route', 'ARRIVED': 'Arrivée'};

class ShipmentsScreen extends ConsumerWidget {
  const ShipmentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shipments = ref.watch(shipmentsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expéditions'),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.map_outlined),
            label: const Text('Répartition'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DispatchScreen())),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(shipmentsProvider.future),
        child: shipments.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [ErrorView(e, onRetry: () => ref.invalidate(shipmentsProvider))]),
          data: (list) => list.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('Aucune expédition. Fixez le prochain départ dans Paramètres.', textAlign: TextAlign.center)),
                ])
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final s = list[i];
                    return Card(
                      child: ListTile(
                        title: Text(s.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text('${s.orderRefs.length} commande(s)${s.trackingRef == null ? '' : ' · ${s.trackingRef}'}'),
                        trailing: Text(shipmentStatusLabels[s.status] ?? s.status),
                        onTap: () async {
                          await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentScreen(shipmentId: s.id)));
                          ref.invalidate(shipmentsProvider);
                        },
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}

final _shipmentProvider = FutureProvider.autoDispose.family<Shipment, int>((ref, id) async {
  final all = await ref.watch(adminApiProvider).shipments();
  return all.firstWhere((s) => s.id == id);
});

final _toShipProvider = FutureProvider.autoDispose<List<OrderSummary>>((ref) => ref.watch(adminApiProvider).inbox('to_ship'));

class ShipmentScreen extends ConsumerWidget {
  const ShipmentScreen({super.key, required this.shipmentId});

  final int shipmentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shipment = ref.watch(_shipmentProvider(shipmentId));
    final canOperate = ref.watch(sessionProvider).me?.canOperate ?? false;
    void reload() => ref.invalidate(_shipmentProvider(shipmentId));

    return Scaffold(
      appBar: AppBar(title: Text(shipment.valueOrNull?.label ?? 'Expédition')),
      body: shipment.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: reload),
        data: (s) => ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(shipmentStatusLabels[s.status] ?? s.status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (s.departureDate != null) Text('Départ prévu : ${DateFormat('EEEE d MMMM', 'fr').format(s.departureDate!)}'),
                if (s.orderDeadline != null) Text('Dernière commande : ${DateFormat('EEEE d MMMM', 'fr').format(s.orderDeadline!)}'),
                if (s.forwarder != null) Text('Transitaire : ${s.forwarder}'),
                if (s.trackingRef != null) Text('Suivi : ${s.trackingRef}'),
                if (s.departedAt != null) Text('Départ : ${dateTime(s.departedAt)}'),
                if (s.arrivedAt != null) Text('Arrivée : ${dateTime(s.arrivedAt)}'),
              ]),
            ),
          ),
          SectionTitle('Commandes (${s.orderRefs.length})'),
          Card(
            child: Column(children: [
              if (s.orderRefs.isEmpty) const ListTile(title: Text('Aucune commande')),
              for (final (i, r) in s.orderRefs.indexed)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: Text(r),
                  // Only while the shipment is still being prepared (server refuses afterwards).
                  trailing: canOperate && s.status == 'OPEN' && i < s.orderIds.length
                      ? IconButton(
                          tooltip: 'Retirer de l’expédition',
                          icon: const Icon(Icons.remove_circle_outline_rounded, color: AppColors.danger),
                          onPressed: () => _removeOrder(context, ref, s, s.orderIds[i], r),
                        )
                      : null,
                ),
            ]),
          ),
          if (canOperate && s.status == 'OPEN') ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              icon: const Icon(Icons.playlist_add_rounded),
              label: const Text('Ajouter des commandes achetées'),
              onPressed: () => _addOrders(context, ref, s),
            ),
          ],
        ]),
      ),
      bottomNavigationBar: !canOperate || shipment.valueOrNull == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: switch (shipment.value!.status) {
                  'OPEN' => FilledButton(onPressed: () => _depart(context, ref, shipment.value!), child: const Text('Marquer comme partie')),
                  'IN_TRANSIT' => FilledButton(
                      onPressed: () async {
                        final ok = await confirm(context,
                            title: 'Arrivée à Abidjan ?', body: 'Toutes les commandes passent à « Arrivée ».', ok: 'Confirmer');
                        if (!ok) return;
                        try {
                          await ref.read(adminApiProvider).arriveShipment(shipmentId);
                          reload();
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      child: const Text('Arrivée à Abidjan'),
                    ),
                  _ => const SizedBox.shrink(),
                },
              ),
            ),
    );
  }

  Future<void> _removeOrder(BuildContext context, WidgetRef ref, Shipment s, int orderId, String orderRef) async {
    final ok = await confirm(
      context,
      title: 'Retirer $orderRef ?',
      body: 'La commande sortira de « ${s.label} » et ne partira pas avec ce colis. '
          'Elle devra être ajoutée à un autre départ.',
      ok: 'Retirer',
    );
    if (!ok) return;
    try {
      await ref.read(adminApiProvider).removeFromShipment(s.id, orderId);
      ref.invalidate(_shipmentProvider(shipmentId));
      if (context.mounted) showInfo(context, '$orderRef retirée de l’expédition.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _addOrders(BuildContext context, WidgetRef ref, Shipment s) async {
    final orders = await ref.read(_toShipProvider.future);
    if (!context.mounted) return;
    if (orders.isEmpty) return showInfo(context, 'Aucune commande achetée en attente.');
    final selected = <int>{...orders.map((o) => o.id)};
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const ListTile(title: Text('Commandes à expédier', style: TextStyle(fontWeight: FontWeight.w700))),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final o in orders)
                  CheckboxListTile(
                    value: selected.contains(o.id),
                    title: Text(o.publicRef),
                    subtitle: Text(o.customerName ?? ''),
                    onChanged: (v) => setState(() => v == true ? selected.add(o.id) : selected.remove(o.id)),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: FilledButton(
                onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, true),
                child: Text('Ajouter ${selected.length} commande(s)'),
              ),
            ),
          ]),
        ),
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminApiProvider).addToShipment(s.id, selected.toList());
      ref.invalidate(_shipmentProvider(shipmentId));
      ref.invalidate(_toShipProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _depart(BuildContext context, WidgetRef ref, Shipment s) async {
    final tracking = TextEditingController();
    final weight = TextEditingController();
    final cost = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Départ de l’expédition'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: tracking, decoration: const InputDecoration(labelText: 'N° de suivi (AWB)')),
            const SizedBox(height: 10),
            TextField(
              controller: weight,
              decoration: const InputDecoration(labelText: 'Poids (kg)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: cost,
              decoration: const InputDecoration(labelText: 'Coût transitaire', suffixText: 'FCFA'),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminApiProvider).departShipment(
            s.id,
            trackingRef: tracking.text.trim().isEmpty ? null : tracking.text.trim(),
            weightKg: weight.text.trim().isEmpty ? null : weight.text.trim().replaceAll(',', '.'),
            costXof: int.tryParse(cost.text),
          );
      ref.invalidate(_shipmentProvider(shipmentId));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.ok});

  final bool ok;

  @override
  Widget build(BuildContext context) =>
      Icon(Icons.circle, size: 10, color: ok ? AppColors.success : AppColors.warning);
}
