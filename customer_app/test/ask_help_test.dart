import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flariane/widgets/help.dart';

void main() {
  testWidgets('Poser une question sheet renders', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Builder(builder: (c) => Scaffold(body: TextButton(onPressed: () => showAskHelp(c), child: const Text('open')))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Écrire à l’équipe sur WhatsApp'), findsOneWidget);
  });
}
