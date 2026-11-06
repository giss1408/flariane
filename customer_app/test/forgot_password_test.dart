import 'package:flariane/core/api.dart';
import 'package:flariane/core/providers.dart';
import 'package:flariane/features/auth/login_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeApi extends CustomerApi {
  _FakeApi() : super(baseUrl: 'http://localhost', tokens: MemoryTokenStore());

  final requested = <String>[];

  @override
  Future<void> requestPasswordReset(String phone) async => requested.add(phone);
}

void main() {
  testWidgets('forgot password: asks the team and confirms', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(api)], child: const MaterialApp(home: LoginScreen())));
    await tester.tap(find.text('Mot de passe oublié ?'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Téléphone'), '0701020304');
    await tester.tap(find.text('Demander'));
    await tester.pumpAndSettle();
    expect(api.requested, ['0701020304']);
    expect(find.textContaining('Demande envoyée'), findsOneWidget);
  });

  testWidgets('forgot password: needs a number first', (tester) async {
    final api = _FakeApi();
    await tester.pumpWidget(ProviderScope(overrides: [apiProvider.overrideWithValue(api)], child: const MaterialApp(home: LoginScreen())));
    await tester.tap(find.text('Mot de passe oublié ?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Demander'));
    await tester.pumpAndSettle();
    expect(api.requested, isEmpty);
    expect(find.text('Saisis ton numéro de téléphone.'), findsOneWidget);
  });
}
