import 'package:flutter/material.dart';

/// SHEIN (black) or Temu (orange) tag, so orders from the two stores are never confused.
class StoreBadge extends StatelessWidget {
  const StoreBadge(this.store, {super.key, this.small = false});

  final String store;
  final bool small;

  @override
  Widget build(BuildContext context) {
    final temu = store == 'TEMU';
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 7 : 10, vertical: small ? 2 : 4),
      decoration: BoxDecoration(color: temu ? const Color(0xFFFB7701) : const Color(0xFF111111), borderRadius: BorderRadius.circular(6)),
      child: Text(temu ? 'Temu' : 'SHEIN',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: small ? 11 : 13, letterSpacing: temu ? 0 : 0.8)),
    );
  }
}
