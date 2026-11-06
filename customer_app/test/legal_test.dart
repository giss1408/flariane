import 'package:flariane/core/providers.dart';
import 'package:flariane/data/models.dart';
import 'package:flariane/features/auth/login_screen.dart';
import 'package:flariane/features/legal/legal_hub_screen.dart';
import 'package:flariane/widgets/consent_tick.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:mocktail/mocktail.dart';

import 'home_test.dart' show MockApi, host;

LegalDoc doc(String slug, String title) => LegalDoc.fromJson({
      'slug': slug,
      'title': title,
      'icon': 'description',
      'updated': '2026-11-06',
      'summary': ['Premier point de $title.', 'Deuxième point.', 'Troisième point.'],
      'sections': [
        {'heading': 'Le service', 'paragraphs': ['Texte du service de $title.'], 'bullets': <String>[]},
        {'heading': 'Les détails', 'paragraphs': <String>[], 'bullets': ['Un détail à puces.']},
      ],
    });

MockApi legalApi() {
  final api = MockApi();
  final docs = [doc('conditions', 'Conditions d’utilisation'), doc('remboursement', 'Annulation et remboursement'), doc('confidentialite', 'Confidentialité')];
  when(() => api.legalDocuments()).thenAnswer((_) async => docs);
  for (final d in docs) {
    when(() => api.legalDocument(d.slug)).thenAnswer((_) async => d);
  }
  when(() => api.myData()).thenAnswer((_) async => {
        'customer': {'display_name': 'Awa', 'phone': '+2250701020304', 'locale': 'fr', 'created_at': '2026-10-01T10:00:00Z'},
        'orders': [
          {'ref': 'FLR-ABCDE', 'status': 'PICKED_UP', 'total_xof': 14184, 'created_at': '2026-11-02T10:00:00Z', 'cart_url': null},
        ],
      });
  return api;
}

void main() {
  setUpAll(() => initializeDateFormatting('fr'));

  List<Override> with_(MockApi api) => [apiProvider.overrideWithValue(api)];

  testWidgets('the hub lists every text with its first summary line, and "Mes données"', (tester) async {
    await tester.pumpWidget(host(const LegalHubScreen(), overrides: with_(legalApi()), disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.text('Conditions d’utilisation'), findsOneWidget);
    expect(find.text('Annulation et remboursement'), findsOneWidget);
    expect(find.text('Premier point de Confidentialité.'), findsOneWidget);
    expect(find.text('Mes données'), findsOneWidget);
  });

  testWidgets('a text opens on its summary, with the first section open and the others one tap away', (tester) async {
    await tester.pumpWidget(host(const LegalHubScreen(), overrides: with_(legalApi()), disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Annulation et remboursement'));
    await tester.pumpAndSettle();
    expect(find.text('En bref'), findsOneWidget);
    expect(find.text('Premier point de Annulation et remboursement.'), findsOneWidget);
    expect(find.text('Texte du service de Annulation et remboursement.'), findsOneWidget);
    expect(find.text('Un détail à puces.'), findsNothing);
    await tester.tap(find.text('Les détails'));
    await tester.pumpAndSettle();
    expect(find.text('Un détail à puces.'), findsOneWidget);
    expect(find.text('Dernière mise à jour : 06/11/2026'), findsOneWidget);
  });

  testWidgets('"Mes données" shows what we hold and how to correct or delete it', (tester) async {
    await tester.pumpWidget(host(const LegalHubScreen(), overrides: with_(legalApi()), disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mes données'));
    await tester.pumpAndSettle();
    expect(find.text('+2250701020304'), findsOneWidget);
    expect(find.text('Awa'), findsOneWidget);
    expect(find.text('FLR-ABCDE'), findsOneWidget);
    expect(find.text('Copier toutes mes données'), findsOneWidget);
    expect(find.textContaining('Supprimer : Mon compte'), findsOneWidget);
  });

  testWidgets('the consent text links to the terms and the privacy policy inside the app', (tester) async {
    var ticked = false;
    await tester.pumpWidget(host(Scaffold(body: ConsentTick(value: ticked, onChanged: (v) => ticked = v)), overrides: with_(legalApi()), disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.tapOnText(find.textRange.ofSubstring('conditions d’utilisation'));
    await tester.pumpAndSettle();
    expect(find.text('En bref'), findsOneWidget);
    expect(find.text('Premier point de Conditions d’utilisation.'), findsOneWidget);
  });

  testWidgets('the login screen offers the terms, the privacy policy and the legal notice before signing up', (tester) async {
    final api = legalApi();
    when(() => api.legalDocument('mentions-legales')).thenAnswer((_) async => doc('mentions-legales', 'Mentions légales'));
    await tester.pumpWidget(host(const LoginScreen(), overrides: with_(api), disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.text('Conditions'), findsOneWidget);
    expect(find.text('Confidentialité'), findsOneWidget);
    await tester.tap(find.text('Mentions légales'));
    await tester.pumpAndSettle();
    expect(find.text('Premier point de Mentions légales.'), findsOneWidget);
  });
}
