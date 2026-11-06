import 'package:flariane/core/format.dart';
import 'package:flariane/core/providers.dart';
import 'package:flariane/data/models.dart';
import 'package:flariane/features/account/loyalty_screen.dart';
import 'package:flariane/features/orders/order_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

import 'home_test.dart' show MockApi, host;

Loyalty loyalty({int balance = 120}) => Loyalty.fromJson({
      'balance': balance,
      'referral_code': 'AWA-7K3Q',
      'redeem_points': 100,
      'discount_percent': 10,
      'points_per_order': 5,
      'points_referral_signup': 1,
      'points_referred_order': 3,
      'history': [
        {'kind': 'ORDER', 'points': 5, 'created_at': '2026-11-02T10:00:00Z', 'order_ref': 'FLR-ABCDE'},
        {'kind': 'REFERRAL_SIGNUP', 'points': 1, 'created_at': '2026-11-01T10:00:00Z', 'friend_name': 'Aya'},
      ],
    });

Order quotedOrder({int fee = 2555}) => Order.fromJson({
      'public_ref': 'FLR-ABCDE',
      'status': 'QUOTED',
      'total_xof': 20000,
      'created_at': '2026-11-01T10:00:00Z',
      'pickup_point': null,
      'quote': {
        'version': 1,
        'status': 'SENT',
        'items_xof': 14000,
        'freight_xof': 3445,
        'customs_xof': 0,
        'fee_xof': fee,
        'total_xof': 20000,
        'expires_at': DateTime.now().add(const Duration(hours: 24)).toUtc().toIso8601String(),
        'lines': [],
        'screenshot_url': null,
      },
      'payment': null,
      'attachments': 0,
      'can_cancel': true,
      'can_request_requote': false,
    });

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  test('discount is 10 % of the fee, rounded down, and needs the points', () {
    final q = quotedOrder().quote!;
    expect(loyalty().discountFor(q.feeXof), 255);
    expect(loyalty().canRedeemOn(q), isTrue);
    expect(loyalty(balance: 99).canRedeemOn(q), isFalse);
    expect(loyalty().canRedeemOn(quotedOrder(fee: 0).quote!), isFalse);
  });

  testWidgets('points screen shows balance, code and why it changed', (tester) async {
    final api = MockApi();
    when(() => api.loyalty()).thenAnswer((_) async => loyalty());
    await tester.pumpWidget(host(const LoyaltyScreen(), overrides: [apiProvider.overrideWithValue(api)], disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.text('120'), findsOneWidget);
    expect(find.text('AWA-7K3Q'), findsOneWidget);
    expect(find.text('Les points sont crédités au retrait du colis'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Aya a rejoint Flariane'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Colis FLR-ABCDE retiré'), findsOneWidget);
    expect(find.text('Aya a rejoint Flariane'), findsOneWidget);
    expect(find.text('+5 pts'), findsOneWidget);
  });

  Future<void> pumpOrder(WidgetTester tester, Loyalty l) async {
    final api = MockApi();
    when(() => api.loyalty()).thenAnswer((_) async => l);
    when(() => api.order('FLR-ABCDE')).thenAnswer((_) async => quotedOrder());
    when(() => api.publicInfo()).thenAnswer((_) async => {'offers': [], 'support_whatsapp': null});
    when(() => api.nextDeparture()).thenAnswer((_) async => null);
    await tester.pumpWidget(host(const OrderScreen(orderRef: 'FLR-ABCDE'), overrides: [apiProvider.overrideWithValue(api)], disableAnimations: true));
    await tester.pumpAndSettle();
  }

  testWidgets('quote review: the tick box appears at 100 pts and lowers the amount to pay', (tester) async {
    await pumpOrder(tester, loyalty());
    expect(find.text('+5 pts au retrait du colis'), findsOneWidget);
    final tick = find.textContaining('Utiliser 100 pts');
    await tester.scrollUntilVisible(tick, 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('−${fcfa(255)}'), findsOneWidget);
    await tester.tap(tick);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.textContaining('Accepter et payer ${fcfa(19745)}'), findsOneWidget);
  });

  testWidgets('quote review: no tick box under 100 pts', (tester) async {
    await pumpOrder(tester, loyalty(balance: 40));
    expect(find.textContaining('Utiliser 100 pts'), findsNothing);
  });
}
