import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api/api_client.dart';
import 'outbox/outbox.dart';
import 'outbox/outbox_repository.dart';

/// Thin layer over the outbox: a screen calls one of these and is done. Nothing
/// here talks to the network except [finishJobWork], which cannot be queued.
class FieldRepository {
  FieldRepository(this._api, this._outbox);

  final ApiClient _api;
  final OutboxRepository _outbox;

  Future<void> confirmPickup({
    required int id,
    required String label,
    List<String> uploadLocalIds = const [],
    String? note,
    Map<String, dynamic> location = const {},
  }) =>
      _outbox.enqueue(
        kind: IntentKind.confirmPickup,
        recordId: id,
        recordLabel: label,
        body: {'note': ?note, ...location},
        uploadLocalIds: uploadLocalIds,
      );

  Future<void> cancelPickup({
    required int id,
    required String label,
    required String reason,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.cancelPickup,
        recordId: id,
        recordLabel: label,
        body: {'reason': reason},
      );

  /// The one multi-record intent, because operators select a handful at once.
  Future<void> takeDeliveries(List<int> ids, {String? label}) => _outbox.enqueue(
        kind: IntentKind.takeDeliveries,
        recordId: ids.length == 1 ? ids.first : null,
        recordLabel: label ?? '${ids.length} parcels',
        body: {'ids': ids},
      );

  Future<void> releaseDelivery({required int id, required String label}) => _outbox.enqueue(
        kind: IntentKind.releaseDelivery,
        recordId: id,
        recordLabel: label,
      );

  Future<void> markDelivered({
    required int id,
    required String label,
    required String receiverName,
    required String signatureUploadLocalId,
    List<String> photoLocalIds = const [],
    Map<String, dynamic> location = const {},
  }) =>
      _outbox.enqueue(
        kind: IntentKind.markDelivered,
        recordId: id,
        recordLabel: label,
        body: {'receiver_name': receiverName, ...location},
        uploadLocalIds: [signatureUploadLocalId, ...photoLocalIds],
      );

  Future<void> timer({
    required int id,
    required String label,
    required bool start,
    int? jobTypeId,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.timer,
        recordId: id,
        recordLabel: label,
        body: {'action': start ? 'start' : 'stop', 'job_type_id': ?jobTypeId},
      );

  Future<void> moveDepartment({
    required int id,
    required String label,
    required int departmentId,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.department,
        recordId: id,
        recordLabel: label,
        body: {'department_id': departmentId},
      );

  /// **Online only.** It runs Odoo's stock validation chain — reservations and
  /// backorders — whose outcome cannot be predicted on the device. Queueing it
  /// would mean showing a success that may not happen.
  Future<Map<String, dynamic>> finishJobWork({required int id, required String idemKey}) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/jobwork/$id/finish',
      body: const {},
      idempotencyKey: idemKey,
    );
    return response.data ?? const {};
  }

  /// A customer's handwritten slip. Kept in memory only — never in a shared
  /// image cache on disk.
  Future<Uint8List?> jangadPage(int pickingId, int page) async {
    final response = await _api.get<List<int>>(
      '/pickups/$pickingId/jangad/$page',
      responseType: ResponseType.bytes,
    );
    final data = response.data;
    return data == null ? null : Uint8List.fromList(data);
  }
}
