import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';
import 'legal_doc_screen.dart';

IconData _icon(String key) => switch (key) {
      'route' => Icons.directions_boat_rounded,
      'description' => Icons.description_outlined,
      'undo' => Icons.undo_rounded,
      'privacy' => Icons.privacy_tip_outlined,
      'business' => Icons.business_outlined,
      _ => Icons.article_outlined,
    };

/// "Infos et légal": how it works, terms, refunds, privacy, legal notice, and what we know about her.
class LegalHubScreen extends ConsumerWidget {
  const LegalHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docs = ref.watch(legalDocsProvider);
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Infos et légal'),
      body: docs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(legalDocsProvider)),
        data: (list) => RefreshIndicator(
          onRefresh: () => ref.refresh(legalDocsProvider.future),
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('Tout est écrit simplement : le résumé d’abord, le détail ensuite.', style: TextStyle(color: context.pal.muted, height: 1.4)),
            const SizedBox(height: 12),
            for (final d in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    leading: CircleAvatar(backgroundColor: context.pal.lilac, child: Icon(_icon(d.icon), color: context.pal.accent)),
                    title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(d.summary.first, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalDocScreen(slug: d.slug, title: d.title))),
                  ),
                ),
              ),
            Card(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: CircleAvatar(backgroundColor: context.pal.lilac, child: Icon(Icons.folder_shared_outlined, color: context.pal.accent)),
                title: const Text('Mes données', style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Ce que Flariane sait de toi, et tes droits'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MyDataScreen())),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// What we hold about her (law 2013-450): read it, copy it, and how to correct or delete it.
class MyDataScreen extends ConsumerWidget {
  const MyDataScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(myDataProvider);
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Mes données'),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(myDataProvider)),
        data: (d) {
          final me = (d['customer'] as Map?)?.cast<String, dynamic>() ?? const {};
          final orders = ((d['orders'] as List?) ?? const []).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('Voici ce que nous gardons à ton sujet. Tu peux le copier, le faire corriger ou supprimer ton compte.', style: TextStyle(color: context.pal.muted, height: 1.4)),
            const SizedBox(height: 12),
            Card(
              child: Column(children: [
                _Row('Prénom', me['display_name'] as String? ?? '—'),
                _Row('Téléphone', me['phone'] as String? ?? '—'),
                _Row('Inscrit le', _day(me['created_at'] as String?)),
                _Row('Commandes', '${orders.length}'),
              ]),
            ),
            if (orders.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Tes commandes', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
              const SizedBox(height: 8),
              Card(
                child: Column(children: [
                  for (final o in orders)
                    ListTile(
                      dense: true,
                      title: Text('${o['ref']}'),
                      subtitle: Text(_day(o['created_at'] as String?)),
                      trailing: Text(o['total_xof'] == null ? '—' : '${fcfa(o['total_xof'] as int)} FCFA'),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Copier toutes mes données'),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(d)));
                showInfo(context, 'Données copiées.');
              },
            ),
            const SizedBox(height: 16),
            const _Rights(),
          ]);
        },
      ),
    );
  }

  static String _day(String? iso) {
    final t = iso == null ? null : DateTime.tryParse(iso);
    return t == null ? '—' : date(t);
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(label, style: TextStyle(color: context.pal.muted)),
        trailing: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
}

class _Rights extends StatelessWidget {
  const _Rights();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: context.pal.lilac, borderRadius: BorderRadius.circular(20)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (i, t) in const [
            'Corriger : change ton prénom dans Mon compte, ou écris-nous pour le reste.',
            'Supprimer : Mon compte › Supprimer mon compte. Tes données personnelles sont effacées ; seuls les montants des commandes payées restent, sans ton identité.',
            'Une question sur tes droits (loi ivoirienne 2013-450) ? Utilise le bouton « Une question ? ».',
          ].indexed)
            Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : 10), child: Text(t, style: const TextStyle(height: 1.45))),
        ]),
      );
}
