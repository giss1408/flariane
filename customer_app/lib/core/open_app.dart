import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/common.dart';

/// Apps a customer jumps to while using Flariane. Android package ids; if the app is not installed the
/// Play Store page opens instead.
enum PartnerApp {
  shein('SHEIN', 'com.zzkko'),
  temu('Temu', 'com.einnovation.temu'),
  wave('Wave', 'com.wave.personal');

  const PartnerApp(this.label, this.androidPackage);
  final String label;
  final String androidPackage;
}

Future<void> openPartnerApp(BuildContext context, PartnerApp app) async {
  var opened = false;
  if (Platform.isAndroid) {
    try {
      opened = await launchUrl(Uri.parse('intent://#Intent;package=${app.androidPackage};end'), mode: LaunchMode.externalApplication);
    } catch (_) {}
    if (!opened) {
      try {
        opened = await launchUrl(Uri.parse('https://play.google.com/store/apps/details?id=${app.androidPackage}'), mode: LaunchMode.externalApplication);
      } catch (_) {}
    }
  }
  if (!opened && context.mounted) showInfo(context, 'Ouvre l’app ${app.label} depuis ton téléphone.');
}
