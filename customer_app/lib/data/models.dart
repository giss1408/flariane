DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);
int? _int(Object? v) => v == null ? null : (v as num).toInt();

class Location {
  Location({required this.commune, required this.quartier, this.landmark, this.lat, this.lng});

  factory Location.fromJson(Map<String, dynamic> j) => Location(
        commune: j['commune'] as String,
        quartier: j['quartier'] as String,
        landmark: j['landmark'] as String?,
        lat: (j['lat'] as num?)?.toDouble(),
        lng: (j['lng'] as num?)?.toDouble(),
      );

  final String commune;
  final String quartier;
  final String? landmark;
  final double? lat;
  final double? lng;

  bool get hasGps => lat != null && lng != null;
  String get short => '$commune, $quartier';

  Map<String, dynamic> toJson() => {'commune': commune, 'quartier': quartier, 'landmark': landmark, 'lat': lat, 'lng': lng};
}

Location? _location(Object? j) => j == null ? null : Location.fromJson(j as Map<String, dynamic>);

class Me {
  Me({required this.displayName, required this.phoneMasked, this.mustChangePassword = false, this.location, this.phoneVerified = true, this.phoneRejected = false, this.consentRequired = false});

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        displayName: j['display_name'] as String?,
        phoneMasked: j['phone_masked'] as String? ?? '',
        mustChangePassword: j['must_change_password'] as bool? ?? false,
        location: _location(j['location']),
        phoneVerified: j['phone_verified'] as bool? ?? true,
        phoneRejected: j['phone_rejected'] as bool? ?? false,
        consentRequired: j['consent_required'] as bool? ?? false,
      );

  final String? displayName;
  final String phoneMasked;
  final bool mustChangePassword;
  final Location? location;
  final bool phoneVerified;
  final bool phoneRejected;
  final bool consentRequired;
}

class PickupPoint {
  PickupPoint({required this.id, required this.name, required this.address, required this.openingHours});

  factory PickupPoint.fromJson(Map<String, dynamic> j) => PickupPoint(
        id: j['id'] as int,
        name: j['name'] as String,
        address: j['address'] as String,
        openingHours: j['opening_hours'] as String,
      );

  final int id;
  final String name;
  final String address;
  final String openingHours;
}

class OrderSummary {
  OrderSummary({required this.ref, required this.status, required this.totalXof, required this.createdAt, this.store = 'SHEIN'});

  factory OrderSummary.fromJson(Map<String, dynamic> j) => OrderSummary(
        ref: j['public_ref'] as String,
        status: j['status'] as String,
        totalXof: _int(j['total_xof']),
        createdAt: _date(j['created_at'])!,
        store: j['store'] as String? ?? 'SHEIN',
      );

  final String ref;
  final String status;
  final int? totalXof;
  final DateTime createdAt;
  final String store;
}

/// A promotion the Flariane team shows on the home screen ("-10 % sur tes 20 premières commandes").
class Offer {
  Offer({required this.id, required this.title, this.message = '', this.endsAt});

  factory Offer.fromJson(Map<String, dynamic> j) => Offer(
        id: j['id'] as int,
        title: j['title'] as String,
        message: j['message'] as String? ?? '',
        endsAt: _date(j['ends_at'])?.toLocal(),
      );

  final int id;
  final String title;
  final String message;
  final DateTime? endsAt;
}

class QuoteLine {
  QuoteLine({required this.itemId, required this.title, this.size, this.color, required this.qty, required this.lineTotalXof});

  factory QuoteLine.fromJson(Map<String, dynamic> j) => QuoteLine(
        itemId: j['order_item_id'] as int,
        title: j['title'] as String,
        size: j['size'] as String?,
        color: j['color'] as String?,
        qty: j['qty'] as int,
        lineTotalXof: _int(j['line_total_xof'])!,
      );

  final int itemId;
  final String title;
  final String? size;
  final String? color;
  final int qty;
  final int lineTotalXof;
}

class Quote {
  Quote({
    required this.version,
    required this.status,
    required this.itemsXof,
    required this.freightXof,
    required this.customsXof,
    required this.feeXof,
    required this.totalXof,
    required this.note,
    required this.expiresAt,
    required this.lines,
    this.screenshotUrl,
    this.loyaltyPointsUsed = 0,
    this.loyaltyDiscountXof = 0,
  });

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
        version: j['version'] as int,
        status: j['status'] as String,
        itemsXof: _int(j['items_xof'])!,
        freightXof: _int(j['freight_xof'])!,
        customsXof: _int(j['customs_xof'])!,
        feeXof: _int(j['fee_xof'])!,
        totalXof: _int(j['total_xof'])!,
        note: j['admin_note'] as String?,
        expiresAt: _date(j['expires_at']),
        lines: ((j['lines'] as List?) ?? []).cast<Map<String, dynamic>>().map(QuoteLine.fromJson).toList(),
        screenshotUrl: j['screenshot_url'] as String?,
        loyaltyPointsUsed: j['loyalty_points_used'] as int? ?? 0,
        loyaltyDiscountXof: _int(j['loyalty_discount_xof']) ?? 0,
      );

  final int version;
  final String status;
  final int itemsXof;
  final int freightXof;
  final int customsXof;
  final int feeXof;
  final int totalXof;
  final String? note;
  final DateTime? expiresAt;
  final List<QuoteLine> lines;
  final String? screenshotUrl;
  final int loyaltyPointsUsed;
  final int loyaltyDiscountXof; // taken off the service fee when loyalty points were redeemed
  int get amountToPayXof => totalXof - loyaltyDiscountXof;
  bool isOpen(DateTime now) => status == 'SENT' && expiresAt != null && expiresAt!.isAfter(now);
}

class Payment {
  Payment({required this.status, required this.amountXof, required this.launchUrl, this.provider = 'WAVE', this.declared = false, this.method});

  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
        status: j['status'] as String,
        amountXof: _int(j['amount_xof'])!,
        launchUrl: j['launch_url'] as String?,
        provider: j['provider'] as String? ?? 'WAVE',
        declared: j['declared'] as bool? ?? false,
        method: j['method'] as String?,
      );

  final String status;
  final int amountXof;
  final String? launchUrl;
  final String provider; // WAVE (checkout link) | WAVE_QR (personal QR, confirmed by Flariane)
  final bool declared;
  final String? method; // WAVE | ORANGE | MOOV

  /// Paid outside the app (mobile money + screenshot), confirmed by Flariane.
  bool get isQr => provider == 'MANUAL' || provider == 'WAVE_QR';
}

class Order {
  Order({
    required this.ref,
    required this.status,
    this.store = 'SHEIN',
    required this.totalXof,
    required this.createdAt,
    required this.pickupPoint,
    this.deliveryLocation,
    required this.quote,
    required this.payment,
    required this.attachments,
    required this.canCancel,
    required this.canRequestRequote,
    this.paymentDeadline,
    this.pickupCode,
    this.loyaltyPointsEarned = 0,
  });

  factory Order.fromJson(Map<String, dynamic> j) => Order(
        ref: j['public_ref'] as String,
        status: j['status'] as String,
        store: j['store'] as String? ?? 'SHEIN',
        totalXof: _int(j['total_xof']),
        createdAt: _date(j['created_at'])!,
        pickupPoint: j['pickup_point'] == null ? null : PickupPoint.fromJson(j['pickup_point'] as Map<String, dynamic>),
        deliveryLocation: _location(j['delivery_location']),
        quote: j['quote'] == null ? null : Quote.fromJson(j['quote'] as Map<String, dynamic>),
        payment: j['payment'] == null ? null : Payment.fromJson(j['payment'] as Map<String, dynamic>),
        attachments: j['attachments'] as int? ?? 0,
        canCancel: j['can_cancel'] as bool? ?? false,
        canRequestRequote: j['can_request_requote'] as bool? ?? false,
        paymentDeadline: _date(j['payment_deadline']),
        pickupCode: j['pickup_code'] as String?,
        loyaltyPointsEarned: j['loyalty_points_earned'] as int? ?? 0,
      );

  final String ref;
  final String status;
  final int? totalXof;
  final DateTime createdAt;
  final String store; // SHEIN | TEMU
  final PickupPoint? pickupPoint;
  final Location? deliveryLocation;
  final Quote? quote;
  final Payment? payment;
  final int attachments;
  final bool canCancel;
  final bool canRequestRequote;
  final DateTime? paymentDeadline; // cancelled automatically if not paid by then
  final String? pickupCode; // 6 digits, only while the parcel waits at the pickup point
  final int loyaltyPointsEarned; // credited when the parcel was collected

  String get storeName => store == 'TEMU' ? 'Temu' : 'SHEIN';

  // Payments are manual (mobile money + screenshot), confirmed by Flariane: nothing to poll.
  bool get paymentPending => false;
}

class LoyaltyEvent {
  LoyaltyEvent({required this.kind, required this.points, required this.createdAt, this.orderRef, this.friendName});

  factory LoyaltyEvent.fromJson(Map<String, dynamic> j) => LoyaltyEvent(
        kind: j['kind'] as String,
        points: j['points'] as int,
        createdAt: _date(j['created_at'])!,
        orderRef: j['order_ref'] as String?,
        friendName: j['friend_name'] as String?,
      );

  final String kind; // REFERRAL_SIGNUP | ORDER | REFERRED_ORDER | REDEEM | RELEASE
  final int points;
  final DateTime createdAt;
  final String? orderRef;
  final String? friendName;

  /// Why the balance changed, in plain words.
  String get label => switch (kind) {
        'REFERRAL_SIGNUP' => '${friendName ?? 'Une amie'} a rejoint Flariane',
        'ORDER' => 'Colis ${orderRef ?? ''} retiré'.trim(),
        'REFERRED_ORDER' => '${friendName ?? 'Une amie'} a retiré sa première commande',
        'REDEEM' => 'Points utilisés sur ${orderRef ?? 'une commande'}',
        'RELEASE' => 'Points rendus (${orderRef ?? 'commande'} non payée)',
        _ => kind,
      };
}

class Loyalty {
  Loyalty({
    required this.balance,
    required this.referralCode,
    required this.redeemPoints,
    required this.discountPercent,
    required this.pointsPerOrder,
    required this.pointsReferralSignup,
    required this.pointsReferredOrder,
    required this.history,
  });

  factory Loyalty.fromJson(Map<String, dynamic> j) => Loyalty(
        balance: j['balance'] as int,
        referralCode: j['referral_code'] as String?,
        redeemPoints: j['redeem_points'] as int,
        discountPercent: j['discount_percent'] as int,
        pointsPerOrder: j['points_per_order'] as int,
        pointsReferralSignup: j['points_referral_signup'] as int,
        pointsReferredOrder: j['points_referred_order'] as int,
        history: ((j['history'] as List?) ?? []).cast<Map<String, dynamic>>().map(LoyaltyEvent.fromJson).toList(),
      );

  final int balance;
  final String? referralCode;
  final int redeemPoints;
  final int discountPercent;
  final int pointsPerOrder;
  final int pointsReferralSignup;
  final int pointsReferredOrder;
  final List<LoyaltyEvent> history;

  /// Service-fee reduction the redeem block of points gives on a quote with this fee (rounded down).
  int discountFor(int feeXof) => feeXof * discountPercent ~/ 100;

  bool canRedeemOn(Quote q) => balance >= redeemPoints && discountFor(q.feeXof) > 0;
}

/// One legal text (terms, refund policy, privacy…): a plain-language summary, then the full text in sections.
class LegalDoc {
  LegalDoc({required this.slug, required this.title, required this.icon, required this.summary, required this.updated, this.sections = const []});

  factory LegalDoc.fromJson(Map<String, dynamic> j) => LegalDoc(
        slug: j['slug'] as String,
        title: j['title'] as String,
        icon: j['icon'] as String? ?? '',
        summary: ((j['summary'] as List?) ?? []).cast<String>(),
        updated: j['updated'] as String? ?? '',
        sections: ((j['sections'] as List?) ?? []).cast<Map<String, dynamic>>().map(LegalSection.fromJson).toList(),
      );

  final String slug;
  final String title;
  final String icon; // route | description | undo | privacy | business
  final List<String> summary;
  final String updated; // ISO date
  final List<LegalSection> sections;

  /// 2026-11-06 → 06/11/2026
  String get updatedLabel {
    final p = updated.split('-');
    return p.length == 3 ? '${p[2]}/${p[1]}/${p[0]}' : updated;
  }
}

class LegalSection {
  LegalSection({required this.heading, this.paragraphs = const [], this.bullets = const []});

  factory LegalSection.fromJson(Map<String, dynamic> j) => LegalSection(
        heading: j['heading'] as String,
        paragraphs: ((j['paragraphs'] as List?) ?? []).cast<String>(),
        bullets: ((j['bullets'] as List?) ?? []).cast<String>(),
      );

  final String heading;
  final List<String> paragraphs;
  final List<String> bullets;
}
