import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/logo.dart';

const communes = [
  'Abobo',
  'Adjamé',
  'Attécoubé',
  'Cocody',
  'Koumassi',
  'Marcory',
  'Plateau',
  'Port-Bouët',
  'Treichville',
  'Yopougon',
  'Anyama',
  'Bingerville',
  'Songon',
];

/// Roughly the Abidjan district; the server enforces the same box.
bool inAbidjan(double lat, double lng) =>
    lat >= 4.9 && lat <= 5.8 && lng >= -4.6 && lng <= -3.6;

class LocationScreen extends ConsumerStatefulWidget {
  const LocationScreen({super.key, this.initial});

  final Location? initial;

  @override
  ConsumerState<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends ConsumerState<LocationScreen> {
  late String? _commune = widget.initial?.commune;
  late final _quartier = TextEditingController(text: widget.initial?.quartier);
  late final _landmark = TextEditingController(text: widget.initial?.landmark);
  late double? _lat = widget.initial?.lat;
  late double? _lng = widget.initial?.lng;
  bool _locating = false;
  bool _saving = false;

  Future<void> _useGps() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          showInfo(context, 'Active la localisation de ton téléphone.');
        }
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (mounted) {
          showInfo(context,
              'Sans accès à ta position, indique simplement ton quartier et un repère.');
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 20)));
      if (!inAbidjan(pos.latitude, pos.longitude)) {
        if (mounted) {
          showInfo(context,
              'Ta position semble hors d’Abidjan. Indique ton quartier et un repère.');
        }
        return;
      }
      setState(() {
        _lat = double.parse(pos.latitude.toStringAsFixed(6));
        _lng = double.parse(pos.longitude.toStringAsFixed(6));
      });
    } catch (_) {
      if (mounted) {
        showInfo(context,
            'Position introuvable pour le moment. Réessaie dehors ou près d’une fenêtre.');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    if (_commune == null) return showInfo(context, 'Choisis ta commune.');
    if (_quartier.text.trim().isEmpty) {
      return showInfo(context, 'Indique ton quartier.');
    }
    setState(() => _saving = true);
    try {
      await ref.read(apiProvider).setLocation(Location(
            commune: _commune!,
            quartier: _quartier.text.trim(),
            landmark:
                _landmark.text.trim().isEmpty ? null : _landmark.text.trim(),
            lat: _lat,
            lng: _lng,
          ));
      ref.invalidate(meProvider);
      if (!mounted) return;
      showInfo(context, 'Adresse enregistrée.');
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: const FlarianeHeader(subtitle: 'Mon adresse à Abidjan'),
        body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              Text('Où es-tu à Abidjan ?', style: display(24)),
              const SizedBox(height: 4),
              const Text(
                  'On s’en sert pour organiser la distribution des colis à leur arrivée.',
                  style: TextStyle(color: AppColors.muted)),
              const SizedBox(height: 20),
              const Text('Commune',
                  style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final c in communes)
                  ChoiceChip(
                    label: Text(c),
                    selected: _commune == c,
                    onSelected: (_) => setState(() => _commune = c),
                    selectedColor: AppColors.primary,
                    backgroundColor: Colors.white,
                    labelStyle: TextStyle(
                        color: _commune == c ? Colors.white : AppColors.plum,
                        fontWeight: FontWeight.w600),
                    showCheckmark: false,
                  ),
              ]),
              const SizedBox(height: 20),
              TextField(
                controller: _quartier,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Quartier',
                    hintText: 'Ex. Riviera 3, Angré 8e tranche'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _landmark,
                maxLines: 2,
                maxLength: 200,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                    labelText: 'Repère (optionnel)',
                    hintText: 'Ex. derrière la pharmacie, portail bleu'),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: AppColors.lilac.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(18)),
                child: Row(children: [
                  Icon(
                      _lat != null
                          ? Icons.my_location_rounded
                          : Icons.location_searching_rounded,
                      color: AppColors.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _lat != null
                          ? 'Position GPS ajoutée'
                          : 'Ajoute ta position GPS pour qu’on te trouve plus vite (optionnel)',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_lat != null)
                    IconButton(
                        tooltip: 'Retirer la position',
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => setState(() => _lat = _lng = null))
                  else
                    TextButton(
                      onPressed: _locating ? null : _useGps,
                      child: _locating
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Utiliser ma position'),
                    ),
                ]),
              ),
            ]),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Enregistrer mon adresse')),
          ),
        ),
      );
}
