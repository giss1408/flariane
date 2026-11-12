
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/cached_image.dart';
import '../../widgets/common.dart';
import '../../widgets/payment_proof.dart';
import '../../widgets/store_badge.dart';
import '../../widgets/whatsapp.dart';
import '../purchase/purchase_screen.dart';
import '../quote/quote_editor_screen.dart';
import '../shipments/shipments_screen.dart';

final orderProvider = FutureProvider.autoDispose.family<OrderDetail, int>(
  (ref, id) => ref.watch(adminApiProvider).order(id),
);

final pickupPointsProvider = FutureProvider.autoDispose<List<PickupPoint>>(
  (ref) => ref.watch(adminApiProvider).pickupPoints(),
);

/// Opens a SHEIN/Temu share link outside the app, so the installed store app handles it.
Future<void> openInShein(BuildContext context, String url) async {
  final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) showInfo(context, 'Impossible d’ouvrir le lien.');
}

class OrderScreen extends ConsumerWidget {
  const OrderScreen({super.key, required this.orderId});

  final int orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final order = ref.watch(orderProvider(orderId));
    final me = ref.watch(sessionProvider).me;
    return Scaffold(
      appBar: AppBar(
        title: Text(order.valueOrNull?.publicRef ?? 'Commande'),
        actions: [
          if (order.valueOrNull != null &&
              ((me?.isSuperAdmin ?? false) ||
                  ((me?.canOperate ?? false) && (order.value!.canDeleteWrongLink || order.value!.canDeleteUnpaid || order.value!.canDeletePaymentProblem))))
            _DeleteMenu(order: order.value!, superAdmin: me?.isSuperAdmin ?? false),
        ],
      ),
      body: order.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(orderProvider(orderId))),
        data: (o) => RefreshIndicator(
          onRefresh: () => ref.refresh(orderProvider(orderId).future),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              _Header(order: o),
              if (o.pendingChangeRequest != null) _ChangeRequestCard(order: o, change: o.pendingChangeRequest!),
              _CartSection(order: o),
              if (o.customerNote != null && o.customerNote!.isNotEmpty) ...[
                const SectionTitle('Note du client'),
                Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(o.customerNote!))),
              ],
              if (o.latestSent != null) _QuoteSummary(order: o),
              if (o.purchase != null) _PurchaseSummary(order: o),
              if (o.inShipment) ...[
                const SectionTitle('Expédition'),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.local_shipping_rounded),
                    title: Text(o.shipmentLabel ?? 'Expédition'),
                    subtitle: const Text('Ouvrir l’expédition'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentScreen(shipmentId: o.shipmentId!)));
                      ref.invalidate(orderProvider(orderId));
                    },
                  ),
                ),
              ],
              const SectionTitle('Adresse à Abidjan'),
              Card(
                child: o.deliveryLocation == null
                    ? const ListTile(leading: Icon(Icons.location_off_outlined), title: Text('Non renseignée par la cliente'))
                    : ListTile(
                        leading: const Icon(Icons.home_work_outlined),
                        title: Text('${o.deliveryLocation!.commune}, ${o.deliveryLocation!.quartier}'),
                        subtitle: o.deliveryLocation!.landmark == null ? null : Text(o.deliveryLocation!.landmark!),
                        trailing: o.deliveryLocation!.mapsUrl == null
                            ? null
                            : IconButton(
                                tooltip: 'Ouvrir dans Maps',
                                icon: const Icon(Icons.map_rounded),
                                onPressed: () => launchUrl(Uri.parse(o.deliveryLocation!.mapsUrl!), mode: LaunchMode.externalApplication),
                              ),
                      ),
              ),
              if (o.pickupPoint != null) ...[
                const SectionTitle('Point de retrait'),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.place_rounded),
                    title: Text(o.pickupPoint!.name),
                    subtitle: Text('${o.pickupPoint!.address}\n${o.pickupPoint!.openingHours}'),
                  ),
                ),
              ],
              _RefundSection(order: o, canRefund: me?.role == 'SUPER_ADMIN', onChanged: () => ref.invalidate(orderProvider(orderId))),
              _ItemsSection(order: o, canOperate: me?.canOperate ?? false),
              const SectionTitle('Historique'),
              Card(
                child: Column(children: [
                  for (final h in o.history.reversed)
                    ListTile(dense: true, title: Text(statusLabels[h.toStatus] ?? h.toStatus), trailing: Text(dateTime(h.createdAt))),
                ]),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: order.valueOrNull == null || !(me?.canOperate ?? false)
          ? null
          : SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: _PrimaryAction(order: order.value!))),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              StoreBadge(order.store),
              const SizedBox(width: 10),
              Expanded(child: Text(order.customerName ?? 'Client', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
              StatusChip(order.status),
            ]),
            const SizedBox(height: 6),
            Row(children: [
              Text(order.customerPhoneMasked, style: const TextStyle(color: AppColors.muted)),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('Afficher'),
                onPressed: () async {
                  try {
                    final phone = await ref.read(adminApiProvider).revealPhone(order.id);
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Téléphone du client'),
                        content: SelectableText(phone, style: const TextStyle(fontSize: 20)),
                        actions: [
                          TextButton(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: phone));
                              Navigator.pop(ctx);
                            },
                            child: const Text('Copier'),
                          ),
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
                        ],
                      ),
                    );
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
            ]),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.key_rounded, size: 18),
                label: const Text('Mot de passe oublié'),
                onPressed: () => _resetPassword(context, ref),
              ),
            ),
          ]),
        ),
      );

  Future<void> _resetPassword(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(context,
        title: 'Réinitialiser le mot de passe ?',
        body: 'Vérifiez d’abord que la demande vient bien du numéro du client. Ses sessions seront fermées.',
        ok: 'Réinitialiser');
    if (!ok || !context.mounted) return;
    try {
      final temp = await ref.read(adminApiProvider).resetCustomerPassword(order.customerId);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Mot de passe temporaire'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('À envoyer au client sur WhatsApp. Affiché une seule fois ; il devra le changer à la connexion.'),
            const SizedBox(height: 12),
            SelectableText(temp, style: const TextStyle(fontSize: 22, letterSpacing: 2, fontWeight: FontWeight.w700)),
          ]),
          actions: [
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: temp)), child: const Text('Copier')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

class _ChangeRequestCard extends StatelessWidget {
  const _ChangeRequestCard({required this.order, required this.change});

  final OrderDetail order;
  final ChangeRequest change;

  @override
  Widget build(BuildContext context) {
    final itemsById = {for (final i in order.items) i.id: i};
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: AppColors.warningBg, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Modification demandée', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.warning)),
          const SizedBox(height: 6),
          if (change.newCartUrl != null) const Text('• Nouveau lien de panier (voir ci-dessous)'),
          for (final id in change.removedItemIds) Text('• Retirer : ${itemsById[id]?.title ?? 'article $id'}'),
          for (final c in change.lineChanges)
            Text('• ${itemsById[c['order_item_id']]?.title ?? 'Article'} : '
                '${[if (c['size'] != null) 'taille ${c['size']}', if (c['color'] != null) 'couleur ${c['color']}', if (c['qty'] != null) 'qté ${c['qty']}'].join(', ')}'),
          if (change.note != null && change.note!.isNotEmpty) Text('« ${change.note} »'),
        ]),
      ),
    );
  }
}

class _CartSection extends StatelessWidget {
  const _CartSection({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionTitle('Panier ${order.storeName}'),
        if (order.sourceCartUrl != null)
          FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text('Ouvrir dans ${order.storeName}'),
            onPressed: () => openInShein(context, order.sourceCartUrl!),
          ),
        for (final (i, link) in order.submittedLinks.indexed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.link_rounded),
              label: Text('Lien ${i + 1}'),
              onPressed: () => openInShein(context, link),
            ),
          ),
        if (order.attachments.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: order.attachments.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) => GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Capture du panier')),
                    body: InteractiveViewer(child: Center(child: CachedImage(order.attachments[i].url))),
                  ),
                )),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedImage(order.attachments[i].url, width: 100, height: 100, fit: BoxFit.cover, errorText: ''),
                ),
              ),
            ),
          ),
        ],
      ]);
}

class _QuoteSummary extends StatelessWidget {
  const _QuoteSummary({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context) {
    final q = order.latestSent!;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Devis n°${q.version}', trailing: Text(quoteStatusLabels[q.status] ?? q.status)),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            if (q.screenshotUrl != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedImage(q.screenshotUrl!, height: 200, width: double.infinity, fit: BoxFit.cover, alignment: Alignment.topCenter),
                ),
              ),
            for (final l in q.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text('${l.qty} × ${l.title}${l.variant.isEmpty ? '' : '\n${l.variant}'}')),
                  Text(fcfa(l.lineTotalXof)),
                ]),
              ),
            const Divider(),
            AmountRow(q.isCartMode ? 'Panier ${order.storeName}${q.cartEuros == null ? '' : ' (${q.cartEuros})'}' : 'Articles', q.itemsXof),
            AmountRow('Transport', q.freightXof),
            if (q.customsXof > 0) AmountRow('Douane', q.customsXof),
            if (q.feeXof > 0) AmountRow('Frais de service', q.feeXof),
            AmountRow('Total', q.totalXof, bold: q.loyaltyDiscountXof == 0),
            if (q.loyaltyDiscountXof > 0) ...[
              AmountRow('Points utilisés (${q.loyaltyPointsUsed} pts)', -q.loyaltyDiscountXof),
              AmountRow('À payer', q.amountToPayXof, bold: true),
            ],
            if (q.expiresAt != null && q.status == 'SENT')
              Align(alignment: Alignment.centerLeft, child: Text('Valable jusqu’au ${dateTime(q.expiresAt)}', style: const TextStyle(color: AppColors.muted))),
          ]),
        ),
      ),
    ]);
  }
}

class _PurchaseSummary extends StatelessWidget {
  const _PurchaseSummary({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionTitle('Achat ${order.storeName}'),
        Card(
          child: ListTile(
            leading: const Icon(Icons.receipt_long_rounded),
            title: Text('Commande ${order.storeName} ${order.purchase!.storeOrderRef}'),
            subtitle: Text('Payé ${fcfa(order.purchase!.paidXof)}'
                '${order.purchase!.decision == null ? '' : ' · hausse : ${order.purchase!.decision == 'ABSORB' ? 'absorbée' : 'client contacté'}'}'),
          ),
        ),
      ]);
}

class _ItemsSection extends ConsumerWidget {
  const _ItemsSection({required this.order, required this.canOperate});

  final OrderDetail order;
  final bool canOperate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canCancel = canOperate && (order.status == 'PURCHASED' || order.status == 'IN_TRANSIT');
    final items = order.activeItems;
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Articles'),
      Card(
        child: Column(children: [
          for (final i in items)
            ListTile(
              title: Text(i.title, style: TextStyle(decoration: i.itemStatus == 'OK' ? null : TextDecoration.lineThrough)),
              subtitle: Text([
                '${i.qty} ×',
                if (i.size != null) i.size!,
                if (i.color != null) i.color!,
                '${i.sourcePrice} ${i.sourceCurrency}',
                if (i.itemStatus == 'CANCELLED_BY_STORE') '· annulé par le magasin',
              ].join(' ')),
              trailing: canCancel && i.itemStatus == 'OK'
                  ? PopupMenuButton<String>(
                      onSelected: (_) async {
                        final ok = await confirm(context,
                            title: 'Article annulé par ${order.storeName} ?',
                            body: 'Le client sera remboursé de cet article et prévenu sur WhatsApp.',
                            ok: 'Annuler l’article');
                        if (!ok) return;
                        try {
                          await ref.read(adminApiProvider).cancelItemByStore(order.id, i.id);
                          ref.invalidate(orderProvider(order.id));
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      itemBuilder: (_) => [PopupMenuItem(value: 'cancel', child: Text('Annulé par ${order.storeName}'))],
                    )
                  : null,
            ),
        ]),
      ),
    ]);
  }
}

/// The single primary action for the order's current status.
class _PrimaryAction extends ConsumerWidget {
  const _PrimaryAction({required this.order});

  final OrderDetail order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void refresh() => ref.invalidate(orderProvider(order.id));

    switch (order.status) {
      case 'QUOTE_REQUESTED':
      case 'QUOTED':
        final label = order.status == 'QUOTE_REQUESTED'
            ? (order.draft != null ? 'Reprendre le devis' : 'Préparer le devis')
            : 'Corriger le devis (nouvelle version)';
        final edit = FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => QuoteEditorScreen(order: order)));
            refresh();
          },
          child: Text(label),
        );
        if (order.status != 'QUOTED') return edit;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WhatsAppButton(label: 'Envoyer le devis sur WhatsApp', onPressed: () => sendWhatsApp(context, ref, order.id, 'quote')),
          const SizedBox(height: 8),
          edit,
        ]);
      case 'AWAITING_PAYMENT':
        final manual = order.payments.where((p) => p.awaitsManualConfirmation).firstOrNull;
        final relance = WhatsAppButton(label: 'Relancer le paiement sur WhatsApp', onPressed: () => sendWhatsApp(context, ref, order.id, 'quote'));
        if (manual == null) return relance;
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (manual.declared) ...[
            WarningBox('La cliente a payé par ${manual.methodName}. Vérifie la capture et ton compte (montant + référence), puis confirme.'),
            const SizedBox(height: 8),
            if (manual.hasProof)
              OutlinedButton.icon(
                icon: const Icon(Icons.receipt_rounded),
                label: const Text('Voir la capture du paiement'),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PaymentProofScreen(orderId: order.id))),
              ),
            const SizedBox(height: 8),
          ] else ...[
            relance,
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            icon: const Icon(Icons.verified_rounded),
            onPressed: () => _confirmPayment(context, ref, manual.amountXof),
            label: Text('Confirmer le paiement reçu (${fcfa(manual.amountXof)})'),
          ),
        ]);
      case 'PAID':
        return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          WhatsAppButton(label: 'Confirmer le paiement sur WhatsApp', onPressed: () => sendWhatsApp(context, ref, order.id, 'payment')),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PurchaseScreen(order: order)));
              refresh();
            },
            child: Text('Acheter sur ${order.storeName}'),
          ),
        ]);
      case 'PURCHASED':
        // Next mandatory step: put the parcel in a shipment. Done once: the button locks afterwards.
        return Column(mainAxisSize: MainAxisSize.min, children: [
          if (order.inShipment)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('Déjà dans « ${order.shipmentLabel ?? 'une expédition'} »', style: const TextStyle(color: AppColors.muted)),
            ),
          FilledButton.icon(
            icon: const Icon(Icons.local_shipping_rounded),
            onPressed: order.inShipment ? null : () => _addToShipment(context, ref),
            label: const Text('Ajouter à une expédition'),
          ),
        ]);
      case 'IN_TRANSIT':
        return OutlinedButton.icon(
          icon: const Icon(Icons.flight_land_rounded),
          onPressed: order.shipmentId == null
              ? null
              : () async {
                  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShipmentScreen(shipmentId: order.shipmentId!)));
                  refresh();
                },
          label: const Text('Ouvrir l’expédition (marquer l’arrivée)'),
        );
      case 'ARRIVED':
        return FilledButton(onPressed: () => _readyForPickup(context, ref), child: const Text('Prête au retrait'));
      case 'READY_FOR_PICKUP':
        return Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () async {
                final ok = await confirm(context,
                    title: 'Renvoyer un code ?', body: 'L’ancien code ne marchera plus. WhatsApp s’ouvre avec le nouveau code à envoyer.', ok: 'Nouveau code');
                if (!ok) return;
                try {
                  final code = await ref.read(adminApiProvider).readyForPickup(order.id);
                  if (context.mounted) await sendWhatsApp(context, ref, order.id, 'pickup', code: code);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              child: const Text('Renvoyer le code'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: FilledButton(onPressed: () => _confirmPickup(context, ref), child: const Text('Valider le retrait')),
          ),
        ]);
      case 'PICKED_UP' || 'CANCELLED' || 'REFUNDED':
        return OutlinedButton.icon(
          icon: const Icon(Icons.archive_outlined),
          onPressed: () async {
            if (!await confirm(context, title: 'Retirer cette commande ?', body: 'Elle disparaît des listes (gardée dans l’historique et les rapports).', ok: 'Retirer')) return;
            try {
              await ref.read(adminApiProvider).client.call((d) => d.post('/admin/orders/${order.id}/archive'), (_) {});
              if (context.mounted) Navigator.of(context).pop();
            } catch (e) {
              if (context.mounted) showError(context, e);
            }
          },
          label: const Text('Retirer des listes'),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Future<void> _confirmPayment(BuildContext context, WidgetRef ref, int amount) async {
    final txn = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Paiement reçu sur Wave ?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Confirme seulement si tu vois ${fcfa(amount)} pour ${order.publicRef} sur ton compte.'),
          const SizedBox(height: 12),
          TextField(controller: txn, decoration: const InputDecoration(labelText: 'N° de transaction (optionnel)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirmer')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(adminApiProvider).confirmPayment(order.id, transactionRef: txn.text.trim().isEmpty ? null : txn.text.trim());
      ref.invalidate(orderProvider(order.id));
      if (context.mounted) await sendWhatsApp(context, ref, order.id, 'payment');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _addToShipment(BuildContext context, WidgetRef ref) async {
    final api = ref.read(adminApiProvider);
    try {
      // Only real departures (set as "Prochain départ" in settings) take orders.
      final open = (await api.shipments()).where((s) => s.status == 'OPEN' && s.departureDate != null).toList()
        ..sort((a, b) => a.departureDate!.compareTo(b.departureDate!));
      if (!context.mounted) return;
      final choice = await showModalBottomSheet<int>(
        context: context,
        builder: (ctx) => SafeArea(
          child: ListView(shrinkWrap: true, children: [
            const ListTile(title: Text('Ajouter à une expédition', style: TextStyle(fontWeight: FontWeight.w700))),
            if (open.isEmpty)
              const ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('Aucun départ ouvert'),
                subtitle: Text('Crée le prochain départ ci-dessus.'),
              ),
            ListTile(
              leading: const Icon(Icons.add_circle_outline_rounded),
              title: const Text('Créer un nouveau départ'),
              onTap: () => Navigator.pop(ctx, -1),
            ),
            for (final s in open)
              ListTile(
                leading: const Icon(Icons.flight_takeoff_rounded),
                title: Text(s.label),
                subtitle: Text('${s.orderRefs.length} commande(s)'
                    '${s.orderDeadline == null ? '' : ' · commandes jusqu’au ${DateFormat('d MMMM', 'fr').format(s.orderDeadline!)}'}'),
                onTap: () => Navigator.pop(ctx, s.id),
              ),
          ]),
        ),
      );
      if (choice == null) return;
      var shipmentId = choice;
      if (choice == -1) {
        if (!context.mounted) return;
        final date = await showDatePicker(
          context: context,
          initialDate: DateTime.now().add(const Duration(days: 14)),
          firstDate: DateTime.now(),
          lastDate: DateTime.now().add(const Duration(days: 365)),
          helpText: 'Date de départ',
        );
        if (date == null) return;
        shipmentId = (await api.createShipment(date)).id;
      }
      await api.addToShipment(shipmentId, [order.id]);
      ref.invalidate(orderProvider(order.id));
      if (context.mounted) showInfo(context, 'Commande ajoutée. Marquez l’expédition comme partie au départ.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _readyForPickup(BuildContext context, WidgetRef ref) async {
    final points = await ref.read(pickupPointsProvider.future);
    if (!context.mounted) return;
    final selected = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('Point de retrait', style: TextStyle(fontWeight: FontWeight.w700))),
          for (final p in points)
            ListTile(
              leading: Icon(p.id == order.pickupPoint?.id ? Icons.radio_button_checked : Icons.radio_button_off),
              title: Text(p.name),
              subtitle: Text(p.address),
              onTap: () => Navigator.pop(ctx, p.id),
            ),
        ]),
      ),
    );
    if (selected == null) return;
    try {
      final code = await ref.read(adminApiProvider).readyForPickup(order.id, pickupPointId: selected);
      ref.invalidate(orderProvider(order.id));
      // The code exists only now: send it straight away from WhatsApp.
      if (context.mounted) await sendWhatsApp(context, ref, order.id, 'pickup', code: code);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _confirmPickup(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Code de retrait'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          style: const TextStyle(fontSize: 24, letterSpacing: 6),
          decoration: const InputDecoration(hintText: '000000'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (code == null || code.length != 6) return;
    try {
      await ref.read(adminApiProvider).confirmPickup(order.id, code);
      ref.invalidate(orderProvider(order.id));
      if (context.mounted) showInfo(context, 'Retrait validé.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// SUPER_ADMIN: send money back for a paid order; everyone sees a pending refund and can open the proof.
class _RefundSection extends ConsumerWidget {
  const _RefundSection({required this.order, required this.canRefund, required this.onChanged});

  final OrderDetail order;
  final bool canRefund;
  final VoidCallback onChanged;

  PaymentInfo? get _paid => order.payments.where((p) => p.status == 'SUCCEEDED').firstOrNull;

  Future<void> _start(BuildContext context, WidgetRef ref) async {
    final paid = _paid;
    if (paid == null) return;
    final amount = TextEditingController(text: '${paid.amountXof}');
    final reason = TextEditingController();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rembourser la cliente'),
        content: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Payé : ${fcfa(paid.amountXof)} par ${paid.methodName}. Si tu rembourses tout, la commande est terminée.'),
            const SizedBox(height: 12),
            TextFormField(
              controller: amount,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(labelText: 'Montant à rembourser (FCFA)'),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return n == null || n <= 0 || n > paid.amountXof ? 'Entre 1 et ${paid.amountXof}' : null;
              },
            ),
            TextFormField(
              controller: reason,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Motif'),
              validator: (v) => (v ?? '').trim().length < 3 ? 'Motif requis' : null,
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => form.currentState!.validate() ? Navigator.pop(ctx, true) : null, child: const Text('Rembourser')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final n = int.parse(amount.text);
      await ref.read(adminApiProvider).startRefund(order.id, amountXof: n == paid.amountXof ? null : n, reason: reason.text.trim());
      onChanged();
      if (context.mounted) showInfo(context, 'Remboursement créé. Envoie l’argent puis marque-le « Fait » dans Remboursements.');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = order.status == 'REFUND_PENDING';
    final startable = canRefund && (order.status == 'PAID' || order.status == 'PURCHASED') && _paid != null;
    if (!pending && !startable) return const SizedBox.shrink();
    final proof = order.payments.any((p) => p.hasProof);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Remboursement'),
      if (pending) ...[
        const WarningBox('Remboursement à envoyer à la cliente. Quand c’est fait, marque-le « Fait » dans Compte › Remboursements.'),
      ],
      if (pending && proof)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.receipt_rounded),
            label: const Text('Voir la capture du paiement'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PaymentProofScreen(orderId: order.id))),
          ),
        ),
      if (startable)
        OutlinedButton.icon(
          icon: const Icon(Icons.undo_rounded, color: AppColors.danger),
          style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
          label: const Text('Rembourser la cliente…'),
          onPressed: () => _start(context, ref),
        ),
    ]);
  }
}

class _DeleteMenu extends ConsumerWidget {
  const _DeleteMenu({required this.order, required this.superAdmin});

  final OrderDetail order;
  final bool superAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
        onSelected: (reason) => _delete(context, ref, reason),
        itemBuilder: (_) => [
          if (order.canDeleteWrongLink)
            const PopupMenuItem(value: 'wrong_link', child: Text('Lien incorrect · supprimer')),
          if (order.canDeleteUnpaid)
            const PopupMenuItem(value: 'unpaid', child: Text('Supprimer (non payée)')),
          if (order.canDeletePaymentProblem)
            const PopupMenuItem(value: 'payment_problem', child: Text('Problème de paiement · supprimer')),
          if (superAdmin)
            const PopupMenuItem(value: 'force', child: Text('Forcer la suppression (admin)')),
        ],
      );

  Future<void> _delete(BuildContext context, WidgetRef ref, String reason) async {
    final wrongLink = reason == 'wrong_link';
    final ok = await confirm(
      context,
      title: 'Supprimer ${order.publicRef} ?',
      body: wrongLink
          ? 'Le lien ne mène pas à un panier ${order.storeName} valide. La commande est supprimée définitivement, '
              'puis WhatsApp s’ouvre avec un message demandant à la cliente de renvoyer son panier.'
          : reason == 'force'
              ? 'Suppression forcée, quel que soit l’état : la commande, ses devis, articles, captures, paiements, '
                  'remboursements et achats sont effacés définitivement, y compris pour la cliente. '
                  'Si de l’argent a été reçu, rembourse d’abord : cette action ne rend rien. Seule une trace d’audit reste.'
              : reason == 'payment_problem'
              ? 'Problème de paiement (preuve fausse, illisible ou jamais confirmée). Aucun paiement n’est confirmé : '
                  'la commande est supprimée définitivement (devis, captures, articles) et disparaît aussi de l’app de la cliente.'
              : 'Commande non payée depuis plus de 3 jours. Elle est supprimée définitivement '
                  '(devis, captures, articles) et disparaît aussi de l’app de la cliente.',
      ok: 'Supprimer',
    );
    if (!ok) return;
    try {
      final url = await ref.read(adminApiProvider).deleteOrder(order.id, reason);
      if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (context.mounted) {
        showInfo(context, '${order.publicRef} supprimée.');
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
