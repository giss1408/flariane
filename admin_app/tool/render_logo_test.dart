// Renders the logo PNGs used for the launcher icon and the splash screen from the same painter the app uses:
//   flutter test tool/render_logo_test.dart && python3 tool/make_icons.py
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flariane_admin/widgets/logo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _save(String name, FlarianeMarkPainter painter, {double scale = 1, double canvas = 1024}) async {
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder);
  final size = canvas * scale;
  c.translate((canvas - size) / 2, (canvas - size) / 2);
  painter.paint(c, Size.square(size));
  final image = await recorder.endRecording().toImage(canvas.toInt(), canvas.toInt());
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  File('assets/logo/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
}

void main() {
  test('render logo PNGs', () async {
    await _save('tile_full', const FlarianeMarkPainter(fullBleed: true)); // iOS icon, legacy Android icon source
    await _save('tile_round', const FlarianeMarkPainter(shadow: false)); // rounded tile on transparent: splash
    // Adaptive icon foreground: Android keeps only the middle 66 % of the 108 dp canvas.
    await _save('foreground', const FlarianeMarkPainter(tile: false), scale: 0.62);
  });
}
