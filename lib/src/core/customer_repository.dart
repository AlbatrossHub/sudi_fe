import '../models/docs.dart';
import 'db/records_dao.dart';
import 'outbox/outbox.dart';
import 'outbox/outbox_repository.dart';

/// The customer's only write.
///
/// It is an offline intent like any field one: a capture-time idempotency key,
/// `occurred_at` from the trusted clock, and pages staged through
/// `POST /uploads` first, then quoted in page order. Since v2 it carries the
/// services picked on the dashboard: one submission is services + pages.
class CustomerRepository {
  CustomerRepository(this._outbox, this._records);

  final OutboxRepository _outbox;
  final RecordsDao _records;

  /// Give **either** [addressId] or [manualAddress] — both, or neither, is a
  /// 422.
  Future<OutboxItem> submitJangad({
    required List<String> uploadLocalIds,
    int? addressId,
    String? manualAddress,
    required String addressLabel,
    List<ServiceRequest> services = const [],
  }) async {
    assert(
      (addressId == null) != (manualAddress == null),
      'Exactly one of addressId or manualAddress',
    );
    final item = await _outbox.enqueue(
      kind: IntentKind.submitJangad,
      recordLabel: addressLabel,
      body: {
        'pickup_address_id': ?addressId,
        'manual_pickup_address': ?manualAddress,
        if (services.isNotEmpty) 'services': [for (final s in services) s.toWire()],
      },
      uploadLocalIds: uploadLocalIds,
    );
    // Offline there is no reference yet — the server mints it on arrival — so
    // the row is written now and filled in when the intent lands. The customer
    // can still see what they sent.
    await _records.insertJangad(
      localId: item.localId,
      pages: uploadLocalIds,
      address: addressLabel,
      occurredAt: item.occurredAt,
      services: [for (final s in services) s.toDraft()],
    );
    return item;
  }

  Future<List<Map<String, Object?>>> submissions() => _records.jangads();
}
