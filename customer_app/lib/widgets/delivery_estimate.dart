import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../core/providers.dart';
import '../core/theme.dart';

/// Days for the store to deliver to our address in Germany (usual range seen on orders).
const storeDeliveryDays = {'SHEIN': (7, 12), 'TEMU': (7, 15)};
const seaFreight = Duration(days: 42); // Germany → Abidjan, 6 weeks
const _weekly = Duration(days: 7); // a parcel that misses a departure takes the next one

/// Earliest and latest arrival in Abidjan for an order paid [today].
(DateTime, DateTime) abidjanArrival(String store, DateTime today, DateTime? nextDeparture) {
  final (min, max) = storeDeliveryDays[store] ?? storeDeliveryDays['SHEIN']!;
  DateTime leaves(DateTime inGermany) =>
      nextDeparture != null && !inGermany.isAfter(nextDeparture) ? nextDeparture : inGermany.add(_weekly);
  return (
    leaves(today.add(Duration(days: min))).add(seaFreight),
    leaves(today.add(Duration(days: max))).add(seaFreight),
  );
}

/// Shown on the quote before paying: when the parcel should reach Abidjan, and why.
class DeliveryEstimate extends ConsumerWidget {
  const DeliveryEstimate({super.key, required this.store, required this.storeName});

  final String store;
  final String storeName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final departure = ref.watch(nextDepartureProvider).valueOrNull?.departure;
    final (from, to) = abidjanArrival(store, DateTime.now(), departure);
    final (min, max) = storeDeliveryDays[store] ?? storeDeliveryDays['SHEIN']!;
    final d = DateFormat('d MMMM', 'fr');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.local_shipping_rounded, color: context.pal.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Arrivée à Abidjan : entre le ${d.format(from)} et le ${d.format(to)}',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            '• $storeName livre notre adresse en Allemagne en $min à $max jours\n'
            '• ton colis part avec le prochain départ${departure == null ? '' : ' (le ${d.format(departure)})'}, ou celui d’après s’il arrive trop tard\n'
            '• puis environ 6 semaines de transport jusqu’à Abidjan',
            style: TextStyle(color: context.pal.muted, height: 1.4),
          ),
          const SizedBox(height: 6),
          Text('Estimation : les délais de $storeName et du transport peuvent varier.',
              style: TextStyle(color: context.pal.muted, fontSize: 12)),
        ]),
      ),
    );
  }
}
