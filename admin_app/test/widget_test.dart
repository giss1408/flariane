import 'package:flariane_admin/core/attention.dart';
import 'package:flariane_admin/core/secure_store.dart';
import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/core/theme.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flariane_admin/features/auth/auth_screens.dart';
import 'package:flariane_admin/features/account/backoffice_screens.dart';
import 'package:flariane_admin/features/inbox/inbox_screen.dart';
import 'package:flariane_admin/features/inbox/payments_to_confirm.dart';
import 'package:flariane_admin/features/order/order_screen.dart';
import 'package:flariane_admin/features/shipments/shipments_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements AdminApi {}

Widget host(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
    );

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  testWidgets('login refuses a malformed TOTP before calling the API', (tester) async {
    final api = MockApi();
    when(() => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          totp: any(named: 'totp'),
          deviceName: any(named: 'deviceName'),
          platform: any(named: 'platform'),
          deviceId: any(named: 'deviceId'),
          deviceSecret: any(named: 'deviceSecret'),
        )).thenThrow(Exception('boom'));

    await tester.pumpWidget(host(const LoginScreen(), [
      adminApiProvider.overrideWithValue(api),
      secureStoreProvider.overrideWithValue(MemorySecureStore()),
    ]));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'a@flariane.ci');
    await tester.enterText(find.widgetWithText(TextFormField, 'Mot de passe'), 'pw');
    await tester.enterText(find.widgetWithText(TextFormField, 'Code à 6 chiffres (si ton compte en a un)'), '12a3');
    await tester.tap(find.text('Se connecter'));
    await tester.pump();
    expect(find.text('6 chiffres'), findsOneWidget);
    verifyNever(() => api.login(
          email: any(named: 'email'),
          password: any(named: 'password'),
          totp: any(named: 'totp'),
          deviceName: any(named: 'deviceName'),
          platform: any(named: 'platform'),
        ));
  });

  testWidgets('inbox lists orders and flags change requests', (tester) async {
    final api = MockApi();
    when(() => api.inbox(any(), search: any(named: 'search'))).thenAnswer((inv) async {
      if (inv.positionalArguments.first != 'to_quote') return [];
      return [
        OrderSummary(
          id: 1,
          publicRef: 'FLR-K3Q9A',
          status: 'QUOTE_REQUESTED',
          customerName: 'Awa',
          totalXof: null,
          createdAt: DateTime.now(),
          statusChangedAt: DateTime.now(),
          hasChangeRequest: true,
        ),
      ];
    });
    await tester.pumpWidget(host(const InboxScreen(), [adminApiProvider.overrideWithValue(api)]));
    await tester.pumpAndSettle();
    expect(find.text('FLR-K3Q9A'), findsOneWidget);
    expect(find.byIcon(Icons.edit_note_rounded), findsOneWidget);
    expect(find.text('À chiffrer'), findsWidgets);
  });

  testWidgets('inbox row shows the expedition an order is already in', (tester) async {
    final api = MockApi();
    when(() => api.inbox(any(), search: any(named: 'search'))).thenAnswer((inv) async {
      if (inv.positionalArguments.first != 'to_quote') return [];
      return [
        OrderSummary(
          id: 1,
          publicRef: 'FLR-K3Q9A',
          status: 'PURCHASED',
          customerName: 'Awa',
          totalXof: null,
          createdAt: DateTime.now(),
          statusChangedAt: DateTime.now(),
          hasChangeRequest: false,
          shipmentId: 7,
          shipmentLabel: 'Départ du 15/01/2030',
        ),
      ];
    });
    await tester.pumpWidget(host(const InboxScreen(), [adminApiProvider.overrideWithValue(api)]));
    await tester.pumpAndSettle();
    expect(find.text('Départ du 15/01/2030'), findsOneWidget);
  });

  group('order and expedition', () {
    Map<String, dynamic> purchasedOrder({int? shipmentId, String? shipmentLabel}) => {
          'id': 42,
          'public_ref': 'FLR-AAAAA',
          'created_at': '2026-10-01T10:00:00Z',
          'status': 'PURCHASED',
          'customer_id': 1,
          'customer_name': 'Awa',
          'customer_phone_masked': '+225 07 •• •• 04',
          'source_cart_url': null,
          'submitted_links': <String>[],
          'customer_note': null,
          'pickup_point': null,
          'items': <dynamic>[],
          'quotes': <dynamic>[],
          'change_requests': <dynamic>[],
          'attachments': <dynamic>[],
          'payments': <dynamic>[],
          'purchase': null,
          'history': <dynamic>[],
          'shipment_id': shipmentId,
          'shipment_label': shipmentLabel,
        };

    List<Override> asOperator(MockApi api) => [adminApiProvider.overrideWithValue(api), sessionProvider.overrideWith(_OperatorSession.new)];

    Finder addToShipment() => find.ancestor(of: find.text('Ajouter à une expédition'), matching: find.byWidgetPredicate((w) => w is FilledButton));

    testWidgets('an order already in an expedition cannot be added again and shows its expedition', (tester) async {
      final api = MockApi();
      when(() => api.order(42)).thenAnswer((_) async => OrderDetail.fromJson(purchasedOrder(shipmentId: 7, shipmentLabel: 'Départ du 15/01/2030')));
      await tester.pumpWidget(host(const OrderScreen(orderId: 42), asOperator(api)));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(addToShipment()).onPressed, isNull);
      expect(find.text('Déjà dans « Départ du 15/01/2030 »'), findsOneWidget);
      expect(find.text('Expédition'), findsOneWidget); // section title
      expect(find.text('Départ du 15/01/2030'), findsOneWidget); // the tappable card
    });

    testWidgets('an order not in an expedition can still be added', (tester) async {
      final api = MockApi();
      when(() => api.order(42)).thenAnswer((_) async => OrderDetail.fromJson(purchasedOrder()));
      await tester.pumpWidget(host(const OrderScreen(orderId: 42), asOperator(api)));
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(addToShipment()).onPressed, isNotNull);
      expect(find.textContaining('Déjà dans'), findsNothing);
    });

    testWidgets('tapping an order in an expedition opens it', (tester) async {
      final api = MockApi();
      when(() => api.shipments()).thenAnswer((_) async => [
            Shipment(
              id: 7,
              label: 'Départ du 15/01/2030',
              forwarder: null,
              trackingRef: null,
              status: 'OPEN',
              departureDate: null,
              orderDeadline: null,
              departedAt: null,
              arrivedAt: null,
              orderIds: [42],
              orderRefs: ['FLR-AAAAA'],
            ),
          ]);
      when(() => api.order(42)).thenAnswer((_) async => OrderDetail.fromJson(purchasedOrder(shipmentId: 7, shipmentLabel: 'Départ du 15/01/2030')));
      await tester.pumpWidget(host(const ShipmentScreen(shipmentId: 7), asOperator(api)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FLR-AAAAA'));
      await tester.pumpAndSettle();
      expect(find.byType(OrderScreen), findsOneWidget);
      verify(() => api.order(42)).called(greaterThan(0));
    });
  });

  group('payments to confirm', () {
    OrderSummary waiting() => OrderSummary(
          id: 42,
          publicRef: 'FLR-PAYME',
          status: 'AWAITING_PAYMENT',
          customerName: 'Awa',
          totalXof: 25000,
          createdAt: DateTime.now(),
          statusChangedAt: DateTime.now(),
          hasChangeRequest: false,
        );

    testWidgets('the banner counts them and opens the list', (tester) async {
      final api = MockApi();
      when(() => api.inbox('to_confirm', search: any(named: 'search'), store: any(named: 'store'))).thenAnswer((_) async => [waiting()]);
      await tester.pumpWidget(host(const Scaffold(body: PaymentsToConfirmBanner()), [
        adminApiProvider.overrideWithValue(api),
        attentionProvider.overrideWith((ref) async => Attention({'payments_to_confirm': 2})),
      ]));
      await tester.pumpAndSettle();
      expect(find.text('2 paiements à confirmer'), findsOneWidget);
      await tester.tap(find.text('2 paiements à confirmer'));
      await tester.pumpAndSettle();
      expect(find.text('Paiements à confirmer'), findsOneWidget); // screen title
      expect(find.text('FLR-PAYME'), findsOneWidget);
    });

    testWidgets('no banner when nothing waits', (tester) async {
      await tester.pumpWidget(host(const Scaffold(body: PaymentsToConfirmBanner()), [
        attentionProvider.overrideWith((ref) async => Attention({'payments_to_confirm': 0, 'to_quote': 3})),
      ]));
      await tester.pumpAndSettle();
      expect(find.textContaining('paiement'), findsNothing);
    });
  });

  group('offers', () {
    Map<String, dynamic> offer({bool active = true, String? endsAt}) => {
          'id': 5,
          'title': '-10 % sur tes 20 premières commandes',
          'message': 'Offre de lancement',
          'active': active,
          'ends_at': endsAt,
          'created_at': '2026-10-28T10:00:00Z',
        };

    testWidgets('lists offers and switches one off', (tester) async {
      final api = MockApi();
      when(() => api.offers()).thenAnswer((_) async => [offer()]);
      when(() => api.updateOffer(any(), any())).thenAnswer((_) async {});
      await tester.pumpWidget(host(const OffersAdminScreen(), [adminApiProvider.overrideWithValue(api)]));
      await tester.pumpAndSettle();
      expect(find.text('-10 % sur tes 20 premières commandes'), findsOneWidget);
      expect(find.textContaining('Visible par les clientes'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      verify(() => api.updateOffer(5, {'active': false})).called(1);
    });

    testWidgets('an ended offer cannot be switched back on', (tester) async {
      final api = MockApi();
      when(() => api.offers()).thenAnswer((_) async => [offer(endsAt: '2020-01-01T00:00:00Z')]);
      await tester.pumpWidget(host(const OffersAdminScreen(), [adminApiProvider.overrideWithValue(api)]));
      await tester.pumpAndSettle();
      expect(find.textContaining('Terminée'), findsWidgets);
      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    });

    testWidgets('creates an offer from the form', (tester) async {
      final api = MockApi();
      when(() => api.offers()).thenAnswer((_) async => []);
      when(() => api.createOffer(any())).thenAnswer((_) async {});
      await tester.pumpWidget(host(const OffersAdminScreen(), [adminApiProvider.overrideWithValue(api)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nouvelle offre'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Titre'), '  -15 % cette semaine ');
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      verify(() => api.createOffer({'title': '-15 % cette semaine', 'message': '', 'ends_at': null, 'active': true})).called(1);
    });

    testWidgets('a title is required', (tester) async {
      final api = MockApi();
      when(() => api.offers()).thenAnswer((_) async => []);
      await tester.pumpWidget(host(const OffersAdminScreen(), [adminApiProvider.overrideWithValue(api)]));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nouvelle offre'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enregistrer'));
      await tester.pumpAndSettle();
      verifyNever(() => api.createOffer(any()));
    });
  });
}

class _OperatorSession extends SessionController {
  @override
  SessionState build() =>
      SessionState(SessionStatus.loggedIn, me: AdminMe(id: 1, email: 'op@flariane.ci', name: 'Op', role: 'OPERATOR', deviceId: 1));
}
