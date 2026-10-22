import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/whatsapp.dart';

final unverifiedProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) => ref.watch(adminApiProvider).unverifiedCustomers());

/// New customers whose number isn't confirmed yet: send them a code from your WhatsApp.
class VerificationsBanner extends ConsumerWidget {
  const VerificationsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unverifiedProvider).valueOrNull?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: AppColors.warningBg,
        borderRadius: BorderRadius.circular(12),
        child: ListTile(
          leading: const Icon(Icons.how_to_reg_rounded, color: AppColors.warning),
          title: Text('$count inscription${count > 1 ? 's' : ''} à vérifier', style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: const Text('Envoie le code sur WhatsApp'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VerificationsScreen()));
            ref.invalidate(unverifiedProvider);
          },
        ),
      ),
    );
  }
}

class VerificationsScreen extends ConsumerWidget {
  const VerificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(unverifiedProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Inscriptions à vérifier')),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(unverifiedProvider.future),
        child: list.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(children: [ErrorView(e, onRetry: () => ref.invalidate(unverifiedProvider))]),
          data: (rows) => rows.isEmpty
              ? ListView(children: const [SizedBox(height: 120), Center(child: Text('Tout est vérifié.'))])
              : ListView(padding: const EdgeInsets.all(12), children: [
                  const WarningBox('Envoie le code depuis ton WhatsApp : la cliente le saisit dans l’app. '
                      'Si le numéro n’est pas sur WhatsApp ou ne répond pas, refuse l’inscription.'),
                  const SizedBox(height: 10),
                  for (final c in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Text(c['display_name'] as String? ?? 'Sans prénom', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            Text('${c['phone_masked']} · inscrite ${ago(DateTime.parse(c['created_at'] as String))}',
                                style: const TextStyle(color: AppColors.muted)),
                            if (c['code_sent'] == true) const Text('Code déjà envoyé', style: TextStyle(color: AppColors.success)),
                            const SizedBox(height: 10),
                            WhatsAppButton(
                              label: c['code_sent'] == true ? 'Renvoyer un code sur WhatsApp' : 'Envoyer le code sur WhatsApp',
                              onPressed: () async {
                                try {
                                  final url = await ref.read(adminApiProvider).verificationCodeLink(c['id'] as int);
                                  await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                                  ref.invalidate(unverifiedProvider);
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                            ),
                            TextButton(
                              onPressed: () async {
                                if (!await confirm(context, title: 'Refuser cette inscription ?', body: 'La cliente verra que son numéro n’a pas pu être vérifié et pourra en saisir un autre.', ok: 'Refuser')) return;
                                try {
                                  await ref.read(adminApiProvider).rejectRegistration(c['id'] as int);
                                  ref.invalidate(unverifiedProvider);
                                } catch (e) {
                                  if (context.mounted) showError(context, e);
                                }
                              },
                              child: const Text('Refuser', style: TextStyle(color: AppColors.danger)),
                            ),
                          ]),
                        ),
                      ),
                    ),
                ]),
        ),
      ),
    );
  }
}
