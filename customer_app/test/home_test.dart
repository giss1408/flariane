import 'package:flariane/core/api.dart';
import 'package:flariane/core/providers.dart';
import 'package:flariane/core/theme.dart';
import 'package:flariane/data/models.dart';
import 'package:flariane/features/orders/home_screen.dart';
import 'package:flariane/widgets/offer_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements CustomerApi {}

OrderSummary order(String status, {String ref = 'FLR-ABCDE'}) =>
    OrderSummary(ref: ref, status: status, totalXof: 35608, createdAt: DateTime(2026, 10, 21));

Widget host(Widget child, {List<Override> overrides = const [], bool disableAnimations = false}) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, app) => MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations), child: app!),
        home: child,
      ),
    );

/// A home screen backed by a fake API.
MockApi homeApi({required List<List<OrderSummary>> orders, List<Map<String, dynamic>> offers = const []}) {
  final api = MockApi();
  var call = 0;
  when(() => api.orders()).thenAnswer((_) async => orders[call++ < orders.length ? call - 1 : orders.length - 1]);
  when(() => api.nextDeparture()).thenAnswer((_) async => null);
  when(() => api.me()).thenAnswer((_) async => Me(displayName: 'Awa', phoneMasked: '+225 07 •• •• 04', location: Location(commune: 'Cocody', quartier: 'Riviera')));
  when(() => api.publicInfo()).thenAnswer((_) async => {'offers': offers, 'support_whatsapp': null});
  when(() => api.hideOrder(any())).thenAnswer((_) async {});
  return api;
}

Future<void> scrollToOrders(WidgetTester tester, Finder target) =>
    tester.scrollUntilVisible(target, 300, scrollable: find.byType(Scrollable).first);

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  group('offer banner', () {
    test('countdown wording', () {
      final now = DateTime(2026, 10, 28, 15);
      Offer ends(DateTime? d) => Offer(id: 1, title: 't', endsAt: d);
      expect(offerCountdown(ends(null), now), isNull);
      expect(offerCountdown(ends(DateTime(2026, 10, 27)), now), isNull); // already over
      expect(offerCountdown(ends(DateTime(2026, 10, 28, 23, 59)), now), 'Se termine aujourd’hui');
      expect(offerCountdown(ends(DateTime(2026, 10, 29, 23, 59)), now), 'Plus qu’un jour');
      expect(offerCountdown(ends(DateTime(2026, 10, 31, 23, 59)), now), 'Plus que 3 jours');
    });

    testWidgets('shows the offer and sends her to a new order on tap', (tester) async {
      var taps = 0;
      final offer = Offer(id: 1, title: '-10 % sur tes 20 premières commandes', message: 'Offre de lancement', endsAt: DateTime.now().add(const Duration(days: 3)));
      await tester.pumpWidget(host(Scaffold(body: OfferBanner(offer: offer, onTap: () => taps++)), disableAnimations: true));
      await tester.pumpAndSettle();
      expect(find.text('-10 % sur tes 20 premières commandes'), findsOneWidget);
      expect(find.text('Offre de lancement'), findsOneWidget);
      expect(find.text('OFFRE'), findsOneWidget);
      expect(find.textContaining('Plus que'), findsOneWidget);
      await tester.tap(find.text('J’en profite'));
      expect(taps, 1);
    });

    testWidgets('animates by default', (tester) async {
      await tester.pumpWidget(host(Scaffold(body: OfferBanner(offer: Offer(id: 1, title: 'Promo')))));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isTrue);
    });

    testWidgets('does not animate when the phone asks for no animations', (tester) async {
      await tester.pumpWidget(host(Scaffold(body: OfferBanner(offer: Offer(id: 1, title: 'Promo'))), disableAnimations: true));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.hasRunningAnimations, isFalse);
    });

    testWidgets('no call to action when it cannot lead anywhere', (tester) async {
      await tester.pumpWidget(host(Scaffold(body: OfferBanner(offer: Offer(id: 1, title: 'Promo'))), disableAnimations: true));
      await tester.pumpAndSettle();
      expect(find.text('J’en profite'), findsNothing);
    });
  });

  group('home screen', () {
    List<Override> with_(MockApi api) => [apiProvider.overrideWithValue(api)];

    testWidgets('shows the offers the team switched on', (tester) async {
      final api = homeApi(orders: [[]], offers: [
        {'id': 1, 'title': '-10 % cette semaine', 'message': 'Pour tout le monde', 'ends_at': null},
      ]);
      await tester.pumpWidget(host(const HomeScreen(), overrides: with_(api), disableAnimations: true));
      await tester.pumpAndSettle();
      expect(find.text('-10 % cette semaine'), findsOneWidget);
    });

    testWidgets('no offer, no banner', (tester) async {
      final api = homeApi(orders: [[]]);
      await tester.pumpWidget(host(const HomeScreen(), overrides: with_(api), disableAnimations: true));
      await tester.pumpAndSettle();
      expect(find.text('OFFRE'), findsNothing);
    });

    testWidgets('a collected order can be removed from the list', (tester) async {
      final api = homeApi(orders: [
        [order('PICKED_UP')],
        [],
      ]);
      await tester.pumpWidget(host(const HomeScreen(), overrides: with_(api), disableAnimations: true));
      await tester.pumpAndSettle();
      await scrollToOrders(tester, find.byTooltip('Retirer de ma liste'));
      await tester.tap(find.byTooltip('Retirer de ma liste'));
      await tester.pumpAndSettle();
      expect(find.text('Retirer FLR-ABCDE ?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Retirer'));
      await tester.pumpAndSettle();
      verify(() => api.hideOrder('FLR-ABCDE')).called(1);
      expect(find.text('Commande retirée de ta liste.'), findsOneWidget);
      expect(find.byTooltip('Retirer de ma liste'), findsNothing);
    });

    testWidgets('"Garder" leaves the order alone', (tester) async {
      final api = homeApi(orders: [
        [order('PICKED_UP')],
      ]);
      await tester.pumpWidget(host(const HomeScreen(), overrides: with_(api), disableAnimations: true));
      await tester.pumpAndSettle();
      await scrollToOrders(tester, find.byTooltip('Retirer de ma liste'));
      await tester.tap(find.byTooltip('Retirer de ma liste'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Garder'));
      await tester.pumpAndSettle();
      verifyNever(() => api.hideOrder(any()));
      expect(find.byTooltip('Retirer de ma liste'), findsOneWidget);
    });

    testWidgets('an order still in progress has no remove button', (tester) async {
      final api = homeApi(orders: [
        [order('QUOTED')],
      ]);
      await tester.pumpWidget(host(const HomeScreen(), overrides: with_(api), disableAnimations: true));
      await tester.pumpAndSettle();
      await scrollToOrders(tester, find.text('Mes commandes'));
      expect(find.byTooltip('Retirer de ma liste'), findsNothing);
    });
  });
}
