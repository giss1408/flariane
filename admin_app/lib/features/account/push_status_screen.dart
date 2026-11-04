import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../widgets/common.dart';

/// Super admin diagnostics: what the server sees for push alerts, a test button, and the last attempts
/// with the error Firebase returned (a missing service account, a disabled API...).
class PushStatusScreen extends ConsumerStatefulWidget {
  const PushStatusScreen({super.key});

  @override
  ConsumerState<PushStatusScreen> createState() => _PushStatusScreenState();
}

class _PushStatusScreenState extends ConsumerState<PushStatusScreen> {
  late Future<Map<String, dynamic>> _status = ref.read(adminApiProvider).pushStatus();
  bool _testing = false;

  Future<void> _test() async {
    setState(() => _testing = true);
    try {
      final r = await ref.read(adminApiProvider).pushTest();
      if (!mounted) return;
      showInfo(context, r['ok'] == true ? 'Test envoyé : tu dois recevoir l’alerte.' : 'Échec : ${r['error']}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notifications')),
        body: FutureBuilder<Map<String, dynamic>>(
          future: _status,
          builder: (context, snap) {
            if (snap.hasError) return Center(child: Text('Erreur : ${snap.error}'));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final s = snap.data!;
            final devices = (s['devices'] as List).cast<Map<String, dynamic>>();
            final recent = (s['recent'] as List).cast<Map<String, dynamic>>();
            return RefreshIndicator(
              onRefresh: () async => setState(() => _status = ref.read(adminApiProvider).pushStatus()),
              child: ListView(padding: const EdgeInsets.all(16), children: [
                ListTile(
                  leading: Icon(s['mode'] == 'live' ? Icons.check_circle_rounded : Icons.warning_amber_rounded),
                  title: Text('Mode : ${s['mode']}'),
                  subtitle: Text('Projet Firebase : ${s['project_id']}\nClé de service sur le serveur : ${s['has_service_account'] == true ? 'oui' : 'NON (aucune alerte ne partira)'}'),
                ),
                FilledButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: const Icon(Icons.send_rounded),
                  label: Text(_testing ? 'Envoi…' : 'Envoyer un test à ce téléphone'),
                ),
                const SizedBox(height: 16),
                const Text('Appareils', style: TextStyle(fontWeight: FontWeight.w700)),
                for (final d in devices)
                  ListTile(
                    dense: true,
                    title: Text('n°${d['id']} · ${d['name']}'),
                    subtitle: Text('${d['approved'] == true ? 'approuvé' : 'en attente'} · ${d['has_push_token'] == true ? 'jeton push enregistré' : 'PAS de jeton push'}'),
                  ),
                const SizedBox(height: 16),
                const Text('Dernières alertes', style: TextStyle(fontWeight: FontWeight.w700)),
                if (recent.isEmpty) const ListTile(dense: true, title: Text('Aucune alerte n’a été tentée par le serveur.')),
                for (final n in recent)
                  ListTile(
                    dense: true,
                    leading: Icon(n['status'] == 'SENT' ? Icons.check_rounded : Icons.error_outline_rounded),
                    title: Text('${n['event']} · ${n['status']}'),
                    subtitle: Text('${n['at']}${n['error'] != null ? '\n${n['error']}' : ''}'),
                  ),
              ]),
            );
          },
        ),
      );
}
