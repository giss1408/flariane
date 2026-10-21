import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../data/models.dart';
import '../../widgets/common.dart';
import '../order/order_screen.dart';
import 'quote_draft.dart';

const currencies = ['EUR', 'USD', 'XOF'];

class QuoteEditorScreen extends ConsumerStatefulWidget {
  const QuoteEditorScreen({super.key, required this.order});

  final OrderDetail order;

  @override
  ConsumerState<QuoteEditorScreen> createState() => _QuoteEditorScreenState();
}

class _QuoteEditorScreenState extends ConsumerState<QuoteEditorScreen> {
  late final QuoteDraftModel _model = QuoteDraftModel.fromOrder(widget.order);
  Quote? _saved; // last server response: authoritative totals
  Timer? _debounce;
  bool _saving = false;
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

  void _changed() {
    setState(() => _dirty = true);
    _scheduleSave();
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 900), _save);
  }

  /// Autosave: the server stores the draft and returns computed totals.
  Future<bool> _save() async {
    if (!_model.isValid) return false;
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

  Future<void> _send() async {
    final error = _model.error;
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
        body: 'Total ${fcfa(quote.totalXof)}. Le client le reçoit sur WhatsApp et ne pourra plus le voir modifié — '
            'toute correction créera une nouvelle version.',
        ok: 'Envoyer',
      );
      if (!ok) return;
      final api = ref.read(adminApiProvider);
      try {
        await api.sendQuote(widget.order.id, quote.version);
      } on ApiException catch (e) {
        if (e.code != 'fee_below_minimum' || !mounted) rethrow;
        final low = await confirm(
          context,
          title: 'Frais sous le minimum',
          body: 'Les frais de service (${fcfa(quote.feeXof)}) sont inférieurs au minimum (${fcfa(quote.minFeeXof)}). Envoyer quand même ?',
          ok: 'Envoyer quand même',
        );
        if (!low) return;
        await api.sendQuote(widget.order.id, quote.version, confirmLowFee: true);
      }
      ref.invalidate(orderProvider(widget.order.id));
      if (!mounted) return;
      showInfo(context, 'Devis envoyé au client.');
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
              label: const Text('Ouvrir le panier dans SHEIN'),
              onPressed: () => openInShein(context, order.sourceCartUrl!),
            ),
          if (change != null) ...[
            const SizedBox(height: 12),
            WarningBox('Modifications demandées appliquées ci-dessous.'
                '${change.note == null ? '' : ' Note : « ${change.note} »'}'),
          ],
          const SectionTitle('Articles'),
          for (final (i, line) in _model.lines.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _LineEditor(
                key: ObjectKey(line),
                index: i,
                line: line,
                onChanged: _changed,
                onRemove: _model.lines.length == 1
                    ? null
                    : () {
                        setState(() => _model.lines.removeAt(i));
                        _changed();
                      },
              ),
            ),
          OutlinedButton.icon(
            icon: const Icon(Icons.add_rounded),
            label: const Text('Ajouter un article'),
            onPressed: () {
              setState(() => _model.lines.add(DraftLine(currency: _model.lines.last.currency)));
            },
          ),
          const SectionTitle('Frais'),
          _AmountField(
            label: 'Transport (vide = automatique)',
            hint: _saved == null ? null : fcfa(_saved!.freightXof),
            initial: _model.freightXof,
            onChanged: (v) {
              _model.freightXof = v;
              _changed();
            },
          ),
          const SizedBox(height: 10),
          _AmountField(
            label: 'Douane (vide = automatique)',
            hint: _saved == null ? null : fcfa(_saved!.customsXof),
            initial: _model.customsXof,
            onChanged: (v) {
              _model.customsXof = v;
              _changed();
            },
          ),
          const SizedBox(height: 10),
          _AmountField(
            label: 'Frais de service *',
            initial: _model.feeXof,
            autofocus: _model.feeXof == null && order.draft == null && order.latestSent != null,
            onChanged: (v) {
              _model.feeXof = v;
              _changed();
            },
          ),
          if (_saved != null && _saved!.feeBelowMinimum && !_dirty) ...[
            const SizedBox(height: 8),
            WarningBox('Frais sous le minimum (${fcfa(_saved!.minFeeXof)}).'),
          ],
          const SizedBox(height: 10),
          TextFormField(
            initialValue: _model.note,
            maxLines: 3,
            maxLength: 1000,
            decoration: const InputDecoration(labelText: 'Message au client (optionnel)'),
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
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: _dirty ? AppColors.muted : null,
                ),
              ),
            ]),
            if (_saved != null && !_dirty)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Articles ${fcfa(_saved!.itemsXof)} · Transport ${fcfa(_saved!.freightXof)} · Douane ${fcfa(_saved!.customsXof)}',
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
    final error = _model.error;
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

class _LineEditor extends StatelessWidget {
  const _LineEditor({super.key, required this.index, required this.line, required this.onChanged, this.onRemove});

  final int index;
  final DraftLine line;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              Text('Article ${index + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
              const Spacer(),
              if (onRemove != null)
                IconButton(tooltip: 'Retirer', icon: const Icon(Icons.delete_outline_rounded), onPressed: onRemove),
            ]),
            TextFormField(
              initialValue: line.title,
              decoration: const InputDecoration(labelText: 'Nom'),
              textCapitalization: TextCapitalization.sentences,
              onChanged: (v) {
                line.title = v;
                onChanged();
              },
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: line.size,
                  decoration: const InputDecoration(labelText: 'Taille'),
                  onChanged: (v) {
                    line.size = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: line.color,
                  decoration: const InputDecoration(labelText: 'Couleur'),
                  onChanged: (v) {
                    line.color = v;
                    onChanged();
                  },
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              SizedBox(
                width: 76,
                child: TextFormField(
                  initialValue: '${line.qty}',
                  decoration: const InputDecoration(labelText: 'Qté'),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(2)],
                  onChanged: (v) {
                    line.qty = int.tryParse(v) ?? 0;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  initialValue: line.price,
                  decoration: const InputDecoration(labelText: 'Prix SHEIN unitaire'),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                  onChanged: (v) {
                    line.price = v;
                    onChanged();
                  },
                ),
              ),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: line.currency,
                items: [for (final c in currencies) DropdownMenuItem(value: c, child: Text(c))],
                onChanged: (v) {
                  if (v == null) return;
                  line.currency = v;
                  onChanged(); // parent setState rebuilds this card with the new value
                },
              ),
            ]),
          ]),
        ),
      );
}

class _AmountField extends StatelessWidget {
  const _AmountField({required this.label, required this.initial, required this.onChanged, this.hint, this.autofocus = false});

  final String label;
  final String? hint;
  final int? initial;
  final ValueChanged<int?> onChanged;
  final bool autofocus;

  @override
  Widget build(BuildContext context) => TextFormField(
        initialValue: initial?.toString() ?? '',
        autofocus: autofocus,
        decoration: InputDecoration(labelText: label, hintText: hint, suffixText: 'FCFA'),
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(8)],
        onChanged: (v) => onChanged(parseFcfa(v)),
      );
}
