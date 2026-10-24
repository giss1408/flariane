import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers.dart';
import '../core/theme.dart';

/// Required consent: use of the phone number to process orders (law 2013-450).
class ConsentTick extends StatelessWidget {
  const ConsentTick({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: value, onChanged: (v) => onChanged(v ?? false), activeColor: AppColors.primary),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text.rich(
              TextSpan(style: const TextStyle(height: 1.4), children: [
                const TextSpan(text: 'J’accepte que Flariane utilise mon numéro de téléphone pour traiter mes commandes, conformément à la '),
                TextSpan(
                  text: 'politique de confidentialité',
                  style: TextStyle(color: context.pal.accent, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrl(Uri.parse('$apiBaseUrl/legal/confidentialite'), mode: LaunchMode.externalApplication),
                ),
                const TextSpan(text: '.'),
              ]),
            ),
          ),
        ),
      ]);
}
