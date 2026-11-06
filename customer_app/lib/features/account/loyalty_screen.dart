import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

/// "Mes points": balance, progress toward the next reduction, referral code and why the balance changed.
class LoyaltyScreen extends ConsumerWidget {
  const LoyaltyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loyalty = ref.watch(loyaltyProvider);
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Mes points'),
      body: loyalty.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(loyaltyProvider)),
        data: (l) => RefreshIndicator(
          onRefresh: () => ref.refresh(loyaltyProvider.future),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            _Balance(l),
            if (l.referralCode != null) ...[const SizedBox(height: 12), _ReferralCard(l)],
            const SizedBox(height: 12),
            _Rules(l),
            const SizedBox(height: 16),
            const Text('Historique', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
            const SizedBox(height: 8),
            if (l.history.isEmpty)
              Text('Tes points apparaîtront ici dès ton premier colis retiré.', style: TextStyle(color: context.pal.muted))
            else
              for (final e in l.history) _EventTile(e),
          ]),
        ),
      ),
    );
  }
}

class _Balance extends StatelessWidget {
  const _Balance(this.l);

  final Loyalty l;

  @override
  Widget build(BuildContext context) {
    final progress = (l.balance / l.redeemPoints).clamp(0.0, 1.0);
    final missing = l.redeemPoints - l.balance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${l.balance}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 40)),
            const SizedBox(width: 6),
            const Padding(padding: EdgeInsets.only(bottom: 8), child: Text('pts')),
          ]),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progress, minHeight: 8, borderRadius: BorderRadius.circular(4)),
          const SizedBox(height: 8),
          Text(
            missing > 0
                ? 'Encore $missing pts pour −${l.discountPercent} % sur les frais de service d’une commande.'
                : 'Tu peux utiliser ${l.redeemPoints} pts : −${l.discountPercent} % sur les frais de service de ton prochain devis.',
          ),
          const SizedBox(height: 8),
          Text('Les points sont crédités au retrait du colis', style: TextStyle(color: context.pal.muted)),
        ]),
      ),
    );
  }
}

class _ReferralCard extends StatelessWidget {
  const _ReferralCard(this.l);

  final Loyalty l;

  String get _message => 'Je commande mes paniers SHEIN et Temu avec Flariane. '
      'Inscris-toi avec mon code ${l.referralCode} : je gagne des points quand tu commandes !';

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ton code de parrainage', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Row(children: [
              Text(l.referralCode!, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 24, letterSpacing: 1.5)),
              const Spacer(),
              IconButton(
                tooltip: 'Copier',
                icon: const Icon(Icons.copy_rounded),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: l.referralCode!));
                  showInfo(context, 'Code copié.');
                },
              ),
            ]),
            const SizedBox(height: 8),
            FilledButton.icon(
              icon: const Icon(Icons.share_rounded),
              label: const Text('Partager sur WhatsApp'),
              onPressed: () => launchUrl(Uri.parse('https://wa.me/?text=${Uri.encodeComponent(_message)}'), mode: LaunchMode.externalApplication),
            ),
          ]),
        ),
      );
}

class _Rules extends StatelessWidget {
  const _Rules(this.l);

  final Loyalty l;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Comment ça marche', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('• +${l.pointsPerOrder} pts par commande retirée'),
            Text('• +${l.pointsReferralSignup} pt par amie parrainée'),
            Text('• +${l.pointsReferredOrder} pts quand elle retire sa première commande'),
            Text('• ${l.redeemPoints} pts = −${l.discountPercent} % sur les frais de service d’une commande'),
          ]),
        ),
      );
}

class _EventTile extends StatelessWidget {
  const _EventTile(this.e);

  final LoyaltyEvent e;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(e.label),
        subtitle: Text(dateTime(e.createdAt)),
        trailing: Text(
          '${e.points > 0 ? '+' : ''}${e.points} pts',
          style: TextStyle(fontWeight: FontWeight.w700, color: e.points > 0 ? context.pal.success : context.pal.muted),
        ),
      );
}
