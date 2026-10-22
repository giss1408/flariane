import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/logo.dart';

/// Shown after sign-up until the number is confirmed with the code Flariane sends on WhatsApp.
class VerifyPhoneScreen extends ConsumerStatefulWidget {
  const VerifyPhoneScreen({super.key, required this.phoneMasked, this.rejected = false});

  final String phoneMasked;
  final bool rejected; // the team couldn't verify this number

  @override
  ConsumerState<VerifyPhoneScreen> createState() => _VerifyPhoneScreenState();
}

class _VerifyPhoneScreenState extends ConsumerState<VerifyPhoneScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_code.text.length != 6) return setState(() => _error = 'Le code a 6 chiffres.');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).verifyPhone(_code.text);
      ref.invalidate(meProvider);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changeNumber() async {
    final c = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ton bon numéro WhatsApp'),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: TextInputType.phone,
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 +]')), LengthLimitingTextInputFormatter(17)],
          decoration: const InputDecoration(hintText: '07 01 02 03 04'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (phone == null || phone.isEmpty) return;
    try {
      await ref.read(apiProvider).changePhone(phone);
      ref.invalidate(meProvider);
      setState(() => _error = null);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) => widget.rejected ? _rejected() : _waiting();

  Widget _rejected() => Scaffold(
        appBar: FlarianeHeader(subtitle: 'Vérification', showBack: false, actions: [
          TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Déconnexion')),
        ]),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          const Icon(Icons.error_outline_rounded, size: 56, color: AppColors.danger),
          const SizedBox(height: 16),
          Text('Numéro non vérifié', style: display(28), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          const Text(
            'Nous n’avons pas pu vérifier ton numéro sur WhatsApp (numéro faux ou sans WhatsApp). '
            'Indique ton bon numéro WhatsApp pour recevoir ton code.',
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: _changeNumber, child: const Text('Saisir mon bon numéro')),
        ]),
      );

  Widget _waiting() => Scaffold(
        appBar: FlarianeHeader(subtitle: 'Vérification', showBack: false, actions: [
          TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Déconnexion')),
        ]),
        body: RefreshIndicator(
          onRefresh: () async => ref.invalidate(meProvider),
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const Icon(Icons.mark_chat_read_rounded, size: 56, color: AppColors.success),
            const SizedBox(height: 16),
            Text('Vérifie ton numéro', style: display(28), textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              'L’équipe Flariane va t’envoyer un code à 6 chiffres sur WhatsApp au ${widget.phoneMasked}. '
              'Saisis-le ici pour activer ton compte.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              autofillHints: const [AutofillHints.oneTimeCode],
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              style: const TextStyle(fontSize: 28, letterSpacing: 10, fontWeight: FontWeight.w700),
              decoration: const InputDecoration(hintText: '000000'),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.danger)),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : _submit, child: const Text('Valider mon numéro')),
            const SizedBox(height: 16),
            const Text(
              'Le code arrive en général dans l’heure, aux horaires d’ouverture. '
              'Rien reçu ? Vérifie que ton numéro est bien sur WhatsApp.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
            TextButton(onPressed: _changeNumber, child: const Text('Mon numéro est faux ? Le corriger')),
          ]),
        ),
      );
}
