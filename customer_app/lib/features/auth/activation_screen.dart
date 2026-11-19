import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/help.dart';
import '../../widgets/logo.dart';

/// auth: the account exists, the number is not proven yet. The team sends a 6-digit code on WhatsApp; she types it here and is
/// signed in with the phone and password she just entered (kept in memory only).
class ActivationScreen extends ConsumerStatefulWidget {
  const ActivationScreen({super.key});

  @override
  ConsumerState<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends ConsumerState<ActivationScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_code.text.length != 6) {
      setState(() => _error = 'Code à 6 chiffres.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).activate(_code.text);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final phone = ref.watch(pendingLoginProvider)?.phone ?? '';
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    final shown = digits.length >= 4 ? '${digits.substring(0, 2)} •• •• ${digits.substring(digits.length - 2)}' : phone;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              const Center(child: FlarianeLogo(size: 72, withWordmark: true)),
              const SizedBox(height: 24),
              Text('Vérifie ton numéro', style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Text(
                'L’équipe Flariane va t’envoyer un code à 6 chiffres sur WhatsApp au $shown. Saisis-le ici pour activer ton compte.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                autofocus: true,
                textAlign: TextAlign.center,
                maxLength: 6,
                style: const TextStyle(fontSize: 28, letterSpacing: 8),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Code', counterText: ''),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: context.pal.danger)),
              ],
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _submit, child: const Text('Valider')),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => askOnWhatsApp(context, ref, message: 'Bonjour Flariane, je n’ai pas reçu mon code de vérification. Mon numéro : $phone'),
                child: const Text('Je n’ai pas reçu le code'),
              ),
              TextButton(onPressed: () => ref.read(authProvider.notifier).cancelActivation(), child: const Text('Retour')),
            ]),
          ),
        ),
      ),
    );
  }
}
