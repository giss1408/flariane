import '../../data/models.dart';

/// Cart-mode quote: SHEIN cart total (FCFA) + transport, proven by a cart screenshot.
/// The server computes the total; this only builds the request.
class QuoteDraftModel {
  QuoteDraftModel({this.cartPriceXof, this.freightXof, this.note});

  /// Starts from the open draft, else the last sent quote (a correction), else empty.
  factory QuoteDraftModel.fromOrder(OrderDetail order) {
    final base = order.draft ?? order.latestSent;
    if (base == null) return QuoteDraftModel();
    return QuoteDraftModel(
      cartPriceXof: base.itemsXof > 0 ? base.itemsXof : null,
      freightXof: base.freightXof,
      note: base.adminNote,
    );
  }

  int? cartPriceXof;
  int? freightXof; // null = default transport from settings (5 000 FCFA)
  String? note;

  String? get error => (cartPriceXof ?? 0) <= 0 ? 'Saisis le prix du panier' : null;

  bool get isValid => error == null;

  Map<String, dynamic> toJson() => {
        'cart_price_xof': cartPriceXof ?? 0,
        'freight_xof': freightXof,
        'admin_note': (note ?? '').trim().isEmpty ? null : note!.trim(),
      };
}

/// "25 000" / "25000" / "25.000" -> 25000
int? parseFcfa(String text) {
  final digits = text.replaceAll(RegExp(r'[\s. ]'), '');
  if (digits.isEmpty) return null;
  return int.tryParse(digits);
}
