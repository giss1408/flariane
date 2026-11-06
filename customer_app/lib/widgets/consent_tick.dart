import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../features/legal/legal_doc_screen.dart';

/// Required consent: use of the phone number to process orders (law 2013-450).
class ConsentTick extends StatelessWidget {
  const ConsentTick({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  InlineSpan _link(BuildContext context, String text, String slug) => TextSpan(
        text: text,
        style: TextStyle(color: context.pal.accent, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
        recognizer: TapGestureRecognizer()
          ..onTap = () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalDocScreen(slug: slug, title: text))),
      );

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), activeColor: AppColors.primary),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text.rich(
              TextSpan(style: const TextStyle(height: 1.4), children: [
                const TextSpan(text: 'J’accepte les '),
                _link(context, 'conditions d’utilisation', 'conditions'),
                const TextSpan(text: ' et la '),
                _link(context, 'politique de confidentialité', 'confidentialite'),
                const TextSpan(text: ', et que Flariane utilise mon numéro de téléphone pour traiter mes commandes.'),
              ]),
            ),
          ),
        ),
      ]);
}
