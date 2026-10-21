import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

/// Pay with Wave by scanning Flariane's QR (or sending to its number), then tell us.
/// Flariane checks its Wave app and confirms; the order then becomes "Payée".
class WavePayScreen extends ConsumerStatefulWidget {
  const WavePayScreen({super.key, required this.orderRef, required this.amountXof, this.declared = false});

  final String orderRef;
  final int amountXof;
  final bool declared;

  @override
  ConsumerState<WavePayScreen> createState() => _WavePayScreenState();
}

class _WavePayScreenState extends ConsumerState<WavePayScreen> {
  late bool _declared = widget.declared;
  bool _busy = false;

  Future<void> _declare() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).declarePayment(widget.orderRef);
      ref.invalidate(orderProvider(widget.orderRef));
      setState(() => _declared = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    showInfo(context, '$what copié');
  }

  @override
  Widget build(BuildContext context) {
    final info = ref.watch(publicInfoProvider).valueOrNull;
    final phone = info?['wave_phone'] as String?;
    final hasQr = info?['has_wave_qr'] == true;
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Payer avec Wave'),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
        const Text('À payer', style: TextStyle(color: AppColors.muted)),
        Text(fcfa(widget.amountXof), style: display(36)),
        const SizedBox(height: 16),
        if (hasQr)
          Center(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(22)),
              child: Image.network(ref.read(apiProvider).waveQrUrl, width: 240, height: 240, fit: BoxFit.contain),
            ),
          ),
        const SizedBox(height: 16),
        _Step(n: 1, text: hasQr ? 'Ouvre Wave et scanne ce QR code' : 'Ouvre Wave et envoie le montant à Flariane'),
        if (phone != null)
          _CopyRow(label: 'Numéro Wave Flariane', value: phone, onCopy: () => _copy(phone, 'Numéro')),
        _Step(n: 2, text: 'Envoie exactement ${fcfa(widget.amountXof)}'),
        const _Step(n: 3, text: 'Mets ta référence de commande en note'),
        _CopyRow(label: 'Référence', value: widget.orderRef, big: true, onCopy: () => _copy(widget.orderRef, 'Référence')),
        const _Step(n: 4, text: 'Reviens ici et touche « J’ai payé »'),
        const SizedBox(height: 20),
        if (_declared)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: const Color(0xFFD9F7EE), borderRadius: BorderRadius.circular(18)),
            child: const Text(
              'Merci ! On vérifie ton paiement dans Wave et ta commande passe à « Payée ». Tu seras prévenue sur WhatsApp.',
              style: TextStyle(color: AppColors.success, fontWeight: FontWeight.w600),
            ),
          ),
      ]),
      bottomNavigationBar: _declared
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: FilledButton(onPressed: _busy ? null : _declare, child: const Text('J’ai payé')),
              ),
            ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});

  final int n;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          CircleAvatar(radius: 13, backgroundColor: AppColors.primary, child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 13))),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value, required this.onCopy, this.big = false});

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool big;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 36, bottom: 6),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            title: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            subtitle: Text(value, style: big ? display(24, color: AppColors.plum) : const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.plum)),
            trailing: IconButton(tooltip: 'Copier', icon: const Icon(Icons.copy_rounded), onPressed: onCopy),
          ),
        ),
      );
}
