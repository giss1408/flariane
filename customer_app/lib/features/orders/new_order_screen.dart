import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';
import '../account/location_screen.dart';
import 'order_screen.dart';

/// Mirrors the server's check so the customer gets instant feedback; the server re-validates.
bool looksLikeSheinLink(String text) =>
    RegExp(r'https://([a-z0-9-]+\.)*(shein|temu)\.com/\S+', caseSensitive: false)
        .hasMatch(text);

class NewOrderScreen extends ConsumerStatefulWidget {
  const NewOrderScreen({super.key});

  @override
  ConsumerState<NewOrderScreen> createState() => _NewOrderScreenState();
}

class _NewOrderScreenState extends ConsumerState<NewOrderScreen> {
  late final _link =
      TextEditingController(text: ref.read(sharedTextProvider) ?? '');
  final _note = TextEditingController();
  final _screenshots = <XFile>[];
  int? _pointId;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    Future.microtask(
        () => ref.read(sharedTextProvider.notifier).state = null); // consumed
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _link.text = data!.text!);
  }

  Future<void> _pick() async {
    final files =
        await ImagePicker().pickMultiImage(imageQuality: 70, maxWidth: 1280); // light uploads on mobile data
    setState(() => _screenshots.addAll(files.take(10 - _screenshots.length)));
  }

  Future<void> _submit() async {
    if (!looksLikeSheinLink(_link.text)) {
      return showInfo(context, 'Colle le lien de partage de ton panier SHEIN ou Temu.');
    }
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    try {
      final order = await api.createOrder(
        shareText: _link.text,
        pickupPointId: _pointId,
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
      );
      var failed = 0;
      for (final f in _screenshots) {
        try {
          await api.uploadScreenshot(order.ref, f.path);
        } catch (_) {
          failed++;
        }
      }
      if (!mounted) return;
      showInfo(
          context,
          failed == 0
              ? 'Demande envoyée — vous recevrez votre devis sur WhatsApp.'
              : 'Demande envoyée, mais $failed capture(s) n’ont pas pu être envoyées.');
      Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => OrderScreen(orderRef: order.ref)));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final points = ref.watch(pickupPointsProvider);
    final location = ref.watch(meProvider).valueOrNull?.location;
    return Scaffold(
      appBar: const FlarianeHeader(subtitle: 'Nouveau panier'),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _link,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: 'Lien de ton panier SHEIN ou Temu',
            hintText: 'https://onelink.shein.com/…',
            suffixIcon: IconButton(
                tooltip: 'Coller',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: _paste),
          ),
        ),
        const SizedBox(height: 8),
        Text(
            'Vérifie tailles et couleurs dans ton panier avant d’envoyer. Les prix affichés à Abidjan peuvent changer au moment de notre commande : ton devis te donnera le prix réel.',
            style: TextStyle(color: context.pal.warning)),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: Icon(Icons.place_rounded, color: context.pal.accent),
            title: Text(location == null ? 'Ajoute ton adresse à Abidjan' : 'Livraison : ${location.short}'),
            subtitle: Text(location?.landmark ?? (location == null ? 'Pour préparer la distribution de ton colis' : 'Toucher pour modifier')),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LocationScreen(initial: location))),
          ),
        ),
        const SizedBox(height: 16),
        points.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) =>
              ErrorView(e, onRetry: () => ref.invalidate(pickupPointsProvider)),
          data: (list) => list.isEmpty
              ? const Text('Point de retrait : choisi plus tard avec vous.')
              : DropdownButtonFormField<int>(
                  value: _pointId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                      labelText: 'Point de retrait (optionnel)'),
                  items: [
                    for (final p in list)
                      DropdownMenuItem(
                          value: p.id,
                          child: Text('${p.name} — ${p.address}',
                              overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (v) => setState(() => _pointId = v),
                ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _note,
          maxLines: 3,
          maxLength: 1000,
          decoration: const InputDecoration(labelText: 'Message (optionnel)'),
        ),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (i, f) in _screenshots.indexed)
            InputChip(
                label: Text('Capture ${i + 1}'),
                onDeleted: () => setState(() => _screenshots.remove(f))),
        ]),
        TextButton.icon(
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Ajouter une capture du panier'),
          onPressed: _screenshots.length >= 10 ? null : _pick,
        ),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5))
                : const Text('Demander un devis'),
          ),
        ),
      ),
    );
  }
}
