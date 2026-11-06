import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/core/theme.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flariane_admin/features/account/customers_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

class MockApi extends Mock implements AdminApi {}

Widget host(Widget child, AdminApi api) => ProviderScope(
      overrides: [adminApiProvider.overrideWithValue(api)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: child),
    );

Map<String, dynamic> detail({bool blocked = false}) => {
      'id': 7,
      'display_name': 'Awa',
      'phone_masked': '+225 07 •• •• 04',
      'created_at': DateTime.now().toIso8601String(),
      'phone_verified': true,
      'blocked': blocked,
      'orders_count': 1,
      'referral_code': 'AWA-7K3Q',
      'loyalty_points': 12,
      'recent_orders': [
        {'id': 1, 'public_ref': 'FLR-K3Q9A', 'status': 'PAID', 'total_xof': 45000, 'created_at': DateTime.now().toIso8601String()},
      ],
    };

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  testWidgets('customers list shows blocked accounts and searches', (tester) async {
    final api = MockApi();
    when(() => api.customers(q: any(named: 'q'), offset: any(named: 'offset'))).thenAnswer((inv) async => [
          {'id': 7, 'display_name': 'Awa', 'phone_masked': '+225 07 •• •• 04', 'created_at': DateTime.now().toIso8601String(),
           'phone_verified': true, 'blocked': inv.namedArguments[#q] == '', 'orders_count': 2},
        ]);
    await tester.pumpWidget(host(const CustomersScreen(), api));
    await tester.pumpAndSettle();
    expect(find.text('Awa'), findsOneWidget);
    expect(find.text('Bloqué'), findsOneWidget);
    expect(find.textContaining('2 commandes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'awa');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    verify(() => api.customers(q: 'awa', offset: any(named: 'offset'))).called(1);
  });

  testWidgets('block asks for confirmation, then blocks', (tester) async {
    final api = MockApi();
    var blocked = false;
    when(() => api.customerDetail(7)).thenAnswer((_) async => detail(blocked: blocked));
    when(() => api.blockCustomer(7, block: true)).thenAnswer((_) async => blocked = true);
    await tester.pumpWidget(host(const CustomerScreen(id: 7), api));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bloquer le compte'));
    await tester.pumpAndSettle();
    verifyNever(() => api.blockCustomer(any(), block: any(named: 'block')));
    await tester.tap(find.text('Bloquer'));
    await tester.pumpAndSettle();
    verify(() => api.blockCustomer(7, block: true)).called(1);
    expect(find.text('Débloquer le compte'), findsOneWidget);
  });

  testWidgets('delete asks for confirmation, then deletes and goes back', (tester) async {
    final api = MockApi();
    when(() => api.customerDetail(7)).thenAnswer((_) async => detail());
    when(() => api.deleteCustomer(7)).thenAnswer((_) async {});
    await tester.pumpWidget(host(Builder(builder: (c) => Scaffold(body: TextButton(
        onPressed: () => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const CustomerScreen(id: 7))), child: const Text('open')))), api));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer le compte'));
    await tester.pumpAndSettle();
    verifyNever(() => api.deleteCustomer(any()));
    await tester.tap(find.text('Supprimer'));
    await tester.pumpAndSettle();
    verify(() => api.deleteCustomer(7)).called(1);
    expect(find.text('open'), findsOneWidget);
  });
}
