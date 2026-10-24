import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/consent_tick.dart';
import '../../widgets/logo.dart';

/// Accounts created before the consent tick box (or after a policy update) accept once.
class ConsentScreen extends ConsumerStatefulWidget {
  const ConsentScreen({super.key});

  @override
  ConsumerState<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends ConsumerState<ConsentScreen> {
  bool _consent = false;
  bool _busy = false;

  Future<void> _accept() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).giveConsent();
      ref.invalidate(meProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: FlarianeHeader(subtitle: 'Confidentialité', showBack: false, actions: [
          TextButton(onPressed: () => ref.read(authProvider.notifier).logout(), child: const Text('Déconnexion')),
        ]),
        body: ListView(padding: const EdgeInsets.all(24), children: [
          Icon(Icons.privacy_tip_rounded, size: 52, color: context.pal.accent),
          const SizedBox(height: 16),
          Text('Ton accord', style: display(28), textAlign: TextAlign.center),
          const SizedBox(height: 10),
          const Text(
            'Ton numéro de téléphone sert à traiter tes commandes : ton compte, tes devis, ton paiement et ton retrait, '
            'avec des messages WhatsApp à leur sujet. Nous ne le partageons pas et tu peux supprimer ton compte à tout moment.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          ConsentTick(value: _consent, onChanged: (v) => setState(() => _consent = v)),
          const SizedBox(height: 20),
          FilledButton(onPressed: !_consent || _busy ? null : _accept, child: const Text('Continuer')),
        ]),
      );
}
