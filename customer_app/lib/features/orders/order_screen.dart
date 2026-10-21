import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

class OrderScreen extends ConsumerStatefulWidget {
  const OrderScreen({super.key, required this.orderRef});

  final String orderRef;

  @override
  ConsumerState<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends ConsumerState<OrderScreen> with WidgetsBindingObserver {
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  /// Back from the Wave app: re-read the order (the webhook confirms payment server-side).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) ref.invalidate(orderProvider(widget.orderRef));
  }

  void _syncPolling(Order o) {
    if (o.paymentPending && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 5), (_) => ref.invalidate(orderProvider(widget.orderRef)));
    } else if (!o.paymentPending) {
      _poll?.cancel();
      _poll = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = ref.watch(orderProvider(widget.orderRef));
    order.whenData(_syncPolling);
    return Scaffold(
      appBar: FlarianeHeader(subtitle: 'Commande ${widget.orderRef}'),
      body: order.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(orderProvider(widget.orderRef))),
        data: (o) => RefreshIndicator(
          onRefresh: () => ref.refresh(orderProvider(widget.orderRef).future),
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
            _StatusBanner(order: o),
            if (o.quote != null && (o.status == 'QUOTED' || o.status == 'AWAITING_PAYMENT'))
              _QuoteCard(order: o, quote: o.quote!)
            else if (o.quote != null)
              _QuoteRecap(quote: o.quote!),
            if (stepIndex(o.status) >= 0) ...[
              const SizedBox(height: 16),
              Card(child: Padding(padding: const EdgeInsets.all(14), child: OrderStepper(status: o.status))),
            ],
            if (o.pickupPoint != null) ...[
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.place_rounded),
                  title: Text(o.pickupPoint!.name),
                  subtitle: Text('${o.pickupPoint!.address}\n${o.pickupPoint!.openingHours}'),
                  isThreeLine: true,
                ),
              ),
            ],
            if (o.canCancel) ...[
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => _cancel(o),
                child: const Text('Annuler la commande', style: TextStyle(color: AppColors.danger)),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Future<void> _cancel(Order o) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Annuler la commande ?'),
        content: const Text('Rien ne sera acheté.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Non')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Oui, annuler')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).cancel(o.ref);
      ref.invalidate(orderProvider(o.ref));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}

class _StatusBanner extends ConsumerWidget {
  const _StatusBanner({required this.order});

  final Order order;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (text, color) = switch (order.status) {
      'QUOTE_REQUESTED' => ('Devis en préparation — vous recevrez un message WhatsApp.', AppColors.primary),
      'QUOTED' when order.canRequestRequote => ('Votre devis a expiré.', AppColors.warning),
      'QUOTED' => ('Votre devis est prêt.', AppColors.primary),
      'AWAITING_PAYMENT' when order.paymentPending => ('Nous confirmons votre paiement Wave…', AppColors.primary),
      'AWAITING_PAYMENT' => ('Paiement non abouti. Vous pouvez réessayer.', AppColors.warning),
      'PAID' => ('Paiement reçu. Nous achetons vos articles.', AppColors.success),
      'READY_FOR_PICKUP' => ('Votre colis vous attend ! Présentez le code reçu sur WhatsApp.', AppColors.success),
      'CANCELLED' => ('Commande annulée.', AppColors.danger),
      'REFUND_PENDING' => ('Remboursement en cours.', AppColors.warning),
      'REFUNDED' => ('Commande remboursée.', AppColors.muted),
      _ => (statusLabels[order.status] ?? order.status, AppColors.primary),
    };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: color.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          if (order.paymentPending) ...[
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600))),
        ]),
        if (order.canRequestRequote) ...[
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: () async {
              try {
                await ref.read(apiProvider).requote(order.ref);
                ref.invalidate(orderProvider(order.ref));
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
            child: const Text('Demander un nouveau devis'),
          ),
        ],
        if (order.status == 'AWAITING_PAYMENT' && !order.paymentPending) ...[
          const SizedBox(height: 10),
          FilledButton(
            onPressed: () async {
              try {
                final p = await ref.read(apiProvider).retryPayment(order.ref);
                await openWave(p);
                ref.invalidate(orderProvider(order.ref));
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
            child: const Text('Réessayer le paiement Wave'),
          ),
        ],
      ]),
    );
  }
}

Future<void> openWave(Payment p) async {
  if (p.launchUrl == null) throw ApiException(502, 'wave_unavailable');
  // Opens the Wave app if installed (universal link), otherwise Wave's web checkout.
  await launchUrl(Uri.parse(p.launchUrl!), mode: LaunchMode.externalApplication);
}

String variant(QuoteLine l) => [l.size, l.color].whereType<String>().where((s) => s.isNotEmpty).join(' · ');

class _QuoteCard extends ConsumerStatefulWidget {
  const _QuoteCard({required this.order, required this.quote});

  final Order order;
  final Quote quote;

  @override
  ConsumerState<_QuoteCard> createState() => _QuoteCardState();
}

class _QuoteCardState extends ConsumerState<_QuoteCard> {
  bool _sizesChecked = false;
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      final p = await ref.read(apiProvider).acceptQuote(widget.order.ref, widget.quote.version);
      await openWave(p);
      ref.invalidate(orderProvider(widget.order.ref));
    } on ApiException catch (e) {
      if (!mounted) return;
      showError(context, e);
      // The quote changed or expired while the screen was open: never pay an outdated version.
      if (e.code == 'quote_outdated' || e.code == 'quote_expired') ref.invalidate(orderProvider(widget.order.ref));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final q = widget.quote;
    final open = q.isOpen(DateTime.now()) && widget.order.status == 'QUOTED';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 16),
      Row(children: [
        Text('Devis n°${q.version}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
        const Spacer(),
        if (q.expiresAt != null && open) Text('valable jusqu’au ${dateTime(q.expiresAt)}', style: const TextStyle(color: AppColors.muted)),
      ]),
      const SizedBox(height: 8),
      for (final l in q.lines)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Card(
            child: ListTile(
              title: Text(l.title),
              subtitle: Text('${variant(l).isEmpty ? '' : '${variant(l)} · '}Qté ${l.qty}', style: const TextStyle(fontWeight: FontWeight.w600)),
              trailing: Text(fcfa(l.lineTotalXof)),
            ),
          ),
        ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            AmountRow('Articles', q.itemsXof),
            AmountRow('Transport', q.freightXof),
            AmountRow('Douane', q.customsXof),
            AmountRow('Frais de service', q.feeXof),
            const Divider(),
            AmountRow('Total', q.totalXof, bold: true),
          ]),
        ),
      ),
      if (q.note != null && q.note!.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('« ${q.note} »', style: const TextStyle(fontStyle: FontStyle.italic)),
      ],
      if (open) ...[
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _sizesChecked,
          onChanged: (v) => setState(() => _sizesChecked = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text('Tailles et couleurs vérifiées'),
          subtitle: const Text('Les articles ne peuvent pas être retournés.'),
        ),
        FilledButton(
          onPressed: _sizesChecked && !_busy ? _accept : null,
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : Text('Accepter et payer ${fcfa(q.totalXof)} avec Wave'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () async {
            final sent = await showModalBottomSheet<bool>(
              context: context,
              isScrollControlled: true,
              builder: (_) => ChangeRequestSheet(order: widget.order, quote: q),
            );
            if (sent == true) ref.invalidate(orderProvider(widget.order.ref));
          },
          child: const Text('Modifier ma commande'),
        ),
      ],
    ]);
  }
}

class _QuoteRecap extends StatelessWidget {
  const _QuoteRecap({required this.quote});

  final Quote quote;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Card(
          child: ExpansionTile(
            title: Text('Devis n°${quote.version} · ${fcfa(quote.totalXof)}'),
            children: [
              for (final l in quote.lines)
                ListTile(dense: true, title: Text('${l.qty} × ${l.title}'), subtitle: Text(variant(l)), trailing: Text(fcfa(l.lineTotalXof))),
            ],
          ),
        ),
      );
}

/// Pure builder for the change-request body (unit-tested).
Map<String, dynamic> buildChangeRequest({
  required Quote quote,
  required Set<int> removed,
  required Map<int, ({String size, String color, int qty})> edits,
  String? newLink,
  String? note,
}) {
  final changes = <Map<String, dynamic>>[];
  for (final l in quote.lines) {
    final e = edits[l.itemId];
    if (e == null || removed.contains(l.itemId)) continue;
    final c = <String, dynamic>{'order_item_id': l.itemId};
    if (e.size.trim() != (l.size ?? '')) c['size'] = e.size.trim();
    if (e.color.trim() != (l.color ?? '')) c['color'] = e.color.trim();
    if (e.qty != l.qty) c['qty'] = e.qty;
    if (c.length > 1) changes.add(c);
  }
  return {
    if (newLink != null && newLink.trim().isNotEmpty) 'new_share_text': newLink.trim(),
    'removed_item_ids': removed.toList(),
    'line_changes': changes,
    if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
  };
}

class ChangeRequestSheet extends ConsumerStatefulWidget {
  const ChangeRequestSheet({super.key, required this.order, required this.quote});

  final Order order;
  final Quote quote;

  @override
  ConsumerState<ChangeRequestSheet> createState() => _ChangeRequestSheetState();
}

class _ChangeRequestSheetState extends ConsumerState<ChangeRequestSheet> {
  final _removed = <int>{};
  late final Map<int, ({String size, String color, int qty})> _edits = {
    for (final l in widget.quote.lines) l.itemId: (size: l.size ?? '', color: l.color ?? '', qty: l.qty),
  };
  final _link = TextEditingController();
  final _note = TextEditingController();
  bool _busy = false;

  Future<void> _send() async {
    final body = buildChangeRequest(
      quote: widget.quote,
      removed: _removed,
      edits: _edits,
      newLink: _link.text,
      note: _note.text,
    );
    if (body.length == 2 && (body['removed_item_ids'] as List).isEmpty && (body['line_changes'] as List).isEmpty) {
      return showInfo(context, 'Indiquez au moins une modification.');
    }
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).requestChange(widget.order.ref, widget.quote.version, body);
      if (!mounted) return;
      showInfo(context, 'Demande envoyée — vous recevrez un nouveau devis.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
            Text('Modifier ma commande', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            for (final l in widget.quote.lines) _lineEditor(l),
            TextField(
              controller: _link,
              decoration: const InputDecoration(labelText: 'Nouveau lien de panier SHEIN (optionnel)'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _note, maxLines: 2, decoration: const InputDecoration(labelText: 'Message (optionnel)')),
            const SizedBox(height: 16),
            FilledButton(onPressed: _busy ? null : _send, child: const Text('Envoyer la demande')),
          ]),
        ),
      );

  Widget _lineEditor(QuoteLine l) {
    final removed = _removed.contains(l.itemId);
    final e = _edits[l.itemId]!;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: Text(l.title,
                  style: TextStyle(fontWeight: FontWeight.w600, decoration: removed ? TextDecoration.lineThrough : null)),
            ),
            TextButton(
              onPressed: () => setState(() => removed ? _removed.remove(l.itemId) : _removed.add(l.itemId)),
              child: Text(removed ? 'Garder' : 'Retirer'),
            ),
          ]),
          if (!removed)
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: e.size,
                  decoration: const InputDecoration(labelText: 'Taille'),
                  onChanged: (v) => _edits[l.itemId] = (size: v, color: _edits[l.itemId]!.color, qty: _edits[l.itemId]!.qty),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: e.color,
                  decoration: const InputDecoration(labelText: 'Couleur'),
                  onChanged: (v) => _edits[l.itemId] = (size: _edits[l.itemId]!.size, color: v, qty: _edits[l.itemId]!.qty),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: TextFormField(
                  initialValue: '${e.qty}',
                  decoration: const InputDecoration(labelText: 'Qté'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                  onChanged: (v) => _edits[l.itemId] =
                      (size: _edits[l.itemId]!.size, color: _edits[l.itemId]!.color, qty: (int.tryParse(v) ?? 1).clamp(1, 50)),
                ),
              ),
            ]),
        ]),
      ),
    );
  }
}
