import 'package:flariane_admin/core/format.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flariane_admin/features/purchase/purchase_screen.dart';
import 'package:flariane_admin/features/quote/quote_draft.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> orderJson({List<Map<String, dynamic>> quotes = const [], List<Map<String, dynamic>> changes = const []}) => {
      'id': 1,
      'public_ref': 'FLR-ABCDE',
      'status': 'QUOTE_REQUESTED',
      'customer_id': 1,
      'customer_name': 'Awa',
      'customer_phone_masked': '+225 07 •• •• 04',
      'source_cart_url': 'https://onelink.shein.com/57/abc',
      'submitted_links': <String>[],
      'customer_note': null,
      'pickup_point': null,
      'items': [
        {'id': 10, 'title': 'Robe', 'size': 'M', 'color': 'Bleu', 'qty': 1, 'source_price': '12.99', 'source_currency': 'EUR', 'source_url': null, 'item_status': 'OK', 'active': true},
        {'id': 11, 'title': 'Sandales', 'size': '39', 'color': 'Noir', 'qty': 2, 'source_price': '8.50', 'source_currency': 'EUR', 'source_url': null, 'item_status': 'OK', 'active': true},
      ],
      'quotes': quotes,
      'change_requests': changes,
      'attachments': <dynamic>[],
      'payments': <dynamic>[],
      'purchase': null,
      'history': <dynamic>[],
      'shipment_id': null,
    };

Map<String, dynamic> quoteJson({required int version, required String status, int fee = 3000}) => {
      'id': version,
      'version': version,
      'status': status,
      'items_xof': 19673,
      'freight_xof': 9000,
      'customs_xof': 3935,
      'fee_xof': fee,
      'total_xof': 35608,
      'admin_note': 'Livraison 3 semaines',
      'expires_at': '2026-10-23T18:00:00Z',
      'sent_at': '2026-10-21T18:00:00Z',
      'answered_at': null,
      'fx_rates': {'EUR': '655.957'},
      'created_by': 1,
      'min_fee_xof': 2000,
      'fee_below_minimum': false,
      'lines': [
        {'order_item_id': 10, 'title': 'Robe', 'size': 'M', 'color': 'Bleu', 'qty': 1, 'unit_price_xof': 8521, 'line_total_xof': 8521},
        {'order_item_id': 11, 'title': 'Sandales', 'size': '39', 'color': 'Noir', 'qty': 2, 'unit_price_xof': 5576, 'line_total_xof': 11152},
      ],
    };

void main() {
  group('format', () {
    test('fcfa uses narrow spaces and no decimals', () {
      expect(fcfa(25000), '25 000 FCFA');
      expect(fcfa(1234567), '1 234 567 FCFA');
      expect(fcfa(500), '500 FCFA');
      expect(fcfa(null), '—');
    });

    test('ago', () {
      final now = DateTime(2026, 10, 21, 12);
      expect(ago(now.subtract(const Duration(minutes: 5)), now: now), 'il y a 5 min');
      expect(ago(now.subtract(const Duration(hours: 3)), now: now), 'il y a 3 h');
      expect(ago(now.subtract(const Duration(days: 2)), now: now), 'il y a 2 j');
    });
  });

  group('QuoteDraftModel', () {
    test('new order starts empty and is invalid', () {
      final m = QuoteDraftModel.fromOrder(OrderDetail.fromJson(orderJson()));
      expect(m.cartPriceXof, isNull);
      expect(m.isValid, isFalse);
    });

    test('a correction starts from the last sent quote', () {
      final m = QuoteDraftModel.fromOrder(OrderDetail.fromJson(orderJson(quotes: [quoteJson(version: 1, status: 'CHANGE_REQUESTED')])));
      expect(m.cartPriceXof, 19673);
      expect(m.freightXof, 9000);
      expect(m.isValid, isTrue);
    });

    test('toJson', () {
      final j = QuoteDraftModel(cartPriceXof: 32500, note: '  ').toJson();
      expect(j, {'cart_price_xof': 32500, 'freight_xof': null, 'admin_note': null});
    });

    test('parseFcfa', () {
      expect(parseFcfa('25 000'), 25000);
      expect(parseFcfa('25.000'), 25000);
      expect(parseFcfa(''), isNull);
    });
  });

  group('PurchaseChecklist', () {
    test('every line must be bought or refused', () {
      final q = Quote.fromJson(quoteJson(version: 1, status: 'ACCEPTED'));
      final c = PurchaseChecklist(q);
      expect(c.complete, isFalse);
      c.cycle(10); // bought
      c.cycle(11);
      c.cycle(11); // refused
      expect(c.complete, isTrue);
      expect(c.bought, [10]);
      expect(c.refused, [11]);
      c.cycle(11); // back to unchecked
      expect(c.complete, isFalse);
    });
  });

  test('OrderDetail derived getters', () {
    final o = OrderDetail.fromJson(orderJson(quotes: [
      quoteJson(version: 2, status: 'DRAFT'),
      quoteJson(version: 1, status: 'SENT'),
    ]));
    expect(o.draft!.version, 2);
    expect(o.latestSent!.version, 1);
    expect(o.pendingChangeRequest, isNull);
  });
}
