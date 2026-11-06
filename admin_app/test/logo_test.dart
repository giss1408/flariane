import 'package:flariane_admin/core/secure_store.dart';
import 'package:flariane_admin/core/session.dart';
import 'package:flariane_admin/core/theme.dart';
import 'package:flariane_admin/features/auth/auth_screens.dart';
import 'package:flariane_admin/widgets/logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show MockApi;

void main() {
  testWidgets('the logo mark and its wordmark render', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: Center(child: FlarianeLogo(size: 88, withWordmark: true)))));
    expect(find.text('Flariane'), findsOneWidget);
    expect(find.text('ADMIN'), findsOneWidget);
    expect(find.bySemanticsLabel('Flariane Admin'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('the login screen shows the logo', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [adminApiProvider.overrideWithValue(MockApi()), secureStoreProvider.overrideWithValue(MemorySecureStore())],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const LoginScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(FlarianeLogo), findsOneWidget);
    expect(find.text('SERVEUR DE TEST'), findsNothing); // the prod flavor has no test chip
  });
}
