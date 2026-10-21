import '../../data/models.dart';

/// One editable line of the quote editor.
class DraftLine {
  DraftLine({
    this.id,
    this.title = '',
    this.size = '',
    this.color = '',
    this.qty = 1,
    this.price = '',
    this.currency = 'EUR',
    this.sourceUrl,
  });

  int? id; // existing order_item id
  String title;
  String size;
  String color;
  int qty;
  String price; // SHEIN price as typed, e.g. "12.99" or "12,99"
  String currency;
  String? sourceUrl;

  static final _price = RegExp(r'^\d{1,6}([.,]\d{1,2})?$');

  String get normalizedPrice => price.trim().replaceAll(',', '.');

  String? get error {
    if (title.trim().isEmpty) return 'Nom de l’article requis';
    if (qty < 1 || qty > 50) return 'Quantité entre 1 et 50';
    if (!_price.hasMatch(price.trim())) return 'Prix invalide';
    return null;
  }

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'title': title.trim(),
        'size': size.trim().isEmpty ? null : size.trim(),
        'color': color.trim().isEmpty ? null : color.trim(),
        'qty': qty,
        'source_price': normalizedPrice,
        'source_currency': currency,
        if (sourceUrl != null) 'source_url': sourceUrl,
      };
}

/// Editor state. The server computes every amount; this only builds the request.
class QuoteDraftModel {
  QuoteDraftModel({required this.lines, this.freightXof, this.customsXof, this.feeXof, this.note});

  /// Starts from, in order: the open draft, the last sent quote with the customer's requested
  /// changes applied, or one empty line.
  factory QuoteDraftModel.fromOrder(OrderDetail order, {String defaultCurrency = 'EUR'}) {
    final items = {for (final i in order.items) i.id: i};
    DraftLine fromItem(OrderItem i) => DraftLine(
          id: i.id,
          title: i.title,
          size: i.size ?? '',
          color: i.color ?? '',
          qty: i.qty,
          price: i.sourcePrice,
          currency: i.sourceCurrency,
          sourceUrl: i.sourceUrl,
        );

    final draft = order.draft;
    if (draft != null) {
      return QuoteDraftModel(
        lines: [for (final l in draft.lines) if (items[l.orderItemId] != null) fromItem(items[l.orderItemId]!)],
        freightXof: draft.freightXof,
        customsXof: draft.customsXof,
        feeXof: draft.feeXof,
        note: draft.adminNote,
      );
    }

    final previous = order.latestSent;
    if (previous != null) {
      final change = order.pendingChangeRequest;
      final removed = change?.removedItemIds.toSet() ?? {};
      final changes = {for (final c in change?.lineChanges ?? const <Map<String, dynamic>>[]) c['order_item_id'] as int: c};
      final lines = <DraftLine>[];
      for (final l in previous.lines) {
        final item = items[l.orderItemId];
        if (item == null || removed.contains(item.id)) continue;
        final line = fromItem(item);
        final c = changes[item.id];
        if (c != null) {
          if (c['size'] != null) line.size = c['size'] as String;
          if (c['color'] != null) line.color = c['color'] as String;
          if (c['qty'] != null) line.qty = c['qty'] as int;
        }
        lines.add(line);
      }
      // Freight/customs go back to automatic when lines changed; the fee is kept.
      return QuoteDraftModel(
        lines: lines.isEmpty ? [DraftLine(currency: defaultCurrency)] : lines,
        feeXof: previous.feeXof,
        freightXof: change == null ? previous.freightXof : null,
        customsXof: change == null ? previous.customsXof : null,
        note: previous.adminNote,
      );
    }
    return QuoteDraftModel(lines: [DraftLine(currency: defaultCurrency)]);
  }

  final List<DraftLine> lines;
  int? freightXof; // null = computed by the server from settings
  int? customsXof;
  int? feeXof;
  String? note;

  String? get error {
    if (lines.isEmpty) return 'Ajoutez au moins un article';
    for (final (i, l) in lines.indexed) {
      final e = l.error;
      if (e != null) return 'Article ${i + 1} : $e';
    }
    if (feeXof == null) return 'Saisissez les frais de service';
    return null;
  }

  bool get isValid => error == null;

  Map<String, dynamic> toJson() => {
        'items': [for (final l in lines) l.toJson()],
        'freight_xof': freightXof,
        'customs_xof': customsXof,
        'fee_xof': feeXof,
        'admin_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
      };
}

/// "25 000" / "25000" / "25.000" -> 25000
int? parseFcfa(String text) {
  final digits = text.replaceAll(RegExp(r'[\s. ]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}
