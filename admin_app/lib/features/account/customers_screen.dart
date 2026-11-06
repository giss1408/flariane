import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Super admin: every customer account, with search by first name or full phone number.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  late Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() => ref.read(adminApiProvider).customers(q: _search.text.trim());

  void _reload() => setState(() {
        _future = _load();
      });

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Clients')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Prénom ou numéro complet'),
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), _reload);
              },
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: _future,
              builder: (context, snap) {
                if (snap.hasError) return ErrorView(snap.error!, onRetry: _reload);
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final rows = snap.data!;
                if (rows.isEmpty) return const Center(child: Text('Aucun client.'));
                return RefreshIndicator(
                  onRefresh: () async => _reload(),
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final c = rows[i];
                      final blocked = c['blocked'] == true;
                      return Card(
                        child: ListTile(
                          title: Text(c['display_name'] as String? ?? 'Sans prénom', style: const TextStyle(fontWeight: FontWeight.w700)),
                          subtitle: Text('${c['phone_masked']} · ${c['orders_count']} commande${c['orders_count'] == 1 ? '' : 's'}'
                              '${c['phone_verified'] == true ? '' : ' · numéro non vérifié'}'),
                          trailing: blocked
                              ? const Text('Bloqué', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700))
                              : const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerScreen(id: c['id'] as int)));
                            _reload();
                          },
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      );
}

class CustomerScreen extends ConsumerStatefulWidget {
  const CustomerScreen({super.key, required this.id});

  final int id;

  @override
  ConsumerState<CustomerScreen> createState() => _CustomerScreenState();
}

class _CustomerScreenState extends ConsumerState<CustomerScreen> {
  late Future<Map<String, dynamic>> _future = ref.read(adminApiProvider).customerDetail(widget.id);

  void _reload() => setState(() {
        _future = ref.read(adminApiProvider).customerDetail(widget.id);
      });

  Future<void> _block(Map<String, dynamic> c) async {
    final block = c['blocked'] != true;
    final ok = await confirm(context,
        title: block ? 'Bloquer ce client ?' : 'Débloquer ce client ?',
        body: block
            ? 'Il sera déconnecté partout et ne pourra plus se connecter. Ses commandes et ses données sont conservées.'
            : 'Il pourra de nouveau se connecter avec son mot de passe.',
        ok: block ? 'Bloquer' : 'Débloquer');
    if (!ok || !mounted) return;
    try {
      await ref.read(adminApiProvider).blockCustomer(widget.id, block: block);
      _reload();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _delete(Map<String, dynamic> c) async {
    final ok = await confirm(context,
        title: 'Supprimer ce compte ?',
        body: 'Le nom, le numéro et le mot de passe sont effacés définitivement. Les commandes et paiements restent, sans identité, '
            'pour la comptabilité. Impossible si une commande est payée ou en cours.',
        ok: 'Supprimer');
    if (!ok || !mounted) return;
    try {
      await ref.read(adminApiProvider).deleteCustomer(widget.id);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Client')),
        body: FutureBuilder(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!, onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final c = snap.data!;
            final blocked = c['blocked'] == true;
            final orders = (c['recent_orders'] as List).cast<Map<String, dynamic>>();
            return ListView(padding: const EdgeInsets.all(12), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(c['display_name'] as String? ?? 'Sans prénom', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
                    const SizedBox(height: 4),
                    Text('${c['phone_masked']}', style: const TextStyle(color: AppColors.muted)),
                    const SizedBox(height: 8),
                    Text('Inscrit ${ago(DateTime.parse(c['created_at'] as String))} · '
                        '${c['phone_verified'] == true ? 'numéro vérifié' : 'numéro non vérifié'}'),
                    Text('${c['orders_count']} commande${c['orders_count'] == 1 ? '' : 's'} · ${c['loyalty_points']} points'
                        '${c['referral_code'] == null ? '' : ' · code ${c['referral_code']}'}'),
                    if (blocked) ...[
                      const SizedBox(height: 8),
                      const Text('Compte bloqué', style: TextStyle(color: AppColors.danger, fontWeight: FontWeight.w700)),
                    ],
                  ]),
                ),
              ),
              if (orders.isNotEmpty) ...[
                const SectionTitle('Dernières commandes'),
                Card(
                  child: Column(children: [
                    for (final o in orders)
                      ListTile(
                        dense: true,
                        title: Text('${o['public_ref']} · ${o['status']}'),
                        subtitle: Text(ago(DateTime.parse(o['created_at'] as String))),
                        trailing: o['total_xof'] == null ? null : Text('${fcfa(o['total_xof'] as int)} FCFA'),
                      ),
                  ]),
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                icon: Icon(blocked ? Icons.lock_open_rounded : Icons.block_rounded),
                label: Text(blocked ? 'Débloquer le compte' : 'Bloquer le compte'),
                onPressed: () => _block(c),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                label: const Text('Supprimer le compte', style: TextStyle(color: AppColors.danger)),
                onPressed: () => _delete(c),
              ),
            ]);
          },
        ),
      );
}
