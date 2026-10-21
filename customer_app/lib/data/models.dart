DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);
int? _int(Object? v) => v == null ? null : (v as num).toInt();

class Me {
  Me({required this.displayName, required this.phoneMasked, this.mustChangePassword = false});

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        displayName: j['display_name'] as String?,
        phoneMasked: j['phone_masked'] as String? ?? '',
        mustChangePassword: j['must_change_password'] as bool? ?? false,
      );

  final String? displayName;
  final String phoneMasked;
  final bool mustChangePassword;
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
  OrderSummary({required this.ref, required this.status, required this.totalXof, required this.createdAt});

  factory OrderSummary.fromJson(Map<String, dynamic> j) => OrderSummary(
        ref: j['public_ref'] as String,
        status: j['status'] as String,
        totalXof: _int(j['total_xof']),
        createdAt: _date(j['created_at'])!,
      );

  final String ref;
  final String status;
  final int? totalXof;
  final DateTime createdAt;
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

  bool isOpen(DateTime now) => status == 'SENT' && expiresAt != null && expiresAt!.isAfter(now);
}

class Payment {
  Payment({required this.status, required this.amountXof, required this.launchUrl});

  factory Payment.fromJson(Map<String, dynamic> j) => Payment(
        status: j['status'] as String,
        amountXof: _int(j['amount_xof'])!,
        launchUrl: j['launch_url'] as String?,
      );

  final String status;
  final int amountXof;
  final String? launchUrl;
}

class Order {
  Order({
    required this.ref,
    required this.status,
    required this.totalXof,
    required this.createdAt,
    required this.pickupPoint,
    required this.quote,
    required this.payment,
    required this.attachments,
    required this.canCancel,
    required this.canRequestRequote,
  });

  factory Order.fromJson(Map<String, dynamic> j) => Order(
        ref: j['public_ref'] as String,
        status: j['status'] as String,
        totalXof: _int(j['total_xof']),
        createdAt: _date(j['created_at'])!,
        pickupPoint: j['pickup_point'] == null ? null : PickupPoint.fromJson(j['pickup_point'] as Map<String, dynamic>),
        quote: j['quote'] == null ? null : Quote.fromJson(j['quote'] as Map<String, dynamic>),
        payment: j['payment'] == null ? null : Payment.fromJson(j['payment'] as Map<String, dynamic>),
        attachments: j['attachments'] as int? ?? 0,
        canCancel: j['can_cancel'] as bool? ?? false,
        canRequestRequote: j['can_request_requote'] as bool? ?? false,
      );

  final String ref;
  final String status;
  final int? totalXof;
  final DateTime createdAt;
  final PickupPoint? pickupPoint;
  final Quote? quote;
  final Payment? payment;
  final int attachments;
  final bool canCancel;
  final bool canRequestRequote;

  bool get paymentPending => status == 'AWAITING_PAYMENT' && (payment?.status == 'PENDING' || payment?.status == 'INITIATED');
}
