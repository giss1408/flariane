import 'package:dio/dio.dart';

import '../core/api_client.dart';
import 'models.dart';

class LoginResult {
  LoginResult({required this.status, required this.deviceId, this.deviceSecret, this.accessToken, this.refreshToken});

  final String status; // ok | device_pending
  final int deviceId;
  final String? deviceSecret;
  final String? accessToken;
  final String? refreshToken;
}

class Tokens {
  Tokens(this.accessToken, this.refreshToken);

  final String accessToken;
  final String refreshToken;
}

/// One method per backend route used by the app. Throws [ApiException].
class AdminApi {
  AdminApi(this.client, {Dio? authDio})
      // Refresh goes through a bare Dio: refreshing inside the main client's queued error
      // interceptor would deadlock if the refresh itself failed.
      : _authDio = authDio ?? Dio(BaseOptions(baseUrl: client.dio.options.baseUrl, contentType: 'application/json'));

  final ApiClient client;
  final Dio _authDio;

  Future<LoginResult> login({
    required String email,
    required String password,
    required String totp,
    required String deviceName,
    required String platform,
    int? deviceId,
    String? deviceSecret,
  }) async {
    try {
      final res = await _authDio.post('/admin/auth/login', data: {
        'email': email,
        'password': password,
        'totp': totp,
        'device': {
          'device_id': deviceId,
          'device_secret': deviceSecret,
          'name': deviceName,
          'platform': platform,
        },
      });
      final j = res.data as Map<String, dynamic>;
      final tokens = j['tokens'] as Map<String, dynamic>?;
      return LoginResult(
        status: j['status'] as String,
        deviceId: j['device_id'] as int,
        deviceSecret: j['device_secret'] as String?,
        accessToken: tokens?['access_token'] as String?,
        refreshToken: tokens?['refresh_token'] as String?,
      );
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<Tokens> refresh({required String refreshToken, required int deviceId, required String deviceSecret}) async {
    try {
      final res = await _authDio.post('/admin/auth/refresh', data: {
        'refresh_token': refreshToken,
        'device_id': deviceId,
        'device_secret': deviceSecret,
      });
      final j = res.data as Map<String, dynamic>;
      return Tokens(j['access_token'] as String, j['refresh_token'] as String);
    } catch (e) {
      throw toApiException(e);
    }
  }

  Future<void> logout({required String refreshToken, required int deviceId, required String deviceSecret}) async {
    try {
      await _authDio.post('/admin/auth/logout',
          data: {'refresh_token': refreshToken, 'device_id': deviceId, 'device_secret': deviceSecret});
    } catch (_) {
      // Best effort: the local session is cleared regardless.
    }
  }

  Future<AdminMe> me() => client.call((d) => d.get('/admin/auth/me'), (j) => AdminMe.fromJson(j as Map<String, dynamic>));

  Future<void> setPushToken(String token) =>
      client.call((d) => d.post('/admin/auth/push-token', data: {'push_token': token}), (_) {});

  Future<List<OrderSummary>> inbox(String tab, {String? search}) => client.call(
        (d) => d.get('/admin/orders', queryParameters: {'tab': tab, if (search != null && search.isNotEmpty) 'q': search}),
        (j) => (j as List).cast<Map<String, dynamic>>().map(OrderSummary.fromJson).toList(),
      );

  Future<OrderDetail> order(int id) =>
      client.call((d) => d.get('/admin/orders/$id'), (j) => OrderDetail.fromJson(j as Map<String, dynamic>));

  Future<String> resetCustomerPassword(int customerId) => client.call(
      (d) => d.post('/admin/customers/$customerId/reset-password'), (j) => (j as Map)['temporary_password'] as String);

  Future<String> revealPhone(int orderId) =>
      client.call((d) => d.post('/admin/orders/$orderId/reveal-phone'), (j) => (j as Map)['phone'] as String);

  Future<Quote> saveDraft(int orderId, Map<String, dynamic> body) => client.call(
        (d) => d.put('/admin/orders/$orderId/quote-draft', data: body),
        (j) => Quote.fromJson(j as Map<String, dynamic>),
      );

  Future<Quote> uploadQuoteScreenshot(int orderId, String path) => client.call(
        (d) async => d.post('/admin/orders/$orderId/quote-screenshot', data: FormData.fromMap({'file': await MultipartFile.fromFile(path)})),
        (j) => Quote.fromJson(j as Map<String, dynamic>),
      );

  Future<Quote> sendQuote(int orderId, int version, {bool confirmLowFee = false}) => client.call(
        (d) => d.post('/admin/orders/$orderId/quotes/$version/send', data: {'confirm_low_fee': confirmLowFee}),
        (j) => Quote.fromJson(j as Map<String, dynamic>),
      );

  Future<Map<String, dynamic>> purchase(int orderId, Map<String, dynamic> body) => client.call(
        (d) => d.post('/admin/orders/$orderId/purchase', data: body),
        (j) => j as Map<String, dynamic>,
      );

  Future<void> cancelItemByStore(int orderId, int itemId) =>
      client.call((d) => d.post('/admin/orders/$orderId/items/$itemId/cancel-by-store', data: {}), (_) {});

  /// Returns the new 6-digit pickup code (only the hash is kept server-side).
  Future<String> readyForPickup(int orderId, {int? pickupPointId}) => client.call(
        (d) => d.post('/admin/orders/$orderId/ready-for-pickup', data: {'pickup_point_id': pickupPointId}),
        (j) => (j as Map)['code'] as String,
      );

  /// wa.me link with a pre-written message, sent from the admin's own WhatsApp.
  Future<String> whatsappLink(int orderId, String kind, {String? code}) => client.call(
        (d) => d.post('/admin/orders/$orderId/whatsapp', data: {'kind': kind, 'code': code}),
        (j) => (j as Map)['url'] as String,
      );

  Future<void> confirmPickup(int orderId, String code) =>
      client.call((d) => d.post('/admin/orders/$orderId/pickup', data: {'code': code}), (_) {});

  Future<Map<String, dynamic>> settings() =>
      client.call((d) => d.get('/admin/settings'), (j) => j as Map<String, dynamic>);

  Future<List<PickupPoint>> pickupPoints() => client.call(
        (d) => d.get('/admin/pickup-points'),
        (j) => (j as List).cast<Map<String, dynamic>>().map(PickupPoint.fromJson).toList(),
      );

  Future<List<DispatchGroup>> dispatch() => client.call(
        (d) => d.get('/admin/dispatch'),
        (j) => (j as List).cast<Map<String, dynamic>>().map(DispatchGroup.fromJson).toList(),
      );

  Future<List<Shipment>> shipments() => client.call(
        (d) => d.get('/admin/shipments'),
        (j) => (j as List).cast<Map<String, dynamic>>().map(Shipment.fromJson).toList(),
      );

  Future<Shipment> createShipment(String label, {String? forwarder}) => client.call(
        (d) => d.post('/admin/shipments', data: {'label': label, 'forwarder': forwarder}),
        (j) => Shipment.fromJson(j as Map<String, dynamic>),
      );

  Future<Shipment> addToShipment(int shipmentId, List<int> orderIds) => client.call(
        (d) => d.post('/admin/shipments/$shipmentId/orders', data: {'order_ids': orderIds}),
        (j) => Shipment.fromJson(j as Map<String, dynamic>),
      );

  Future<Shipment> departShipment(int shipmentId, {String? trackingRef, String? weightKg, int? costXof}) => client.call(
        (d) => d.post('/admin/shipments/$shipmentId/depart',
            data: {'tracking_ref': trackingRef, 'weight_kg': weightKg, 'cost_xof': costXof}),
        (j) => Shipment.fromJson(j as Map<String, dynamic>),
      );

  Future<Shipment> arriveShipment(int shipmentId) => client.call(
        (d) => d.post('/admin/shipments/$shipmentId/arrive'),
        (j) => Shipment.fromJson(j as Map<String, dynamic>),
      );

  // ---- back office (SUPER_ADMIN unless noted)

  Future<List<Map<String, dynamic>>> _list(String path, [Map<String, dynamic>? q]) =>
      client.call((d) => d.get(path, queryParameters: q), (j) => (j as List).cast<Map<String, dynamic>>());

  Future<List<Map<String, dynamic>>> devices() => _list('/admin/devices');
  Future<void> approveDevice(int id) => client.call((d) => d.post('/admin/devices/$id/approve'), (_) {});
  Future<void> revokeDevice(int id) => client.call((d) => d.post('/admin/devices/$id/revoke'), (_) {});

  /// VIEWER+
  Future<List<Map<String, dynamic>>> refunds({String? status}) => _list('/admin/refunds', {if (status != null) 'status': status});
  Future<void> completeRefund(int id, String externalRef) =>
      client.call((d) => d.post('/admin/refunds/$id/complete', data: {'external_ref': externalRef}), (_) {});

  /// VIEWER+
  Future<List<Map<String, dynamic>>> heldPayments() => _list('/admin/payments/held');
  Future<void> refundHeldPayment(int paymentId) => client.call((d) => d.post('/admin/payments/$paymentId/refund'), (_) {});

  Future<Map<String, dynamic>> updateSettings(Map<String, dynamic> body) =>
      client.call((d) => d.put('/admin/settings', data: body), (j) => j as Map<String, dynamic>);

  Future<void> savePickupPoint(Map<String, dynamic> body, {int? id}) => client.call(
      (d) => id == null ? d.post('/admin/pickup-points', data: body) : d.put('/admin/pickup-points/$id', data: body), (_) {});

  Future<List<Map<String, dynamic>>> adminUsers() => _list('/admin/users');
  Future<String> createAdminUser(Map<String, dynamic> body) =>
      client.call((d) => d.post('/admin/users', data: body), (j) => (j as Map)['totp_uri'] as String);
  Future<void> deactivateAdminUser(int id) => client.call((d) => d.post('/admin/users/$id/deactivate'), (_) {});

  /// VIEWER+
  /// Wave QR payments: the admin saw the money arrive in their Wave app.
  Future<void> confirmPayment(int orderId, {String? transactionRef}) => client.call(
        (d) => d.post('/admin/orders/$orderId/confirm-payment', data: {'transaction_ref': transactionRef}),
        (_) {},
      );

  /// The customer's payment screenshot (private: fetched with the admin token).
  Future<List<int>> paymentProof(int orderId) => client.call(
        (d) => d.get('/admin/orders/$orderId/payment-proof', options: Options(responseType: ResponseType.bytes)),
        (j) => j as List<int>,
      );

  Future<Map<String, dynamic>> uploadWaveQr(String path) => client.call(
        (d) async => d.post('/admin/settings/wave-qr', data: FormData.fromMap({'file': await MultipartFile.fromFile(path)})),
        (j) => j as Map<String, dynamic>,
      );

  Future<Map<String, dynamic>> reportSummary() =>
      client.call((d) => d.get('/admin/reports/summary'), (j) => j as Map<String, dynamic>);
}
