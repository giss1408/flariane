import 'package:flariane_admin/core/format.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flariane_admin/features/purchase/purchase_screen.dart';
import 'package:flariane_admin/features/quote/quote_draft.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> orderJson({List<Map<String, dynamic>> quotes = const [], List<Map<String, dynamic>> changes = const []}) => {
      'id': 1,
      'public_ref': 'FLR-ABCDE',
      'created_at': '2026-10-01T10:00:00Z',
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
      expect(m.cartPriceEur, isNull);
      expect(m.isValid, isFalse);
    });

    test('a correction starts from the last sent quote in euros', () {
      final q = {...quoteJson(version: 1, status: 'CHANGE_REQUESTED'), 'cart_source_amount': '49.90', 'cart_source_currency': 'EUR'};
      final m = QuoteDraftModel.fromOrder(OrderDetail.fromJson(orderJson(quotes: [q])));
      expect(m.cartPriceEur, '49,90');
      expect(m.freightXof, 9000);
      expect(m.isValid, isTrue);
    });

    test('toJson sends euros with a dot', () {
      final j = QuoteDraftModel(cartPriceEur: '49,9', note: '  ').toJson();
      expect(j, {'cart_price': '49.9', 'cart_currency': 'EUR', 'freight_xof': null, 'admin_note': null});
      expect(QuoteDraftModel(cartPriceEur: 'abc').isValid, isFalse);
      expect(QuoteDraftModel(cartPriceEur: '0').isValid, isFalse);
    });

    test('parseFcfa', () {
      expect(parseFcfa('25 000'), 25000);
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

  test('orders know the expedition they are in', () {
    final free = OrderDetail.fromJson(orderJson());
    expect(free.inShipment, isFalse);
    expect(free.shipmentLabel, isNull);

    final inside = OrderDetail.fromJson({...orderJson(), 'shipment_id': 7, 'shipment_label': 'Départ du 15/01/2030'});
    expect(inside.inShipment, isTrue);
    expect(inside.shipmentLabel, 'Départ du 15/01/2030');

    final row = OrderSummary.fromJson({
      'id': 1,
      'public_ref': 'FLR-ABCDE',
      'status': 'PURCHASED',
      'customer_name': 'Awa',
      'total_xof': 1000,
      'created_at': '2026-10-01T10:00:00Z',
      'status_changed_at': '2026-10-02T10:00:00Z',
      'shipment_id': 7,
      'shipment_label': 'Départ du 15/01/2030',
    });
    expect(row.inShipment, isTrue);
    expect(row.shipmentLabel, 'Départ du 15/01/2030');
    // Older servers send neither field: the app keeps working.
    final legacy = OrderSummary.fromJson({
      'id': 2,
      'public_ref': 'FLR-ZZZZZ',
      'status': 'PURCHASED',
      'customer_name': null,
      'total_xof': null,
      'created_at': '2026-10-01T10:00:00Z',
      'status_changed_at': '2026-10-02T10:00:00Z',
    });
    expect(legacy.inShipment, isFalse);
    expect(legacy.shipmentLabel, isNull);
  });
}
