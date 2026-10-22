import '../../data/models.dart';

/// Cart-mode quote: the SHEIN/Temu cart price in euros (converted by the server with the EUR rate)
/// + transport in FCFA, proven by a cart screenshot.
class QuoteDraftModel {
  QuoteDraftModel({this.cartPriceEur, this.freightXof, this.note});

  /// Starts from the open draft, else the last sent quote (a correction), else empty.
  factory QuoteDraftModel.fromOrder(OrderDetail order) {
    final base = order.draft ?? order.latestSent;
    if (base == null) return QuoteDraftModel();
    return QuoteDraftModel(
      cartPriceEur: base.cartSourceCurrency == 'EUR' ? base.cartSourceAmount?.replaceAll('.', ',') : null,
      freightXof: base.freightXof,
      note: base.adminNote,
    );
  }

  String? cartPriceEur; // as typed: "49,90"
  int? freightXof; // null = default transport from settings (5 000 FCFA)
  String? note;

  static final _price = RegExp(r'^\d{1,6}([.,]\d{1,2})?$');

  String? get normalizedEur => cartPriceEur?.trim().replaceAll(',', '.');

  String? get error {
    final v = cartPriceEur?.trim() ?? '';
    if (v.isEmpty || !_price.hasMatch(v) || double.parse(normalizedEur!) <= 0) return 'Saisis le prix du panier en euros';
    return null;
  }

  bool get isValid => error == null;

  Map<String, dynamic> toJson() => {
        'cart_price': isValid ? normalizedEur : '0',
        'cart_currency': 'EUR',
        'freight_xof': freightXof,
        'admin_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
      };
}

/// "25 000" / "25000" / "25.000" -> 25000
int? parseFcfa(String text) {
  final digits = text.replaceAll(RegExp(r'[\s.\u202F]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}
