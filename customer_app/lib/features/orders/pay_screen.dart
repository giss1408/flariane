import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

const methods = {
  'WAVE': ('Wave', Color(0xFF1DC3FF)),
  'ORANGE': ('Orange Money', Color(0xFFFF7900)),
  'MOOV': ('Moov Money', Color(0xFF0066B3)),
};

/// She pays from her own mobile-money app, then sends the screenshot of the payment.
/// Flariane checks it and the order becomes "Payée".
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key, required this.orderRef, required this.amountXof, this.declared = false});

  final String orderRef;
  final int amountXof;
  final bool declared;

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  String? _method;
  XFile? _proof;
  late bool _declared = widget.declared;
  bool _busy = false;

  Future<void> _pick() async {
    final f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
    if (f != null) setState(() => _proof = f);
  }

  Future<void> _send() async {
    if (_method == null) return showInfo(context, 'Choisis comment tu as payé.');
    if (_proof == null) return showInfo(context, 'Ajoute la capture de ton paiement.');
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).declarePayment(widget.orderRef, method: _method!, proofPath: _proof!.path);
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
    final info = ref.watch(publicInfoProvider);
    final accounts = ((info.valueOrNull?['payment_accounts'] as Map?) ?? {}).cast<String, dynamic>();
    final hasQr = info.valueOrNull?['has_wave_qr'] == true;
    if (_method == null && accounts.length == 1) _method = accounts.keys.first;
    final number = _method == null ? null : accounts[_method] as String?;

    if (_declared) {
      return Scaffold(
        appBar: const FlarianeHeader(subtitle: 'Paiement'),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.hourglass_top_rounded, size: 56, color: AppColors.primary),
            const SizedBox(height: 16),
            Text('Preuve envoyée !', style: display(26)),
            const SizedBox(height: 8),
            const Text('On vérifie ton paiement et ta commande passe à « Payée ». Tu seras prévenue sur WhatsApp.',
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Retour à ma commande')),
          ]),
        ),
      );
    }

    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Paiement'),
      body: info.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(publicInfoProvider)),
        data: (_) => ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
          const Text('À payer', style: TextStyle(color: AppColors.muted)),
          Text(fcfa(widget.amountXof), style: display(36)),
          const SizedBox(height: 18),
          const Text('1. Choisis ton moyen de paiement', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (accounts.isEmpty)
            const Text('Aucun moyen de paiement n’est configuré pour le moment. Contacte-nous sur WhatsApp.',
                style: TextStyle(color: AppColors.danger))
          else
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final key in accounts.keys)
                ChoiceChip(
                  label: Text(methods[key]?.$1 ?? key),
                  selected: _method == key,
                  onSelected: (_) => setState(() => _method = key),
                  selectedColor: methods[key]?.$2 ?? AppColors.primary,
                  backgroundColor: Colors.white,
                  labelStyle: TextStyle(color: _method == key ? Colors.white : AppColors.plum, fontWeight: FontWeight.w700),
                  showCheckmark: false,
                ),
            ]),
          if (number != null) ...[
            const SizedBox(height: 18),
            Text('2. Envoie ${fcfa(widget.amountXof)} avec ${methods[_method]!.$1}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            if (_method == 'WAVE' && hasQr)
              Center(
                child: Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                  child: Image.network(ref.read(apiProvider).waveQrUrl, width: 200, height: 200),
                ),
              ),
            _CopyTile(label: 'Numéro ${methods[_method]!.$1}', value: number, onCopy: () => _copy(number, 'Numéro')),
            _CopyTile(label: 'Référence à mettre en note', value: widget.orderRef, big: true, onCopy: () => _copy(widget.orderRef, 'Référence')),
            const SizedBox(height: 18),
            const Text('3. Envoie-nous la capture du paiement', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: _pick,
              child: Container(
                height: _proof == null ? 120 : 260,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                child: _proof == null
                    ? const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.add_photo_alternate_outlined, color: AppColors.primary, size: 36),
                        SizedBox(height: 6),
                        Text('Ajouter la capture du paiement', style: TextStyle(fontWeight: FontWeight.w600)),
                      ])
                    : ClipRRect(borderRadius: BorderRadius.circular(17), child: Image.file(File(_proof!.path), fit: BoxFit.cover, width: double.infinity)),
              ),
            ),
          ],
        ]),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _busy || _method == null || _proof == null ? null : _send,
            child: _busy
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Envoyer la preuve de paiement'),
          ),
        ),
      ),
    );
  }
}

class _CopyTile extends StatelessWidget {
  const _CopyTile({required this.label, required this.value, required this.onCopy, this.big = false});

  final String label;
  final String value;
  final VoidCallback onCopy;
  final bool big;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          child: ListTile(
            title: Text(label, style: const TextStyle(color: AppColors.muted, fontSize: 13)),
            subtitle: Text(value,
                style: big ? display(24, color: AppColors.plum) : const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.plum)),
            trailing: IconButton(tooltip: 'Copier', icon: const Icon(Icons.copy_rounded), onPressed: onCopy),
          ),
        ),
      );
}
