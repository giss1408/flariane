import 'package:intl/intl.dart';

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

String dateTime(DateTime? when) =>
    when == null ? '—' : DateFormat("dd/MM 'à' HH'h'mm", 'fr').format(when.toLocal());

String date(DateTime when) => DateFormat('dd/MM/yyyy', 'fr').format(when.toLocal());

/// Customer-facing stepper. Side exits (cancelled, refunds) are shown as a banner instead.
const steps = [
  ('QUOTE_REQUESTED', 'Devis'),
  ('AWAITING_PAYMENT', 'Payé'),
  ('PURCHASED', 'Commandé'),
  ('IN_TRANSIT', 'En route'),
  ('ARRIVED', 'Arrivé'),
  ('READY_FOR_PICKUP', 'Prêt au retrait'),
  ('PICKED_UP', 'Retiré'),
];

/// Index of the current step (0-based) for an order status; -1 for side exits.
int stepIndex(String status) => switch (status) {
      'QUOTE_REQUESTED' || 'QUOTED' || 'AWAITING_PAYMENT' => 0,
      'PAID' => 1,
      'PURCHASED' => 2,
      'IN_TRANSIT' => 3,
      'ARRIVED' => 4,
      'READY_FOR_PICKUP' => 5,
      'PICKED_UP' => 6,
      _ => -1,
    };

const statusLabels = {
  'QUOTE_REQUESTED': 'Devis en préparation',
  'QUOTED': 'Devis prêt',
  'AWAITING_PAYMENT': 'En attente de paiement',
  'PAID': 'Payée',
  'PURCHASED': 'Commandée',
  'IN_TRANSIT': 'En route',
  'ARRIVED': 'Arrivée à Abidjan',
  'READY_FOR_PICKUP': 'Prête au retrait',
  'PICKED_UP': 'Retirée',
  'CANCELLED': 'Annulée',
  'REFUND_PENDING': 'Remboursement en cours',
  'REFUNDED': 'Remboursée',
};

const errorMessages = {
  'invalid_phone': 'Numéro ivoirien à 10 chiffres attendu (01, 05 ou 07…).',
  'invalid_credentials': 'Numéro ou mot de passe incorrect.',
  'login_locked': 'Trop d’essais. Réessayez dans 15 minutes.',
  'phone_taken': 'Un compte existe déjà avec ce numéro. Connectez-vous.',
  'weak_password': 'Mot de passe trop simple (8 caractères minimum).',
  'no_shein_link': 'Colle le lien de partage de ton panier SHEIN ou Temu.',
  'invalid_pickup_point': 'Choisissez un point de retrait.',
  'quote_outdated': 'Le devis a été mis à jour.',
  'quote_expired': 'Ce devis a expiré. Demandez-en un nouveau.',
  'sizes_not_confirmed': 'Confirmez les tailles et couleurs.',
  'payment_in_progress': 'Un paiement Wave est en cours pour ce devis.',
  'cannot_cancel': 'Cette commande ne peut plus être annulée.',
  'orders_in_progress': 'Vous avez des commandes en cours.',
  'invalid_image': 'Image invalide.',
  'unsupported_image_type': 'Format accepté : JPEG, PNG ou WebP.',
  'file_too_large': 'Image trop lourde (10 Mo max).',
  'too_many_attachments': '10 captures maximum.',
  'incomplete_gps': 'Position GPS incomplète, réessaie.',
  'rate_limited': 'Trop de requêtes. Patientez un instant.',
};
