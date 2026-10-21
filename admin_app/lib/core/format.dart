import 'package:intl/intl.dart';

/// 25000 -> "25 000 FCFA" (space thousands separator, no decimals).
String fcfa(int? amount) {
  if (amount == null) return '—';
  final digits = amount.abs().toString();
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(' ');
    buf.write(digits[i]);
  }
  return '${amount < 0 ? '-' : ''}$buf FCFA';
}

/// "il y a 3 h", "il y a 2 j"
String ago(DateTime when, {DateTime? now}) {
  final diff = (now ?? DateTime.now()).difference(when.toLocal());
  if (diff.inMinutes < 1) return "à l'instant";
  if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
  return 'il y a ${diff.inDays} j';
}

String dateTime(DateTime? when) =>
    when == null ? '—' : DateFormat("dd/MM 'à' HH'h'mm", 'fr').format(when.toLocal());

const statusLabels = {
  'QUOTE_REQUESTED': 'À chiffrer',
  'QUOTED': 'Devis envoyé',
  'AWAITING_PAYMENT': 'Attente paiement',
  'PAID': 'Payée — à acheter',
  'PURCHASED': 'Commandée',
  'IN_TRANSIT': 'En route',
  'ARRIVED': 'Arrivée',
  'READY_FOR_PICKUP': 'Prête au retrait',
  'PICKED_UP': 'Retirée',
  'CANCELLED': 'Annulée',
  'REFUND_PENDING': 'Remboursement',
  'REFUNDED': 'Remboursée',
};

const quoteStatusLabels = {
  'DRAFT': 'Brouillon',
  'SENT': 'Envoyé',
  'ACCEPTED': 'Accepté',
  'CHANGE_REQUESTED': 'Modif. demandée',
  'EXPIRED': 'Expiré',
  'SUPERSEDED': 'Remplacé',
};

/// Server error codes -> French messages for the admin.
const errorMessages = {
  'invalid_credentials': 'Email, mot de passe ou code incorrect.',
  'rate_limited': 'Trop de tentatives. Réessayez dans quelques minutes.',
  'unknown_device': 'Appareil inconnu. Reconnectez-vous pour l’enregistrer.',
  'device_revoked': 'Cet appareil a été révoqué.',
  'order_not_quotable': 'Cette commande ne peut plus être chiffrée.',
  'draft_outdated': 'Le brouillon a changé. Rechargez la commande.',
  'fee_below_minimum': 'Frais de service sous le minimum.',
  'missing_fx_rate': 'Taux de change manquant pour cette devise.',
  'checklist_incomplete': 'Cochez ou refusez chaque article.',
  'price_increase_decision_required': 'Le prix du magasin a augmenté.',
  'order_not_paid': 'La commande n’est pas payée.',
  'wrong_pickup_code': 'Code de retrait incorrect.',
  'pickup_code_locked': 'Trop d’essais : renvoyez un nouveau code au client.',
  'pickup_point_required': 'Choisissez un point de retrait.',
  'shipment_not_open': 'Cette expédition est déjà partie.',
  'order_not_purchased': 'Seules les commandes achetées peuvent être expédiées.',
  'order_already_in_shipment': 'Commande déjà dans une expédition.',
  'cart_quote_incomplete': 'Ajoute la capture du panier et son prix.',
  'no_draft': 'Enregistre d’abord le devis.',
  'shipment_empty': 'Ajoutez au moins une commande.',
};
