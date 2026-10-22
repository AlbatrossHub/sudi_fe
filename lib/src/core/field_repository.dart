import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/docs.dart';
import 'api/api_client.dart';
import 'outbox/outbox.dart';
import 'outbox/outbox_repository.dart';
import 'v2_repository.dart';

/// Thin layer over the outbox: a screen calls one of these and is done. Nothing
/// here talks to the network except [finishJobWork], which cannot be queued.
class FieldRepository {
  FieldRepository(this._api, this._outbox);

  final ApiClient _api;
  final OutboxRepository _outbox;

  Future<OutboxItem> confirmPickup({
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

  /// "Collect it now", straight after posting a jangad for a customer: the
  /// receipt does not exist yet, so the confirm joins the jangad's chain and
  /// waits on it. When the jangad lands, its answer names the receipt and the
  /// confirm goes to `/pickups/<that id>/confirm` -- in order, both together.
  Future<OutboxItem> confirmAfterPosting({
    required OutboxItem jangad,
    required String label,
    List<String> uploadLocalIds = const [],
    String? note,
    Map<String, dynamic> location = const {},
  }) =>
      _outbox.enqueue(
        kind: IntentKind.confirmPickup,
        recordLabel: label,
        chain: jangad.chain ?? 'local:${jangad.localId}',
        dependsOn: jangad.localId,
        body: {'note': ?note, ...location},
        uploadLocalIds: uploadLocalIds,
        meta: {'posted': jangad.localId},
      );

  Future<OutboxItem> cancelPickup({
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

  /// A jangad for a customer, built by the operator the way the customer would
  /// build it. It lands in the pickup pool like any other; offline it shows in
  /// Pickups as "On this phone" from [meta].
  Future<OutboxItem> postOnBehalf({
    required OnBehalfRequest request,
    required List<String> pageLocalIds,
    required String customerName,
    required String addressLabel,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.submitOnBehalf,
        recordLabel: customerName,
        body: request.toWire(),
        uploadLocalIds: pageLocalIds,
        meta: {
          'customer_name': customerName,
          'address': addressLabel,
          'pages': pageLocalIds.length,
          'services': [for (final s in request.services) s.toDraft()],
          'note': ?request.note,
        },
      );

  /// The one multi-record intent, because operators select a handful at once.
  /// It names every parcel, so each shows it queued and each one's chain waits
  /// for it.
  Future<OutboxItem> takeDeliveries(List<int> ids, {String? label}) => _outbox.enqueue(
        kind: IntentKind.takeDeliveries,
        recordId: ids.length == 1 ? ids.first : null,
        recordIds: ids,
        recordLabel: label ?? '${ids.length} parcels',
        body: {'ids': ids},
      );

  Future<OutboxItem> releaseDelivery({required int id, required String label}) =>
      _outbox.enqueue(
        kind: IntentKind.releaseDelivery,
        recordId: id,
        recordLabel: label,
      );

  Future<OutboxItem> markDelivered({
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

  Future<OutboxItem> timer({
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

  Future<OutboxItem> moveDepartment({
    required int id,
    required String label,
    required int departmentId,
    String? departmentName,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.department,
        recordId: id,
        recordLabel: label,
        body: {'department_id': departmentId},
        meta: {'department_name': ?departmentName},
      );

  /// Manual time on a job-work receipt. Works offline, dated when it was
  /// entered; the day worked is what the person picked.
  Future<OutboxItem> logTime({
    required int id,
    required String label,
    required TimeLogRequest request,
    String? jobTypeName,
  }) =>
      _outbox.enqueue(
        kind: IntentKind.logTime,
        recordId: id,
        recordLabel: label,
        body: request.toWire(),
        meta: {'job_type_name': ?jobTypeName},
      );

  /// Marking notices read is low stakes but still works offline.
  Future<OutboxItem> markNoticesRead({List<int> ids = const [], int? upTo}) => _outbox.enqueue(
        kind: IntentKind.noticesRead,
        recordLabel: 'Notifications',
        body: upTo != null ? {'up_to': upTo} : {'ids': ids},
      );

  /// **Online only.** It runs the office system's stock validation chain —
  /// reservations and backorders — whose outcome cannot be predicted on the
  /// device. Queueing it would mean showing a success that may not happen.
  Future<Map<String, dynamic>> finishJobWork({required int id, required String idemKey}) async {
    final response = await _api.post<Map<String, dynamic>>(
      '/jobwork/$id/finish',
      body: const {},
      idempotencyKey: idemKey,
    );
    return response.data ?? const {};
  }

  /// A customer's handwritten slip, straight from the server. Screens use
  /// `V2Repository.jangadPage`, which also keeps an encrypted copy.
  Future<Uint8List?> jangadPage(int pickingId, int page) async {
    final response = await _api.get<List<int>>(
      V2Paths.jangadPage(pickingId, page),
      responseType: ResponseType.bytes,
    );
    final data = response.data;
    return data == null ? null : Uint8List.fromList(data);
  }
}
