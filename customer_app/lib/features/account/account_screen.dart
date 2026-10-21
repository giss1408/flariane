import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';
import '../auth/login_screen.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Mon compte'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        me.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => ErrorView(e, onRetry: () => ref.invalidate(meProvider)),
          data: (m) => Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_rounded)),
              title: Text(m.displayName ?? 'Sans nom'),
              subtitle: Text(m.phoneMasked),
              trailing: IconButton(
                tooltip: 'Modifier le nom',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => _editName(context, ref, m.displayName),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.password_rounded),
              title: const Text('Changer mon mot de passe'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ChangePasswordScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.logout_rounded),
              title: const Text('Se déconnecter'),
              onTap: () async {
                await ref.read(authProvider.notifier).logout();
                if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
              title: const Text('Supprimer mon compte', style: TextStyle(color: AppColors.danger)),
              subtitle: const Text('Vos données personnelles sont effacées (loi 2013-450).'),
              onTap: () => _delete(context, ref),
            ),
          ]),
        ),
      ]),
    );
  }

  Future<void> _editName(BuildContext context, WidgetRef ref, String? current) async {
    final c = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Votre prénom'),
        content: TextField(controller: c, autofocus: true, maxLength: 80),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    try {
      await ref.read(apiProvider).updateMe(name: name);
      ref.invalidate(meProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer votre compte ?'),
        content: const Text('Impossible si une commande est en cours. Cette action est définitive.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Supprimer', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).deleteMe();
      await ref.read(authProvider.notifier).logout();
      if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
