DateTime? _date(Object? v) => v == null ? null : DateTime.parse(v as String);
int? _int(Object? v) => v == null ? null : (v as num).toInt();
List<T> _list<T>(Object? v, T Function(Map<String, dynamic>) f) =>
    ((v as List?) ?? const []).cast<Map<String, dynamic>>().map(f).toList();

class OrderSummary {
  OrderSummary({
    required this.id,
    required this.publicRef,
    required this.status,
    required this.customerName,
    required this.totalXof,
    required this.createdAt,
    required this.statusChangedAt,
    required this.hasChangeRequest,
  });

  factory OrderSummary.fromJson(Map<String, dynamic> j) => OrderSummary(
        id: j['id'] as int,
        publicRef: j['public_ref'] as String,
        status: j['status'] as String,
        customerName: j['customer_name'] as String?,
        totalXof: _int(j['total_xof']),
        createdAt: _date(j['created_at'])!,
        statusChangedAt: _date(j['status_changed_at'])!,
        hasChangeRequest: j['has_change_request'] as bool? ?? false,
      );

  final int id;
  final String publicRef;
  final String status;
  final String? customerName;
  final int? totalXof;
  final DateTime createdAt;
  final DateTime statusChangedAt;
  final bool hasChangeRequest;
}

class PickupPoint {
  PickupPoint({required this.id, required this.name, required this.address, required this.commune, required this.openingHours});

  factory PickupPoint.fromJson(Map<String, dynamic> j) => PickupPoint(
        id: j['id'] as int,
        name: j['name'] as String,
        address: j['address'] as String,
        commune: j['commune'] as String,
        openingHours: j['opening_hours'] as String,
      );

  final int id;
  final String name;
  final String address;
  final String commune;
  final String openingHours;
}

class DeliveryLocation {
  DeliveryLocation({required this.commune, required this.quartier, this.landmark, this.mapsUrl});

  factory DeliveryLocation.fromJson(Map<String, dynamic> j) => DeliveryLocation(
        commune: j['commune'] as String,
        quartier: j['quartier'] as String,
        landmark: j['landmark'] as String?,
        mapsUrl: j['maps_url'] as String?,
      );

  final String commune;
  final String quartier;
  final String? landmark;
  final String? mapsUrl;
}

DeliveryLocation? _loc(Object? j) => j == null ? null : DeliveryLocation.fromJson(j as Map<String, dynamic>);

class OrderItem {
  OrderItem({
    required this.id,
    required this.title,
    required this.size,
    required this.color,
    required this.qty,
    required this.sourcePrice,
    required this.sourceCurrency,
    required this.sourceUrl,
    required this.itemStatus,
    required this.active,
  });

  factory OrderItem.fromJson(Map<String, dynamic> j) => OrderItem(
        id: j['id'] as int,
        title: j['title'] as String,
        size: j['size'] as String?,
        color: j['color'] as String?,
        qty: j['qty'] as int,
        sourcePrice: j['source_price'].toString(),
        sourceCurrency: j['source_currency'] as String,
        sourceUrl: j['source_url'] as String?,
        itemStatus: j['item_status'] as String,
        active: j['active'] as bool,
      );

  final int id;
  final String title;
  final String? size;
  final String? color;
  final int qty;
  final String sourcePrice;
  final String sourceCurrency;
  final String? sourceUrl;
  final String itemStatus;
  final bool active;
}

class QuoteLine {
  QuoteLine({
    required this.orderItemId,
    required this.title,
    required this.size,
    required this.color,
    required this.qty,
    required this.unitPriceXof,
    required this.lineTotalXof,
  });

  factory QuoteLine.fromJson(Map<String, dynamic> j) => QuoteLine(
        orderItemId: j['order_item_id'] as int,
        title: j['title'] as String,
        size: j['size'] as String?,
        color: j['color'] as String?,
        qty: j['qty'] as int,
        unitPriceXof: _int(j['unit_price_xof'])!,
        lineTotalXof: _int(j['line_total_xof'])!,
      );

  final int orderItemId;
  final String title;
  final String? size;
  final String? color;
  final int qty;
  final int unitPriceXof;
  final int lineTotalXof;

  String get variant => [size, color].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
}

class Quote {
  Quote({
    required this.id,
    required this.version,
    required this.status,
    required this.itemsXof,
    required this.freightXof,
    required this.customsXof,
    required this.feeXof,
    required this.totalXof,
    required this.adminNote,
    required this.expiresAt,
    required this.sentAt,
    required this.answeredAt,
    required this.fxRates,
    required this.minFeeXof,
    required this.feeBelowMinimum,
    required this.lines,
    this.screenshotUrl,
  });

  factory Quote.fromJson(Map<String, dynamic> j) => Quote(
        id: j['id'] as int,
        version: j['version'] as int,
        status: j['status'] as String,
        itemsXof: _int(j['items_xof'])!,
        freightXof: _int(j['freight_xof'])!,
        customsXof: _int(j['customs_xof'])!,
        feeXof: _int(j['fee_xof'])!,
        totalXof: _int(j['total_xof'])!,
        adminNote: j['admin_note'] as String?,
        expiresAt: _date(j['expires_at']),
        sentAt: _date(j['sent_at']),
        answeredAt: _date(j['answered_at']),
        fxRates: ((j['fx_rates'] as Map?) ?? {}).map((k, v) => MapEntry(k as String, v.toString())),
        minFeeXof: _int(j['min_fee_xof']) ?? 0,
        feeBelowMinimum: j['fee_below_minimum'] as bool? ?? false,
        lines: _list(j['lines'], QuoteLine.fromJson),
        screenshotUrl: j['screenshot_url'] as String?,
      );

  final int id;
  final int version;
  final String status;
  final int itemsXof;
  final int freightXof;
  final int customsXof;
  final int feeXof;
  final int totalXof;
  final String? adminNote;
  final DateTime? expiresAt;
  final DateTime? sentAt;
  final DateTime? answeredAt;
  final Map<String, String> fxRates;
  final int minFeeXof;
  final bool feeBelowMinimum;
  final List<QuoteLine> lines;
  final String? screenshotUrl;

  bool get isCartMode => lines.isEmpty;
}

class ChangeRequest {
  ChangeRequest({
    required this.quoteId,
    required this.newCartUrl,
    required this.removedItemIds,
    required this.lineChanges,
    required this.note,
    required this.createdAt,
  });

  factory ChangeRequest.fromJson(Map<String, dynamic> j) => ChangeRequest(
        quoteId: j['quote_id'] as int,
        newCartUrl: j['new_cart_url'] as String?,
        removedItemIds: ((j['removed_item_ids'] as List?) ?? []).cast<int>(),
        lineChanges: ((j['line_changes'] as List?) ?? []).cast<Map<String, dynamic>>(),
        note: j['note'] as String?,
        createdAt: _date(j['created_at'])!,
      );

  final int quoteId;
  final String? newCartUrl;
  final List<int> removedItemIds;
  final List<Map<String, dynamic>> lineChanges;
  final String? note;
  final DateTime createdAt;
}

class Attachment {
  Attachment({required this.id, required this.url});

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(id: j['id'] as int, url: j['url'] as String);

  final int id;
  final String url;
}

class PaymentInfo {
  PaymentInfo({required this.status, required this.amountXof});

  factory PaymentInfo.fromJson(Map<String, dynamic> j) =>
      PaymentInfo(status: j['status'] as String, amountXof: _int(j['amount_xof'])!);

  final String status;
  final int amountXof;
}

class StatusEvent {
  StatusEvent({required this.toStatus, required this.createdAt});

  factory StatusEvent.fromJson(Map<String, dynamic> j) =>
      StatusEvent(toStatus: j['to_status'] as String, createdAt: _date(j['created_at'])!);

  final String toStatus;
  final DateTime createdAt;
}

class Purchase {
  Purchase({required this.storeOrderRef, required this.paidXof, required this.decision});

  factory Purchase.fromJson(Map<String, dynamic> j) => Purchase(
        storeOrderRef: j['store_order_ref'] as String,
        paidXof: _int(j['paid_xof'])!,
        decision: j['price_increase_decision'] as String?,
      );

  final String storeOrderRef;
  final int paidXof;
  final String? decision;
}

class OrderDetail {
  OrderDetail({
    required this.id,
    required this.publicRef,
    required this.status,
    required this.customerId,
    required this.customerName,
    required this.customerPhoneMasked,
    this.store = 'SHEIN',
    required this.sourceCartUrl,
    required this.submittedLinks,
    required this.customerNote,
    required this.pickupPoint,
    this.deliveryLocation,
    required this.items,
    required this.quotes,
    required this.changeRequests,
    required this.attachments,
    required this.payments,
    required this.purchase,
    required this.history,
    required this.shipmentId,
  });

  factory OrderDetail.fromJson(Map<String, dynamic> j) => OrderDetail(
        id: j['id'] as int,
        publicRef: j['public_ref'] as String,
        status: j['status'] as String,
        customerId: j['customer_id'] as int,
        customerName: j['customer_name'] as String?,
        customerPhoneMasked: j['customer_phone_masked'] as String? ?? '',
        store: j['store'] as String? ?? 'SHEIN',
        sourceCartUrl: j['source_cart_url'] as String?,
        submittedLinks: ((j['submitted_links'] as List?) ?? []).cast<String>(),
        customerNote: j['customer_note'] as String?,
        pickupPoint: j['pickup_point'] == null ? null : PickupPoint.fromJson(j['pickup_point'] as Map<String, dynamic>),
        deliveryLocation: _loc(j['delivery_location']),
        items: _list(j['items'], OrderItem.fromJson),
        quotes: _list(j['quotes'], Quote.fromJson),
        changeRequests: _list(j['change_requests'], ChangeRequest.fromJson),
        attachments: _list(j['attachments'], Attachment.fromJson),
        payments: _list(j['payments'], PaymentInfo.fromJson),
        purchase: j['purchase'] == null ? null : Purchase.fromJson(j['purchase'] as Map<String, dynamic>),
        history: _list(j['history'], StatusEvent.fromJson),
        shipmentId: j['shipment_id'] as int?,
      );

  final int id;
  final String publicRef;
  final String status;
  final int customerId;
  final String? customerName;
  final String customerPhoneMasked;
  final String store; // SHEIN | TEMU
  final String? sourceCartUrl;
  final List<String> submittedLinks;
  final String? customerNote;
  final PickupPoint? pickupPoint;
  final DeliveryLocation? deliveryLocation;
  final List<OrderItem> items;
  final List<Quote> quotes; // newest first
  final List<ChangeRequest> changeRequests; // newest first
  final List<Attachment> attachments;
  final List<PaymentInfo> payments;
  final Purchase? purchase;
  final List<StatusEvent> history;
  final int? shipmentId;

  String get storeName => store == 'TEMU' ? 'Temu' : 'SHEIN';

  Quote? get latestQuote => quotes.isEmpty ? null : quotes.first;
  Quote? get draft => quotes.where((q) => q.status == 'DRAFT').firstOrNull;
  Quote? get latestSent => quotes.where((q) => q.status != 'DRAFT').firstOrNull;
  Quote? get accepted => quotes.where((q) => q.status == 'ACCEPTED').firstOrNull;
  ChangeRequest? get pendingChangeRequest =>
      latestSent?.status == 'CHANGE_REQUESTED' ? changeRequests.firstOrNull : null;
  List<OrderItem> get activeItems => items.where((i) => i.active).toList();
}

class Shipment {
  Shipment({
    required this.id,
    required this.label,
    required this.forwarder,
    required this.trackingRef,
    required this.status,
    required this.departedAt,
    required this.arrivedAt,
    required this.orderRefs,
  });

  factory Shipment.fromJson(Map<String, dynamic> j) => Shipment(
        id: j['id'] as int,
        label: j['label'] as String,
        forwarder: j['forwarder'] as String?,
        trackingRef: j['tracking_ref'] as String?,
        status: j['status'] as String,
        departedAt: _date(j['departed_at']),
        arrivedAt: _date(j['arrived_at']),
        orderRefs: ((j['order_refs'] as List?) ?? []).cast<String>(),
      );

  final int id;
  final String label;
  final String? forwarder;
  final String? trackingRef;
  final String status;
  final DateTime? departedAt;
  final DateTime? arrivedAt;
  final List<String> orderRefs;
}

class DispatchGroup {
  DispatchGroup({required this.commune, required this.orders});

  factory DispatchGroup.fromJson(Map<String, dynamic> j) => DispatchGroup(
        commune: j['commune'] as String,
        orders: [
          for (final o in (j['orders'] as List).cast<Map<String, dynamic>>())
            (
              id: o['order_id'] as int,
              ref: o['public_ref'] as String,
              status: o['status'] as String,
              name: o['customer_name'] as String?,
              location: _loc(o['location']),
            ),
        ],
      );

  final String commune;
  final List<({int id, String ref, String status, String? name, DeliveryLocation? location})> orders;
}

class AdminMe {
  AdminMe({required this.id, required this.email, required this.name, required this.role, required this.deviceId});

  factory AdminMe.fromJson(Map<String, dynamic> j) => AdminMe(
        id: j['id'] as int,
        email: j['email'] as String,
        name: j['name'] as String,
        role: j['role'] as String,
        deviceId: j['device_id'] as int,
      );

  final int id;
  final String email;
  final String name;
  final String role;
  final int deviceId;

  bool get canOperate => role == 'OPERATOR' || role == 'SUPER_ADMIN';
}
