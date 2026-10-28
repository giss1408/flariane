import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import 'backoffice_screens.dart';

const roleLabels = {'PICKUP': 'Agent de retrait', 'VIEWER': 'Lecture seule', 'OPERATOR': 'Opérateur', 'SUPER_ADMIN': 'Super admin'};

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(sessionProvider).me;
    return Scaffold(
      appBar: AppBar(title: const Text('Compte')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          child: ListTile(
            leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
            title: Text(me?.name ?? ''),
            subtitle: Text('${me?.email ?? ''}\n${roleLabels[me?.role] ?? me?.role ?? ''} · appareil n°${me?.deviceId ?? '—'}'),
            isThreeLine: true,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Verrouiller maintenant'),
              onTap: () => ref.read(sessionProvider.notifier).lock(),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Se déconnecter'),
              onTap: () async {
                final ok = await confirm(context, title: 'Se déconnecter ?', body: 'L’appareil reste approuvé.', ok: 'Se déconnecter');
                if (ok) await ref.read(sessionProvider.notifier).logout();
              },
            ),
          ]),
        ),
        if (!(me?.isPickupAgent ?? false)) const SectionTitle('Gestion'),
        if (!(me?.isPickupAgent ?? false)) Card(
          child: Column(children: [
            _link(context, Icons.insights_rounded, 'Résumé', const ReportScreen()),
            _link(context, Icons.undo_rounded, 'Remboursements', const RefundsScreen()),
            _link(context, Icons.report_gmailerrorred_rounded, 'Paiements à vérifier', const HeldPaymentsScreen()),
            if (me?.role == 'SUPER_ADMIN') ...[
              _link(context, Icons.phonelink_lock_rounded, 'Appareils', const DevicesScreen()),
              _link(context, Icons.group_rounded, 'Administrateurs', const AdminUsersScreen()),
              _link(context, Icons.place_rounded, 'Points de retrait', const PickupPointsAdminScreen()),
              _link(context, Icons.campaign_rounded, 'Offres clientes', const OffersAdminScreen()),
              _link(context, Icons.tune_rounded, 'Paramètres', const SettingsScreen()),
            ],
          ]),
        ),
        const SizedBox(height: 24),
        const Text('Serveur : ${AppConfig.apiBaseUrl}', textAlign: TextAlign.center, style: TextStyle(fontSize: 12)),
      ]),
    );
  }
}

Widget _link(BuildContext context, IconData icon, String label, Widget page) => ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
    );
