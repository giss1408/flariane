import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/session.dart';
import 'common.dart';

const whatsappGreen = Color(0xFF25D366);

/// Opens WhatsApp on the customer's chat with the message already written; the admin taps Send.
Future<void> sendWhatsApp(BuildContext context, WidgetRef ref, int orderId, String kind, {String? code}) async {
  try {
    final url = await ref.read(adminApiProvider).whatsappLink(orderId, kind, code: code);
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) showInfo(context, 'WhatsApp n’a pas pu s’ouvrir.');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class WhatsAppButton extends StatelessWidget {
  const WhatsAppButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF128C7E), side: const BorderSide(color: whatsappGreen, width: 1.5)),
        icon: const Icon(Icons.chat_rounded),
        label: Text(label),
        onPressed: onPressed,
      );
}
