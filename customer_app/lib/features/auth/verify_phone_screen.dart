import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/logo.dart';

/// Shown after sign-up until the number is confirmed with the code Flariane sends on WhatsApp.
class VerifyPhoneScreen extends ConsumerStatefulWidget {
  const VerifyPhoneScreen({super.key, required this.phoneMasked});

  final String phoneMasked;

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

  @override
  Widget build(BuildContext context) => Scaffold(
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
          ]),
        ),
      );
}
