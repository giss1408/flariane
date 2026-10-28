import 'package:flariane/core/api.dart';
import 'package:flariane/core/format.dart';
import 'package:flariane/core/providers.dart';
import 'package:flariane/core/theme.dart';
import 'package:flariane/data/models.dart';
import 'package:flariane/features/orders/new_order_screen.dart';
import 'package:flariane/features/orders/order_screen.dart';
import 'package:flariane/widgets/delivery_estimate.dart';
import 'package:flariane/widgets/departure_ticket.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements CustomerApi {}

Map<String, dynamic> orderJson(String status) => {
      'public_ref': 'FLR-ABCDE',
      'status': status,
      'total_xof': 35608,
      'created_at': '2026-10-21T10:00:00Z',
      'status_changed_at': '2026-10-21T10:00:00Z',
      'source_cart_url': 'https://onelink.shein.com/57/abc',
      'submitted_links': <String>[],
      'customer_note': null,
      'pickup_point': {'id': 1, 'name': 'Flariane Cocody', 'address': 'Riviera 2', 'commune': 'Cocody', 'opening_hours': '9h–19h'},
      'quote': {
        'version': 2,
        'status': 'SENT',
        'items_xof': 19673,
        'freight_xof': 9000,
        'customs_xof': 3935,
        'fee_xof': 3000,
        'total_xof': 35608,
        'admin_note': null,
        'expires_at': DateTime.now().add(const Duration(days: 1)).toUtc().toIso8601String(),
        'sent_at': '2026-10-21T10:00:00Z',
        'lines': [
          {'order_item_id': 10, 'title': 'Robe', 'size': 'M', 'color': 'Bleu', 'qty': 1, 'unit_price_xof': 8521, 'line_total_xof': 8521},
          {'order_item_id': 11, 'title': 'Sandales', 'size': '39', 'color': 'Noir', 'qty': 2, 'unit_price_xof': 5576, 'line_total_xof': 11152},
        ],
      },
      'payment': null,
      'history': <dynamic>[],
      'attachments': 0,
      'can_cancel': true,
      'can_request_requote': false,
    };

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  test('stepper maps statuses and side exits', () {
    expect(stepIndex('QUOTED'), 0);
    expect(stepIndex('PAID'), 1);
    expect(stepIndex('READY_FOR_PICKUP'), 5);
    expect(stepIndex('CANCELLED'), -1);
  });

  test('SHEIN link detection', () {
    expect(looksLikeSheinLink('Mon panier https://onelink.shein.com/57/65rpbi9ni43f?shc=2_x'), isTrue);
    expect(looksLikeSheinLink('https://m.shein.com/fr/robe-p-1.html'), isTrue);
    expect(looksLikeSheinLink('https://shein.com.evil.com/x'), isFalse);
    expect(looksLikeSheinLink('pas de lien'), isFalse);
    expect(looksLikeSheinLink('Mon panier https://share.temu.com/abc'), isTrue);
  });

  test('change request only sends what changed', () {
    final quote = Order.fromJson(orderJson('QUOTED')).quote!;
    final body = buildChangeRequest(
      quote: quote,
      removed: {11},
      edits: {
        10: (size: 'L', color: 'Bleu', qty: 1),
        11: (size: '40', color: 'Noir', qty: 2), // removed: ignored
      },
      note: '  En L  ',
    );
    expect(body['removed_item_ids'], [11]);
    expect(body['line_changes'], [
      {'order_item_id': 10, 'size': 'L'}
    ]);
    expect(body['note'], 'En L');
    expect(body.containsKey('new_share_text'), isFalse);
  });

  testWidgets('payment stays disabled until sizes are confirmed', (tester) async {
    final api = MockApi();
    when(() => api.order('FLR-ABCDE')).thenAnswer((_) async => Order.fromJson(orderJson('QUOTED')));
    await tester.pumpWidget(ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const OrderScreen(orderRef: 'FLR-ABCDE')),
    ));
    await tester.pumpAndSettle();

    final pay = find.widgetWithText(FilledButton, 'Accepter et payer 35 608 FCFA');
    await tester.scrollUntilVisible(pay, 200);
    expect(tester.widget<FilledButton>(pay).onPressed, isNull);

    final tick = find.text('J’ai vérifié mon panier (tailles, couleurs)');
    await tester.ensureVisible(tick); // clear of the floating question button
    await tester.pumpAndSettle();
    await tester.tap(tick);
    await tester.pump();
    expect(tester.widget<FilledButton>(pay).onPressed, isNotNull);
    expect(find.text('Modifier ma commande'), findsOneWidget);
  });

  test('departure countdown', () {
    final today = DateTime(2026, 12, 3, 18);
    expect(daysUntil(DateTime(2026, 12, 15), today), 12);
    expect(countdownLabel(12), 'J-12');
    expect(countdownLabel(1), 'Demain');
    expect(countdownLabel(0), 'C’est aujourd’hui');
  });

  test('Abidjan arrival: store delivery, then next departure (or the one after), then 6 weeks', () {
    final today = DateTime(2026, 11, 2);
    // SHEIN reaches Germany 9–14 Nov: in time for a 20 Nov departure either way.
    expect(abidjanArrival('SHEIN', today, DateTime(2026, 11, 20)), (DateTime(2027, 1, 1), DateTime(2027, 1, 1)));
    // Departure on 10 Nov: the slowest parcel misses it and waits a week.
    expect(abidjanArrival('TEMU', today, DateTime(2026, 11, 10)), (DateTime(2026, 12, 22), DateTime(2027, 1, 5)));
    // No departure planned yet: assume a week's wait in Germany.
    expect(abidjanArrival('SHEIN', today, null), (DateTime(2026, 12, 28), DateTime(2027, 1, 2)));
  });
}
