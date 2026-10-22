import 'package:flariane_admin/core/secure_store.dart';
import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/core/theme.dart';
import 'package:flariane_admin/data/admin_api.dart';
import 'package:flariane_admin/data/models.dart';
import 'package:flariane_admin/features/auth/auth_screens.dart';
import 'package:flariane_admin/features/inbox/inbox_screen.dart';
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
}
