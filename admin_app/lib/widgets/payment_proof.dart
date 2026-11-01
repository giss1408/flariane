import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'common.dart';

/// The customer's payment screenshot (private: fetched with the admin token), zoomable.
class PaymentProofScreen extends ConsumerWidget {
  const PaymentProofScreen({super.key, required this.orderId});

  final int orderId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        appBar: AppBar(title: const Text('Capture du paiement')),
        body: FutureBuilder<List<int>>(
          future: ref.read(adminApiProvider).paymentProof(orderId),
          builder: (context, snap) {
            if (snap.hasError) return ErrorView(snap.error!, onRetry: () => (context as Element).markNeedsBuild());
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            return InteractiveViewer(maxScale: 5, child: Center(child: Image.memory(Uint8List.fromList(snap.data!))));
          },
        ),
      );
}
