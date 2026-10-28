import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';

/// Generic "load a list, show it, act on rows" screen used by the back-office pages.
class _ListPage extends ConsumerStatefulWidget {
  const _ListPage({required this.title, required this.load, required this.tile, this.fab});

  final String title;
  final Future<List<Map<String, dynamic>>> Function(WidgetRef ref) load;
  final Widget Function(BuildContext context, Map<String, dynamic> row, VoidCallback reload) tile;
  final Widget Function(BuildContext context, VoidCallback reload)? fab;

  @override
  ConsumerState<_ListPage> createState() => _ListPageState();
}

class _ListPageState extends ConsumerState<_ListPage> {
  late Future<List<Map<String, dynamic>>> _future = widget.load(ref);

  void _reload() => setState(() => _future = widget.load(ref));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        floatingActionButton: widget.fab?.call(context, _reload),
        body: FutureBuilder(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!, onRetry: _reload);
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final rows = snap.data!;
            if (rows.isEmpty) return const Center(child: Text('Rien à afficher.'));
            return RefreshIndicator(
              onRefresh: () async => _reload(),
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                itemCount: rows.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) => Card(child: widget.tile(context, rows[i], _reload)),
              ),
            );
          },
        ),
      );
}

Future<void> _act(BuildContext context, Future<void> Function() action, VoidCallback reload, {String? done}) async {
  try {
    await action();
    reload();
    if (done != null && context.mounted) showInfo(context, done);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<String?> _ask(BuildContext context, String title, String label) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: c, autofocus: true, decoration: InputDecoration(labelText: label)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Valider')),
      ],
    ),
  );
}

class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Appareils',
        load: (ref) => ref.read(adminApiProvider).devices(),
        tile: (context, d, reload) {
          final api = ref.read(adminApiProvider);
          final revoked = d['revoked_at'] != null;
          final approved = d['approved_at'] != null;
          return ListTile(
            leading: Icon(d['platform'] == 'ios' ? Icons.phone_iphone : Icons.phone_android),
            title: Text('n°${d['id']} · ${d['name']}'),
            subtitle: Text('Admin ${d['admin_user_id']} · ${revoked ? 'révoqué' : approved ? 'approuvé' : 'EN ATTENTE'}'),
            trailing: revoked
                ? null
                : approved
                    ? TextButton(
                        onPressed: () async {
                          if (await confirm(context, title: 'Révoquer l’appareil ?', body: 'Accès coupé immédiatement.', ok: 'Révoquer')) {
                            if (context.mounted) await _act(context, () => api.revokeDevice(d['id'] as int), reload);
                          }
                        },
                        child: const Text('Révoquer', style: TextStyle(color: AppColors.danger)),
                      )
                    : FilledButton(
                        style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                        onPressed: () => _act(context, () => api.approveDevice(d['id'] as int), reload, done: 'Appareil approuvé.'),
                        child: const Text('Approuver'),
                      ),
          );
        },
      );
}

class RefundsScreen extends ConsumerWidget {
  const RefundsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Remboursements',
        load: (ref) => ref.read(adminApiProvider).refunds(),
        tile: (context, r, reload) => ListTile(
          title: Text('${fcfa((r['amount_xof'] as num).toInt())} · commande ${r['order_id']}'),
          subtitle: Text('${r['reason']}\n${r['status'] == 'COMPLETED' ? 'Remboursé (${r['external_ref']})' : 'À rembourser via Wave Business'}'),
          isThreeLine: true,
          trailing: r['status'] == 'PENDING'
              ? FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: () async {
                    final ext = await _ask(context, 'Remboursement effectué', 'Référence de transaction Wave');
                    if (ext == null || ext.length < 3 || !context.mounted) return;
                    await _act(context, () => ref.read(adminApiProvider).completeRefund(r['id'] as int, ext), reload,
                        done: 'Client prévenu sur WhatsApp.');
                  },
                  child: const Text('Fait'),
                )
              : const Icon(Icons.check_circle, color: AppColors.success),
        ),
      );
}

class HeldPaymentsScreen extends ConsumerWidget {
  const HeldPaymentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Paiements à vérifier',
        load: (ref) => ref.read(adminApiProvider).heldPayments(),
        tile: (context, p, reload) => ListTile(
          title: Text('${p['order_ref']} · ${fcfa((p['amount_xof'] as num).toInt())}'),
          subtitle: Text('${p['reason']}\nWave ${p['provider_txn_id'] ?? '—'}'),
          isThreeLine: true,
          trailing: TextButton(
            onPressed: () async {
              if (await confirm(context, title: 'Rembourser ce paiement ?', body: 'Un remboursement complet sera créé.', ok: 'Rembourser')) {
                if (context.mounted) await _act(context, () => ref.read(adminApiProvider).refundHeldPayment(p['payment_id'] as int), reload);
              }
            },
            child: const Text('Rembourser'),
          ),
        ),
      );
}

class PickupPointsAdminScreen extends ConsumerWidget {
  const PickupPointsAdminScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, VoidCallback reload, [Map<String, dynamic>? p]) async {
    final fields = {
      'name': TextEditingController(text: p?['name'] as String?),
      'address': TextEditingController(text: p?['address'] as String?),
      'commune': TextEditingController(text: p?['commune'] as String?),
      'opening_hours': TextEditingController(text: p?['opening_hours'] as String?),
    };
    const labels = {'name': 'Nom', 'address': 'Adresse', 'commune': 'Commune', 'opening_hours': 'Horaires'};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(p == null ? 'Nouveau point' : 'Modifier le point'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final e in fields.entries)
              Padding(padding: const EdgeInsets.only(bottom: 8), child: TextField(controller: e.value, decoration: InputDecoration(labelText: labels[e.key]))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await _act(
      context,
      () => ref.read(adminApiProvider).savePickupPoint(
            {for (final e in fields.entries) e.key: e.value.text.trim(), 'active': p?['active'] ?? true},
            id: p?['id'] as int?,
          ),
      reload,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Points de retrait',
        load: (ref) async => [
          for (final p in await ref.read(adminApiProvider).pickupPoints())
            {'id': p.id, 'name': p.name, 'address': p.address, 'commune': p.commune, 'opening_hours': p.openingHours, 'active': true},
        ],
        fab: (context, reload) => FloatingActionButton(onPressed: () => _edit(context, ref, reload), child: const Icon(Icons.add)),
        tile: (context, p, reload) => ListTile(
          title: Text(p['name'] as String),
          subtitle: Text('${p['address']} · ${p['opening_hours']}'),
          onTap: () => _edit(context, ref, reload, p),
        ),
      );
}

/// Offers shown to every customer on the app's home screen ("-10 % sur tes 20 premières commandes").
class OffersAdminScreen extends ConsumerWidget {
  const OffersAdminScreen({super.key});

  static DateTime? _end(Map<String, dynamic> o) => o['ends_at'] == null ? null : DateTime.parse(o['ends_at'] as String).toLocal();

  static bool _ended(Map<String, dynamic> o) => _end(o)?.isBefore(DateTime.now()) ?? false;

  Future<void> _edit(BuildContext context, WidgetRef ref, VoidCallback reload, [Map<String, dynamic>? o]) async {
    final title = TextEditingController(text: o?['title'] as String?);
    final message = TextEditingController(text: o?['message'] as String?);
    DateTime? ends = o == null ? null : _end(o);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(o == null ? 'Nouvelle offre' : 'Modifier l’offre'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: title, maxLength: 80, decoration: const InputDecoration(labelText: 'Titre', hintText: '-10 % sur tes 20 premières commandes')),
              TextField(controller: message, maxLength: 240, maxLines: 3, decoration: const InputDecoration(labelText: 'Message (facultatif)')),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event_rounded),
                title: Text(ends == null ? 'Sans date de fin' : 'Jusqu’au ${DateFormat('d MMMM', 'fr').format(ends!)}'),
                trailing: ends == null
                    ? null
                    : IconButton(tooltip: 'Retirer la date de fin', icon: const Icon(Icons.close_rounded), onPressed: () => setState(() => ends = null)),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: ends ?? DateTime.now().add(const Duration(days: 7)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                  );
                  if (picked != null) setState(() => ends = DateTime(picked.year, picked.month, picked.day, 23, 59));
                },
              ),
            ]),
          ),
          actions: [
            if (o != null) TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Supprimer', style: TextStyle(color: AppColors.danger))),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
            TextButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Enregistrer')),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    final api = ref.read(adminApiProvider);
    if (action == 'delete') {
      final ok = await confirm(context, title: 'Supprimer cette offre ?', body: 'Elle disparaît de l’écran d’accueil des clientes.', ok: 'Supprimer');
      if (!ok || !context.mounted) return;
      return _act(context, () => api.deleteOffer(o!['id'] as int), reload);
    }
    if (title.text.trim().isEmpty) return showInfo(context, 'Le titre est obligatoire.');
    final body = {'title': title.text.trim(), 'message': message.text.trim(), 'ends_at': ends?.toUtc().toIso8601String()};
    await _act(context, () => o == null ? api.createOffer({...body, 'active': true}) : api.updateOffer(o['id'] as int, body), reload);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Offres clientes',
        load: (ref) => ref.read(adminApiProvider).offers(),
        fab: (context, reload) =>
            FloatingActionButton.extended(onPressed: () => _edit(context, ref, reload), icon: const Icon(Icons.add), label: const Text('Nouvelle offre')),
        tile: (context, o, reload) {
          final ended = _ended(o);
          final end = _end(o);
          final live = (o['active'] as bool) && !ended;
          return ListTile(
            title: Text(o['title'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text([
              if ((o['message'] as String).isNotEmpty) o['message'] as String,
              if (end == null) 'Sans date de fin' else '${ended ? 'Terminée le' : 'Jusqu’au'} ${DateFormat('d MMMM', 'fr').format(end)}',
              live ? 'Visible par les clientes' : (ended ? 'Terminée' : 'Désactivée'),
            ].join('\n')),
            isThreeLine: true,
            trailing: Switch(
              value: live,
              onChanged: ended ? null : (v) => _act(context, () => ref.read(adminApiProvider).updateOffer(o['id'] as int, {'active': v}), reload),
            ),
            onTap: () => _edit(context, ref, reload, o),
          );
        },
      );
}

class AdminUsersScreen extends ConsumerWidget {
  const AdminUsersScreen({super.key});

  Future<void> _create(BuildContext context, WidgetRef ref, VoidCallback reload) async {
    final email = TextEditingController();
    final name = TextEditingController();
    final password = TextEditingController();
    var role = 'OPERATOR';
    var totpRequired = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Nouvel administrateur'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: email, decoration: const InputDecoration(labelText: 'Email'), keyboardType: TextInputType.emailAddress),
              const SizedBox(height: 8),
              TextField(controller: name, decoration: const InputDecoration(labelText: 'Nom')),
              const SizedBox(height: 8),
              TextField(controller: password, obscureText: true, decoration: const InputDecoration(labelText: 'Mot de passe (12+ caractères)')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: role,
                items: const [
                  DropdownMenuItem(value: 'PICKUP', child: Text('Agent de retrait')),
                  DropdownMenuItem(value: 'VIEWER', child: Text('Lecture seule')),
                  DropdownMenuItem(value: 'OPERATOR', child: Text('Opérateur')),
                  DropdownMenuItem(value: 'SUPER_ADMIN', child: Text('Super admin')),
                ],
                onChanged: (v) => setState(() => role = v ?? role),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: role == 'SUPER_ADMIN' || totpRequired,
                onChanged: role == 'SUPER_ADMIN' ? null : (v) => setState(() => totpRequired = v ?? true),
                title: const Text('Code d’authentification requis'),
                subtitle: Text(role == 'SUPER_ADMIN'
                    ? 'Toujours requis pour un super admin'
                    : 'Sans code : connexion par mot de passe, seulement depuis un téléphone approuvé'),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Créer')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final uri = await ref.read(adminApiProvider).createAdminUser(
          {'email': email.text.trim(), 'name': name.text.trim(), 'password': password.text, 'role': role, 'totp_required': totpRequired});
      reload();
      if (!context.mounted) return;
      if (uri == null) {
        showInfo(context, 'Administrateur créé (sans code). Approuve son téléphone dans Appareils après sa première connexion.');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Clé d’authentification'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('À ajouter dans l’application d’authentification du nouvel admin. Affichée une seule fois.'),
            const SizedBox(height: 12),
            SelectableText(uri, style: const TextStyle(fontSize: 12)),
          ]),
          actions: [
            TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: uri)), child: const Text('Copier')),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ListPage(
        title: 'Administrateurs',
        load: (ref) => ref.read(adminApiProvider).adminUsers(),
        fab: (context, reload) => FloatingActionButton(onPressed: () => _create(context, ref, reload), child: const Icon(Icons.person_add)),
        tile: (context, u, reload) => ListTile(
          title: Text('${u['name']} · ${u['role']}'),
          subtitle: Text('${u['email']}${u['totp_required'] == false ? ' · sans code' : ''}'),
          trailing: u['id'] == ref.read(sessionProvider).me?.id
              ? const Text('Vous')
              : PopupMenuButton<String>(
                  onSelected: (action) async {
                    final api = ref.read(adminApiProvider);
                    if (action == 'totp_on' || action == 'totp_off') {
                      await _act(context, () => api.setTotpRequired(u['id'] as int, action == 'totp_on'), reload,
                          done: action == 'totp_on' ? 'Code désormais requis.' : 'Code plus requis (téléphone approuvé obligatoire).');
                      return;
                    }
                    if (action == 'remove') {
                      if (await confirm(context, title: 'Supprimer ${u['name']} ?', body: 'Son accès est coupé immédiatement sur tous ses appareils.', ok: 'Supprimer')) {
                        if (context.mounted) await _act(context, () => api.deactivateAdminUser(u['id'] as int), reload, done: 'Administrateur supprimé.');
                      }
                      return;
                    }
                    if (!await confirm(context, title: 'Nouveaux identifiants ?', body: 'Un nouveau mot de passe et une nouvelle clé d’authentification sont créés. Ses appareils sont déconnectés.', ok: 'Générer')) return;
                    try {
                      final c = await api.resetAdminCredentials(u['id'] as int);
                      if (!context.mounted) return;
                      await showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Nouveaux identifiants'),
                          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Text('Affichés une seule fois. Transmets-les de façon sûre.'),
                            const SizedBox(height: 12),
                            const Text('Mot de passe', style: TextStyle(fontWeight: FontWeight.w700)),
                            SelectableText(c['password'] as String, style: const TextStyle(fontSize: 18)),
                            if (c['totp_secret'] != null) ...[
                              const SizedBox(height: 8),
                              const Text('Clé d’authentification', style: TextStyle(fontWeight: FontWeight.w700)),
                              SelectableText(c['totp_secret'] as String),
                            ],
                          ]),
                          actions: [
                            TextButton(
                              onPressed: () => Clipboard.setData(ClipboardData(text: 'Mot de passe : ${c['password']}${c['totp_secret'] == null ? '' : '\nClé : ${c['totp_secret']}'}')),
                              child: const Text('Copier'),
                            ),
                            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fermer')),
                          ],
                        ),
                      );
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    }
                  },
                  itemBuilder: (_) => [
                    if (u['role'] != 'SUPER_ADMIN')
                      u['totp_required'] == false
                          ? const PopupMenuItem(value: 'totp_on', child: Text('Exiger le code'))
                          : const PopupMenuItem(value: 'totp_off', child: Text('Ne plus exiger le code')),
                    const PopupMenuItem(value: 'reset', child: Text('Nouveaux identifiants')),
                    const PopupMenuItem(value: 'remove', child: Text('Supprimer', style: TextStyle(color: AppColors.danger))),
                  ],
                ),
        ),
      );
}

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _c = <String, TextEditingController>{};
  bool _loaded = false;
  DateTime? _departure;
  DateTime? _deadline;
  String _paymentMode = 'manual';
  bool _hasWaveQr = false;

  static const intFields = {
    'freight_default_xof': 'Transport par défaut d’un devis (FCFA)',
    'min_fee_xof': 'Frais de service minimum (FCFA)',
    'quote_validity_hours': 'Validité du devis (heures)',
    'payment_deadline_days': 'Délai de paiement avant annulation (jours)',
  };
  static const numFields = {
    'customs_rate_percent': 'Douane (% des articles)',
    'price_increase_buffer_percent': 'Marge de hausse de prix tolérée (%)',
  };

  @override
  void initState() {
    super.initState();
    ref.read(adminApiProvider).settings().then((s) {
      if (!mounted) return;
      for (final k in [...intFields.keys, ...numFields.keys]) {
        _c[k] = TextEditingController(text: '${s[k]}');
      }
      final fx = (s['fx_rates'] as Map).cast<String, dynamic>();
      _c['EUR'] = TextEditingController(text: '${fx['EUR'] ?? ''}');
      _c['USD'] = TextEditingController(text: '${fx['USD'] ?? ''}');
      _paymentMode = (s['payment_mode'] as String?) == 'wave_checkout' ? 'wave_checkout' : 'manual';
      final accounts = ((s['payment_accounts'] as Map?) ?? {}).cast<String, dynamic>();
      for (final k in ['WAVE', 'ORANGE', 'MOOV']) {
        _c['acct_$k'] = TextEditingController(text: (accounts[k] as String?) ?? (k == 'WAVE' ? s['wave_phone'] as String? ?? '' : ''));
      }
      _hasWaveQr = s['has_wave_qr'] == true;
      _c['support_whatsapp'] = TextEditingController(text: s['support_whatsapp'] as String? ?? '');
      final d = s['next_departure_date'] as String?;
      _departure = d == null ? null : DateTime.parse(d);
      final dl = s['next_order_deadline'] as String?;
      _deadline = dl == null ? null : DateTime.parse(dl);
      setState(() => _loaded = true);
    }).catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  static String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<DateTime?> _pickDate(DateTime? current, DateTime? last) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final lastDate = last ?? today.add(const Duration(days: 365));
    return showDatePicker(
      context: context,
      initialDate: current != null && !current.isBefore(today) && !current.isAfter(lastDate) ? current : today,
      firstDate: today,
      lastDate: lastDate.isBefore(today) ? today : lastDate,
    );
  }

  /// Saved immediately: the dates are what customers see on their home screen.
  Future<void> _saveDeparture(Map<String, dynamic> body, VoidCallback apply) async {
    try {
      await ref.read(adminApiProvider).updateSettings(body);
      setState(apply);
      if (mounted) showInfo(context, 'Prochain départ enregistré.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _save() async {
    final body = <String, dynamic>{
      for (final k in intFields.keys) k: int.tryParse(_c[k]!.text.trim()),
      for (final k in numFields.keys) k: double.tryParse(_c[k]!.text.trim().replaceAll(',', '.')),
      if (_departure != null) 'next_departure_date': _iso(_departure!),
      if (_deadline != null) 'next_order_deadline': _iso(_deadline!),
      'payment_mode': _paymentMode,
      if (_c['support_whatsapp']!.text.trim().isNotEmpty) 'support_whatsapp': _c['support_whatsapp']!.text.trim(),
      'payment_accounts': {
        for (final k in ['WAVE', 'ORANGE', 'MOOV']) k: _c['acct_$k']!.text.trim().isEmpty ? null : _c['acct_$k']!.text.trim(),
      },
      'fx_rates': {'EUR': _c['EUR']!.text.trim().replaceAll(',', '.'), 'USD': _c['USD']!.text.trim().replaceAll(',', '.')},
    }..removeWhere((_, v) => v == null);
    try {
      await ref.read(adminApiProvider).updateSettings(body);
      if (mounted) showInfo(context, 'Paramètres enregistrés. Ils s’appliquent aux prochains devis.');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Paramètres')),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                const SectionTitle('Prochain départ (affiché aux clientes)'),
                Card(
                  child: Column(children: [
                    ListTile(
                      leading: const Icon(Icons.flight_takeoff_rounded),
                      title: Text(_departure == null ? 'Aucune date' : DateFormat('EEEE d MMMM yyyy', 'fr').format(_departure!)),
                      subtitle: const Text('Date de départ · crée l’expédition'),
                      onTap: () async {
                        final picked = await _pickDate(_departure, null);
                        if (picked == null) return;
                        // A new departure needs its own deadline: the server clears the old one.
                        final changed = picked != _departure;
                        await _saveDeparture({'next_departure_date': _iso(picked)}, () {
                          _departure = picked;
                          if (changed) _deadline = null;
                        });
                      },
                    ),
                    const Divider(height: 1),
                    ListTile(
                      enabled: _departure != null,
                      leading: const Icon(Icons.event_busy_rounded),
                      title: Text(_deadline == null ? 'Dernière commande : non fixée' : 'Dernière commande : ${DateFormat('EEEE d MMMM', 'fr').format(_deadline!)}'),
                      subtitle: const Text('Date limite pour commander pour ce départ'),
                      onTap: () async {
                        final picked = await _pickDate(_deadline, _departure);
                        if (picked == null) return;
                        await _saveDeparture({'next_departure_date': _iso(_departure!), 'next_order_deadline': _iso(picked)}, () => _deadline = picked);
                      },
                    ),
                  ]),
                ),
                const SectionTitle('Support WhatsApp'),
                TextField(
                  controller: _c['support_whatsapp'],
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Numéro WhatsApp pour les questions des clientes'),
                ),
                const SectionTitle('Paiement'),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'manual', label: Text('Capture du paiement')),
                    ButtonSegment(value: 'wave_checkout', label: Text('Wave Business')),
                  ],
                  selected: {_paymentMode},
                  onSelectionChanged: (s) => setState(() => _paymentMode = s.first),
                ),
                const SizedBox(height: 8),
                Text(
                  _paymentMode == 'wave_qr'
                      ? 'La cliente paie sur Wave, Orange ou Moov, envoie la capture, puis tu confirmes dans la commande.'
                      : 'Paiement automatique via l’API Wave Business (clé API requise sur le serveur).',
                  style: const TextStyle(color: AppColors.muted),
                ),
                const SizedBox(height: 8),
                for (final (k, label) in const [('WAVE', 'Numéro Wave'), ('ORANGE', 'Numéro Orange Money'), ('MOOV', 'Numéro Moov Money')])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _c['acct_$k'],
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(labelText: label, helperText: 'Vide = non proposé aux clientes'),
                    ),
                  ),
                const SizedBox(height: 8),
                Card(
                  child: ListTile(
                    leading: Icon(_hasWaveQr ? Icons.qr_code_2_rounded : Icons.qr_code_scanner_rounded),
                    title: Text(_hasWaveQr ? 'QR Wave enregistré' : 'Ajouter ton QR Wave (optionnel)'),
                    subtitle: const Text('Capture d’écran de ton QR dans l’app Wave'),
                    trailing: const Icon(Icons.upload_rounded),
                    onTap: () async {
                      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
                      if (file == null) return;
                      try {
                        await ref.read(adminApiProvider).uploadWaveQr(file.path);
                        setState(() => _hasWaveQr = true);
                        if (context.mounted) showInfo(context, 'QR Wave enregistré.');
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                  ),
                ),
                const SectionTitle('Taux de change (FCFA pour 1 unité)'),
                TextField(controller: _c['EUR'], decoration: const InputDecoration(labelText: 'EUR'), keyboardType: TextInputType.number),
                const SizedBox(height: 8),
                TextField(controller: _c['USD'], decoration: const InputDecoration(labelText: 'USD'), keyboardType: TextInputType.number),
                const SectionTitle('Devis'),
                for (final e in {...intFields, ...numFields}.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(controller: _c[e.key], decoration: InputDecoration(labelText: e.value), keyboardType: TextInputType.number),
                  ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _save, child: const Text('Enregistrer')),
              ]),
      );
}

class ReportScreen extends ConsumerWidget {
  const ReportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('Résumé (30 jours)')),
        body: FutureBuilder(
          future: ref.read(adminApiProvider).reportSummary(),
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!, onRetry: () => (context as Element).markNeedsBuild());
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final s = snap.data!;
            final byStatus = (s['orders_by_status'] as Map).cast<String, dynamic>();
            return ListView(padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(children: [
                    AmountRow('Encaissé', (s['revenue_xof'] as num).toInt(), bold: true),
                    AmountRow('Frais de service', (s['fees_xof'] as num).toInt()),
                    AmountRow('Remboursé', (s['refunds_xof'] as num).toInt()),
                    Row(children: [const Expanded(child: Text('Commandes payées')), Text('${s['paid_orders']}')]),
                    Row(children: [const Expanded(child: Text('Remboursements en attente')), Text('${s['pending_refunds']}')]),
                  ]),
                ),
              ),
              const SectionTitle('Commandes par statut'),
              Card(
                child: Column(children: [
                  for (final e in byStatus.entries) ListTile(dense: true, title: Text(statusLabels[e.key] ?? e.key), trailing: Text('${e.value}')),
                ]),
              ),
            ]);
          },
        ),
      );
}
