import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/providers.dart';
import '../core/theme.dart';

/// Required consent: privacy policy + being contacted on WhatsApp about orders (law 2013-450).
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
                const TextSpan(text: 'J’accepte la '),
                TextSpan(
                  text: 'politique de confidentialité',
                  style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w700, decoration: TextDecoration.underline),
                  recognizer: TapGestureRecognizer()
                    ..onTap = () => launchUrl(Uri.parse('$apiBaseUrl/legal/confidentialite'), mode: LaunchMode.externalApplication),
                ),
                const TextSpan(text: ' et d’être contactée sur WhatsApp au sujet de mes commandes.'),
              ]),
            ),
          ),
        ),
      ]);
}
