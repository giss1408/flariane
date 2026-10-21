import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../../widgets/whatsapp.dart';
import '../order/order_screen.dart';
import 'quote_draft.dart';

/// Quote = screenshot of the SHEIN/Temu cart + cart price + transport. The customer sees the screenshot.
class QuoteEditorScreen extends ConsumerStatefulWidget {
  const QuoteEditorScreen({super.key, required this.order});

  final OrderDetail order;

  @override
  ConsumerState<QuoteEditorScreen> createState() => _QuoteEditorScreenState();
}

class _QuoteEditorScreenState extends ConsumerState<QuoteEditorScreen> {
  late final QuoteDraftModel _model = QuoteDraftModel.fromOrder(widget.order);
  Quote? _saved; // last server response: authoritative totals and screenshot
  Timer? _debounce;
  bool _saving = false;
  bool _uploading = false;
  bool _dirty = true;
  bool _sending = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _saved = widget.order.draft;
    _dirty = _saved == null;
    if (_model.isValid && _dirty) _scheduleSave();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  String? get _screenshotUrl => _saved?.screenshotUrl ?? widget.order.latestSent?.screenshotUrl;

  void _changed() {
    setState(() => _dirty = true);
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), () => _save());
  }

  /// Autosave: the server stores the draft and returns computed totals.
  Future<bool> _save({bool allowIncomplete = false}) async {
    if (!_model.isValid && !allowIncomplete) return false;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final quote = await ref.read(adminApiProvider).saveDraft(widget.order.id, _model.toJson());
      if (!mounted) return true;
      setState(() {
        _saved = quote;
        _dirty = false;
      });
      return true;
    } catch (e) {
      if (mounted) setState(() => _saveError = toApiException(e).message);
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickScreenshot() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 85, maxWidth: 2000);
    if (file == null) return;
    setState(() => _uploading = true);
    try {
      _debounce?.cancel();
      // The screenshot belongs to the draft: make sure one exists first.
      if (_saved == null && !await _save(allowIncomplete: true)) return;
      final quote = await ref.read(adminApiProvider).uploadQuoteScreenshot(widget.order.id, file.path);
      if (mounted) setState(() => _saved = quote);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _send() async {
    final error = _model.error ?? (_screenshotUrl == null ? 'Ajoute la capture du panier ${widget.order.storeName}' : null);
    if (error != null) return showInfo(context, error);
    setState(() => _sending = true);
    try {
      _debounce?.cancel();
      if ((_dirty || _saved == null) && !await _save()) return;
      if (!mounted) return;
      final quote = _saved!;
      final ok = await confirm(
        context,
        title: 'Envoyer le devis n°${quote.version} ?',
        body: 'Total ${fcfa(quote.totalXof)}. La cliente le reçoit avec la capture du panier. '
            'Toute correction créera une nouvelle version.',
        ok: 'Envoyer',
      );
      if (!ok) return;
      await ref.read(adminApiProvider).sendQuote(widget.order.id, quote.version);
      ref.invalidate(orderProvider(widget.order.id));
      if (!mounted) return;
      // Tell her on WhatsApp right away (message pre-written, sent from this phone).
      await sendWhatsApp(context, ref, widget.order.id, 'quote');
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    final change = order.pendingChangeRequest;
    return Scaffold(
      appBar: AppBar(title: Text('Devis · ${order.publicRef}')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (order.sourceCartUrl != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text('Ouvrir le panier dans ${order.storeName}'),
              onPressed: () => openInShein(context, order.sourceCartUrl!),
            ),
          if (change != null) ...[
            const SizedBox(height: 12),
            WarningBox('Modification demandée.${change.note == null ? '' : ' « ${change.note} »'}'
                '${change.newCartUrl == null ? '' : ' Nouveau lien de panier ci-dessus.'}'),
          ],
          SectionTitle('Capture du panier ${order.storeName}'),
          _ScreenshotBox(url: _screenshotUrl, busy: _uploading, onPick: _pickScreenshot, store: order.storeName),
          const SectionTitle('Montants'),
          _AmountField(
            label: 'Prix ${order.storeName} du panier *',
            initial: _model.cartPriceXof,
            onChanged: (v) {
              _model.cartPriceXof = v;
              _changed();
            },
          ),
          const SizedBox(height: 10),
          _AmountField(
            label: 'Transport (vide = 5 000 FCFA)',
            hint: _saved == null ? '5000' : '${_saved!.freightXof}',
            initial: _model.freightXof,
            onChanged: (v) {
              _model.freightXof = v;
              _changed();
            },
          ),
          const SizedBox(height: 10),
          TextFormField(
            initialValue: _model.note,
            maxLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Message à la cliente (optionnel)'),
            onChanged: (v) {
              _model.note = v;
              _changed();
            },
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          decoration: BoxDecoration(
            color: Theme.of(context).cardTheme.color,
            border: const Border(top: BorderSide(color: Color(0x14000000))),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: _statusLine()),
              Text(
                _saved == null ? '—' : fcfa(_saved!.totalXof),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _dirty ? AppColors.muted : null),
              ),
            ]),
            if (_saved != null && !_dirty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Panier ${fcfa(_saved!.itemsXof)} + transport ${fcfa(_saved!.freightXof)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted),
                ),
              ),
            const SizedBox(height: 10),
            FilledButton(
              onPressed: _sending ? null : _send,
              child: _sending
                  ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                  : const Text('Envoyer le devis'),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _statusLine() {
    final error = _model.error ?? (_screenshotUrl == null ? 'Ajoute la capture du panier' : null);
    final (text, color) = switch (true) {
      _ when error != null => (error, AppColors.warning),
      _ when _saveError != null => (_saveError!, AppColors.danger),
      _ when _saving => ('Calcul…', AppColors.muted),
      _ when _dirty => ('Modifié', AppColors.muted),
      _ => ('Brouillon enregistré', AppColors.success),
    };
    return Text(text, style: TextStyle(color: color, fontSize: 13), maxLines: 2);
  }
}

class _ScreenshotBox extends StatelessWidget {
  const _ScreenshotBox({required this.url, required this.busy, required this.onPick, required this.store});

  final String? url;
  final bool busy;
  final VoidCallback onPick;
  final String store;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(height: 160, child: Center(child: CircularProgressIndicator()));
    }
    if (url == null) {
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onPick,
        child: Container(
          height: 160,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppColors.primary, width: 1.5),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.add_photo_alternate_outlined, size: 40, color: AppColors.primary),
            const SizedBox(height: 8),
            Text('Ajouter la capture du panier $store', style: const TextStyle(fontWeight: FontWeight.w600)),
            const Text('La cliente la verra avant de payer', style: TextStyle(color: AppColors.muted, fontSize: 13)),
          ]),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => Scaffold(
              appBar: AppBar(title: const Text('Capture du panier')),
              body: InteractiveViewer(child: Center(child: Image.network(url!))),
            ),
          )),
          child: Image.network(url!, height: 260, fit: BoxFit.cover, alignment: Alignment.topCenter),
        ),
      ),
      TextButton.icon(onPressed: onPick, icon: const Icon(Icons.refresh_rounded), label: const Text('Remplacer la capture')),
    ]);
  }
}

class _AmountField extends StatelessWidget {
  const _AmountField({required this.label, required this.initial, required this.onChanged, this.hint});

  final String label;
  final String? hint;
  final int? initial;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: initial?.toString() ?? '',
        decoration: InputDecoration(labelText: label, hintText: hint, suffixText: 'FCFA'),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
        onChanged: (v) => onChanged(parseFcfa(v)),
      );
}
