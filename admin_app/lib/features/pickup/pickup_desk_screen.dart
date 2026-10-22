import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/store_badge.dart';
import '../../widgets/whatsapp.dart';

/// Pickup desk: find the parcel by order number or phone, send the code, validate the pickup.
class PickupDeskScreen extends ConsumerStatefulWidget {
  const PickupDeskScreen({super.key});

  @override
  ConsumerState<PickupDeskScreen> createState() => _PickupDeskScreenState();
}

class _PickupDeskScreenState extends ConsumerState<PickupDeskScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  late Future<List<PickupDeskOrder>> _future = _load();

  Future<List<PickupDeskOrder>> _load() => ref.read(adminApiProvider).pickupDesk(query: _search.text.trim());

  void _reload() => setState(() => _future = _load());

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Retraits')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _search,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search_rounded),
                hintText: 'N° de commande (FLR-…) ou téléphone',
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () {
                        _search.clear();
                        _reload();
                      }),
              ),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 500), _reload);
              },
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => _reload(),
              child: FutureBuilder<List<PickupDeskOrder>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.hasError) return ListView(children: [ErrorView(snap.error!, onRetry: _reload)]);
                  if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                  final list = snap.data!;
                  if (list.isEmpty) {
                    return ListView(children: const [SizedBox(height: 100), Center(child: Text('Aucun colis trouvé.'))]);
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _ParcelCard(order: list[i], onChanged: _reload),
                  );
                },
              ),
            ),
          ),
        ]),
      );
}

class _ParcelCard extends ConsumerWidget {
  const _ParcelCard({required this.order, required this.onChanged});

  final PickupDeskOrder order;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              StoreBadge(order.store, small: true),
              const SizedBox(width: 8),
              Text(order.ref, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              const Spacer(),
              StatusChip(order.status),
            ]),
            const SizedBox(height: 8),
            Text(order.customerName ?? 'Cliente', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Row(children: [
              Text(order.phoneMasked, style: const TextStyle(color: AppColors.muted)),
              TextButton(
                onPressed: () async {
                  try {
                    final phone = await ref.read(adminApiProvider).revealPhone(order.id);
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Téléphone'),
                        content: SelectableText(phone, style: const TextStyle(fontSize: 20)),
                        actions: [
                          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: phone)), child: const Text('Copier')),
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
                        ],
                      ),
                    );
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: const Text('Afficher'),
              ),
            ]),
            if (order.pickupPoint != null) Text('Retrait : ${order.pickupPoint!.name}', style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 10),
            if (order.status == 'ARRIVED')
              FilledButton(onPressed: () => _ready(context, ref), child: const Text('Prête au retrait (envoyer le code)')),
            if (order.status == 'READY_FOR_PICKUP') ...[
              FilledButton(onPressed: () => _validate(context, ref), child: const Text('Valider le retrait')),
              const SizedBox(height: 6),
              OutlinedButton(onPressed: () => _ready(context, ref, resend: true), child: const Text('Renvoyer un code')),
            ],
          ]),
        ),
      );

  Future<void> _ready(BuildContext context, WidgetRef ref, {bool resend = false}) async {
    final api = ref.read(adminApiProvider);
    int? pointId = order.pickupPoint?.id;
    if (!resend) {
      final points = await api.pickupPoints();
      if (!context.mounted) return;
      pointId = await showModalBottomSheet<int>(
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
      if (pointId == null) return;
    }
    try {
      final code = await api.readyForPickup(order.id, pickupPointId: pointId);
      onChanged();
      if (context.mounted) await sendWhatsApp(context, ref, order.id, 'pickup', code: code);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _validate(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Code de retrait · ${order.ref}'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
          style: const TextStyle(fontSize: 24, letterSpacing: 6),
          decoration: const InputDecoration(hintText: '000000'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Valider')),
        ],
      ),
    );
    if (code == null || code.length != 6) return;
    try {
      await ref.read(adminApiProvider).confirmPickup(order.id, code);
      onChanged();
      if (context.mounted) showInfo(context, 'Retrait validé : ${order.ref} (${statusLabels['PICKED_UP']}).');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
