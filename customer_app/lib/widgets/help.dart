import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers.dart';
import '../core/theme.dart';
import 'common.dart';
import 'store_badge.dart';

/// Opens WhatsApp to Flariane's support number with the order reference pre-filled.
Future<void> askOnWhatsApp(BuildContext context, WidgetRef ref, {String? orderRef}) async {
  final number = (await ref.read(publicInfoProvider.future))['support_whatsapp'] as String?;
  if (number == null || number.isEmpty) {
    if (context.mounted) showInfo(context, 'Le support WhatsApp n’est pas encore disponible.');
    return;
  }
  var digits = number.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 10 && digits.startsWith('0')) digits = '225$digits';
  final text = orderRef == null ? 'Bonjour Flariane, j’ai une question : ' : 'Bonjour Flariane, j’ai une question sur ma commande $orderRef : ';
  await launchUrl(Uri.parse('https://wa.me/$digits?text=${Uri.encodeComponent(text)}'), mode: LaunchMode.externalApplication);
}

/// Step by step: how to send a SHEIN or Temu cart to Flariane.
void showShareHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ShareHelp(),
    );

/// How to reach the team, then a button that does it.
void showAskHelp(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _AskHelp(),
    );

class _ShareHelp extends StatelessWidget {
  const _ShareHelp();

  static const _shein = [
    'Ouvre l’app SHEIN et remplis ton panier (tailles et couleurs choisies).',
    'Touche le sac 🛍️ pour ouvrir ton panier.',
    'Touche l’icône Partager en haut à droite du panier.',
    'Choisis Flariane dans la liste. Si Flariane n’y est pas, touche « Copier le lien ».',
    'Reviens dans Flariane : « Envoyer mon panier », puis l’icône Coller.',
  ];

  static const _temu = [
    'Ouvre l’app Temu et ouvre un article que tu veux.',
    'Touche l’icône Partager sur la page de l’article.',
    'Choisis Flariane, ou « Copier le lien » puis colle-le dans Flariane.',
    'Plusieurs articles ? Envoie un lien, puis ajoute des captures d’écran de ton panier Temu.',
  ];

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.72,
            child: Column(children: [
              Text('Comment partager mon panier', style: display(22, weight: FontWeight.w700)),
              const SizedBox(height: 8),
              const TabBar(tabs: [Tab(child: StoreBadge('SHEIN')), Tab(child: StoreBadge('TEMU'))]),
              const Expanded(child: TabBarView(children: [_StepList(_shein), _StepList(_temu)])),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'Tu n’y arrives pas ? Fais des captures d’écran de ton panier et ajoute-les avec « Ajouter une capture du panier ».',
                  style: TextStyle(color: context.pal.muted),
                ),
              ),
            ]),
          ),
        ),
      );
}

class _StepList extends StatelessWidget {
  const _StepList(this.steps);

  final List<String> steps;

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        for (final (i, s) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: context.pal.lilac,
                child: Text('${i + 1}', style: TextStyle(color: context.pal.accent, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(width: 12),
              Expanded(child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(s, style: const TextStyle(fontSize: 15)))),
            ]),
          ),
      ]);
}

class _AskHelp extends ConsumerWidget {
  const _AskHelp();

  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Poser une question à l’équipe', style: display(22, weight: FontWeight.w700)),
            const SizedBox(height: 12),
            const _StepList([
              'Touche le bouton vert « Une question ? » en bas de l’écran d’accueil ou d’une commande.',
              'WhatsApp s’ouvre avec un message déjà commencé (et le numéro de ta commande).',
              'Écris ta question et envoie : l’équipe Flariane te répond sur WhatsApp.',
            ]),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF25D366), foregroundColor: Colors.white, minimumSize: const Size.fromHeight(50)),
              icon: const Icon(Icons.chat_rounded),
              label: const Text('Écrire à l’équipe sur WhatsApp'),
              onPressed: () => askOnWhatsApp(context, ref),
            ),
          ]),
        ),
      );
}

/// Always-visible "Une question ?" button, placed above the bottom safe area.
class AskButton extends ConsumerWidget {
  const AskButton({super.key, this.orderRef});

  final String? orderRef;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FloatingActionButton.extended(
        heroTag: 'ask',
        backgroundColor: const Color(0xFF25D366),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.chat_rounded),
        label: const Text('Une question ?'),
        onPressed: () => askOnWhatsApp(context, ref, orderRef: orderRef),
      );
}
