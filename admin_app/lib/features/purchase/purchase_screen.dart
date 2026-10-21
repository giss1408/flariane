import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../order/order_screen.dart';

enum LineCheck { unchecked, bought, refused }

/// Pure state for the purchase checklist (unit-tested).
class PurchaseChecklist {
  PurchaseChecklist(Quote accepted) : states = {for (final l in accepted.lines) l.orderItemId: LineCheck.unchecked};

  final Map<int, LineCheck> states;

  void cycle(int itemId) {
    states[itemId] = switch (states[itemId]!) {
      LineCheck.unchecked => LineCheck.bought,
      LineCheck.bought => LineCheck.refused,
      LineCheck.refused => LineCheck.unchecked,
    };
  }

  bool get complete => states.values.every((s) => s != LineCheck.unchecked);
  List<int> get bought => [for (final e in states.entries) if (e.value == LineCheck.bought) e.key];
  List<int> get refused => [for (final e in states.entries) if (e.value == LineCheck.refused) e.key];
}

class PurchaseScreen extends ConsumerStatefulWidget {
  const PurchaseScreen({super.key, required this.order});

  final OrderDetail order;

  @override
  ConsumerState<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends ConsumerState<PurchaseScreen> {
  late final Quote _quote = widget.order.accepted!;
  late final PurchaseChecklist _checklist = PurchaseChecklist(_quote);
  final _ref = TextEditingController();
  final _amount = TextEditingController();
  String _currency = 'EUR';
  bool _busy = false;

  @override
  void dispose() {
    _ref.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _submit({String? decision}) async {
    if (!_checklist.complete) return showInfo(context, 'Cochez ou refusez chaque article.');
    final allRefused = _checklist.bought.isEmpty;
    if (!allRefused && (_ref.text.trim().length < 3 || _amount.text.trim().isEmpty)) {
      return showInfo(context, 'Saisissez la référence et le montant payé sur SHEIN.');
    }
    setState(() => _busy = true);
    try {
      final result = await ref.read(adminApiProvider).purchase(widget.order.id, {
        'store_order_ref': allRefused ? 'AUCUN' : _ref.text.trim(),
        'paid_amount': allRefused ? '0' : _amount.text.trim().replaceAll(',', '.'),
        'currency': _currency,
        'checked_item_ids': _checklist.bought,
        'refused_item_ids': _checklist.refused,
        'price_increase_decision': decision,
      });
      ref.invalidate(orderProvider(widget.order.id));
      if (!mounted) return;
      final refund = (result['refund_xof'] as num).toInt();
      final margin = (result['estimated_margin_xof'] as num).toInt();
      showInfo(
        context,
        allRefused
            ? 'Aucun article acheté : remboursement complet à effectuer.'
            : 'Achat enregistré. Marge estimée ${fcfa(margin)}${refund > 0 ? ' · remboursement ${fcfa(refund)}' : ''}',
      );
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (e.code == 'price_increase_decision_required' && mounted) {
        final choice = await _askDecision();
        if (choice != null) return _submit(decision: choice);
      } else if (mounted) {
        showError(context, e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askDecision() => showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Le prix SHEIN a augmenté'),
          content: const Text('Le montant payé dépasse le devis au-delà de la marge prévue. '
              'Arrêtez-vous avant de payer SHEIN si vous voulez d’abord contacter le client.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'CONTACT_CUSTOMER'), child: const Text('Client contacté')),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () => Navigator.pop(ctx, 'ABSORB'),
              child: const Text('J’absorbe'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    return Scaffold(
      appBar: AppBar(title: Text('Achat · ${order.publicRef}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (order.sourceCartUrl != null)
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              icon: const Icon(Icons.open_in_new_rounded),
              label: const Text('Ouvrir dans SHEIN'),
              onPressed: () => openInShein(context, order.sourceCartUrl!),
            ),
          const SizedBox(height: 12),
          const WarningBox('Vérifiez taille et couleur de chaque article par rapport au devis accepté — '
              'c’est ce que le client a validé, pas le panier SHEIN actuel.'),
          SectionTitle('Devis accepté n°${_quote.version}', trailing: Text(fcfa(_quote.totalXof))),
          Card(
            child: Column(children: [
              for (final l in _quote.lines) _CheckRow(line: l, state: _checklist.states[l.orderItemId]!, onTap: () {
                setState(() => _checklist.cycle(l.orderItemId));
              }),
            ]),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text('Touchez une ligne : ✓ acheté → ✗ indisponible → à faire', style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ),
          const SectionTitle('Commande SHEIN'),
          TextField(
            controller: _ref,
            decoration: const InputDecoration(labelText: 'Numéro de commande SHEIN'),
            textCapitalization: TextCapitalization.characters,
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _amount,
                decoration: const InputDecoration(labelText: 'Montant payé'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              ),
            ),
            const SizedBox(width: 10),
            DropdownButton<String>(
              value: _currency,
              items: const [
                DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                DropdownMenuItem(value: 'USD', child: Text('USD')),
                DropdownMenuItem(value: 'XOF', child: Text('XOF')),
              ],
              onChanged: (v) => setState(() => _currency = v ?? _currency),
            ),
          ]),
          const SizedBox(height: 8),
          Text('Livraison : entrepôt du transitaire, destinataire « ${order.publicRef} / Flariane ».',
              style: const TextStyle(color: AppColors.muted)),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _busy || !_checklist.complete ? null : () => _submit(),
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Enregistrer l’achat'),
          ),
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.line, required this.state, required this.onTap});

  final QuoteLine line;
  final LineCheck state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (state) {
      LineCheck.unchecked => (Icons.check_box_outline_blank_rounded, AppColors.muted, 'à faire'),
      LineCheck.bought => (Icons.check_box_rounded, AppColors.success, 'acheté'),
      LineCheck.refused => (Icons.cancel_rounded, AppColors.danger, 'indisponible'),
    };
    return ListTile(
      onTap: onTap,
      minVerticalPadding: 12,
      leading: Icon(icon, color: color, size: 30, semanticLabel: label),
      title: Text('${line.qty} × ${line.title}', style: TextStyle(decoration: state == LineCheck.refused ? TextDecoration.lineThrough : null)),
      subtitle: Text(line.variant.isEmpty ? '—' : line.variant, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Text(fcfa(line.lineTotalXof)),
    );
  }
}
