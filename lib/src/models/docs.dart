import '../core/clock/odoo_time.dart';
import 'v2_docs.dart';

export 'v2_docs.dart';

/// The shapes `/sync/pull` hands over. `upserts` are whole documents, not field
/// diffs, so these are read models with no merge logic in them.

class Ref {
  const Ref({required this.id, required this.name});
  final int id;
  final String name;

  static Ref? from(Object? json) {
    if (json is! Map) return null;
    return Ref(id: (json['id'] as num?)?.toInt() ?? 0, name: '${json['name'] ?? ''}');
  }
}

class ItemLine {
  const ItemLine({
    this.moveId,
    required this.sr,
    required this.product,
    required this.size,
    required this.pcs,
    required this.carats,
    this.jobType,
    this.remarks,
  });

  /// The `stock.move` behind the row: what an editable table keeps when it
  /// sends the table back.
  final int? moveId;
  final int sr;
  final String product;
  final String size;

  /// Floats at the product's UoM precision. Display what the server sends —
  /// never round a carat figure on the device.
  final double? pcs;
  final double? carats;
  final Ref? jobType;
  final String? remarks;

  factory ItemLine.fromJson(Map<String, dynamic> j) => ItemLine(
        moveId: (j['move_id'] as num?)?.toInt(),
        sr: (j['sr'] as num?)?.toInt() ?? 0,
        product: '${j['product'] ?? ''}',
        size: '${j['size'] ?? ''}',
        pcs: (j['pcs'] as num?)?.toDouble(),
        carats: (j['carats'] as num?)?.toDouble(),
        jobType: Ref.from(j['job_type']),
        remarks: j['remarks'] as String?,
      );

  static List<ItemLine> listFrom(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => ItemLine.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

class PickupDoc {
  const PickupDoc({
    required this.id,
    required this.rev,
    required this.name,
    required this.stage,
    required this.jangadPages,
    this.customer,
    this.contactPhone,
    this.pickupAddress,
    this.scheduledDate,
    this.collectedAt,
    this.collectedBy,
    this.services = const [],
  });

  final int id;
  final int rev;
  final String name;

  /// `awaiting` or `collected`. One list holds both: the collected tail is what
  /// lets an operator review the round and spot a parcel they missed.
  final String stage;
  final int jangadPages;
  final Ref? customer;
  final String? contactPhone;
  final String? pickupAddress;
  final DateTime? scheduledDate;
  final DateTime? collectedAt;
  final Ref? collectedBy;

  /// What the customer (or the operator on their behalf) asked for.
  final List<ServiceLine> services;

  bool get isCollected => stage == 'collected';

  /// Null when the phone number was not on the office records.
  String get customerLabel => customer?.name ?? 'Not yet on the office records';

  factory PickupDoc.fromJson(Map<String, dynamic> j) => PickupDoc(
        id: (j['id'] as num).toInt(),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        stage: '${j['stage'] ?? 'awaiting'}',
        jangadPages: (j['jangad_pages'] as num?)?.toInt() ?? 0,
        customer: Ref.from(j['customer']),
        contactPhone: j['contact_phone'] as String?,
        pickupAddress: j['pickup_address'] as String?,
        scheduledDate: OdooTime.parse(j['scheduled_date']),
        collectedAt: OdooTime.parse(j['collected_at']),
        collectedBy: Ref.from(j['collected_by']),
        services: ServiceLine.listFrom(j['services']),
      );
}

class DeliveryDoc {
  const DeliveryDoc({
    required this.id,
    required this.rev,
    required this.name,
    required this.stage,
    required this.items,
    this.customer,
    this.contactPhone,
    this.address,
    this.takenBy,
    this.outSince,
    this.originReceipt,
    this.deliveredAt,
    this.receivedBy,
  });

  final int id;
  final int rev;
  final String name;

  /// `awaiting`, `out` or `delivered`.
  final String stage;
  final List<ItemLine> items;
  final Ref? customer;
  final String? contactPhone;
  final String? address;
  final Ref? takenBy;
  final DateTime? outSince;
  final Ref? originReceipt;
  final DateTime? deliveredAt;
  final String? receivedBy;

  double get totalPcs => items.fold(0, (a, b) => a + (b.pcs ?? 0));
  double get totalCarats => items.fold(0, (a, b) => a + (b.carats ?? 0));

  factory DeliveryDoc.fromJson(Map<String, dynamic> j) => DeliveryDoc(
        id: (j['id'] as num).toInt(),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        stage: '${j['stage'] ?? 'awaiting'}',
        items: ItemLine.listFrom(j['items']),
        customer: Ref.from(j['customer']),
        contactPhone: j['contact_phone'] as String?,
        address: j['address'] as String?,
        takenBy: Ref.from(j['taken_by']),
        outSince: OdooTime.parse(j['out_since']),
        originReceipt: Ref.from(j['origin_receipt']),
        deliveredAt: OdooTime.parse(j['delivered_at']),
        receivedBy: j['received_by'] as String?,
      );
}

class TimerInfo {
  const TimerInfo({required this.running, this.startedAt});
  final bool running;
  final DateTime? startedAt;

  static TimerInfo from(Object? json) {
    if (json is! Map) return const TimerInfo(running: false);
    return TimerInfo(
      running: json['running'] == true,
      startedAt: OdooTime.parse(json['started_at']),
    );
  }
}

class JobWorkDoc {
  const JobWorkDoc({
    required this.id,
    required this.rev,
    required this.name,
    required this.state,
    required this.totalHours,
    required this.timer,
    required this.items,
    required this.involvedDepartments,
    required this.jangadPages,
    this.customer,
    this.scheduledDate,
    this.currentDepartment,
    this.services = const [],
    this.myHours = 0,
  });

  final int id;
  final int rev;
  final String name;
  final String state;
  final double totalHours;
  final TimerInfo timer;
  final List<ItemLine> items;
  final List<Ref> involvedDepartments;
  final int jangadPages;
  final Ref? customer;
  final DateTime? scheduledDate;
  final Ref? currentDepartment;

  /// What the customer asked for, shown above the item table.
  final List<ServiceLine> services;

  /// Hours booked on this receipt by the person holding the phone.
  final double myHours;

  double get totalPcs => items.fold(0, (a, b) => a + (b.pcs ?? 0));
  double get totalCarats => items.fold(0, (a, b) => a + (b.carats ?? 0));

  factory JobWorkDoc.fromJson(Map<String, dynamic> j) => JobWorkDoc(
        id: (j['id'] as num).toInt(),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        state: '${j['state'] ?? ''}',
        totalHours: (j['total_hours'] as num?)?.toDouble() ?? 0,
        timer: TimerInfo.from(j['timer']),
        items: ItemLine.listFrom(j['items']),
        involvedDepartments: ((j['involved_departments'] as List?) ?? const [])
            .map(Ref.from)
            .whereType<Ref>()
            .toList(),
        jangadPages: (j['jangad_pages'] as num?)?.toInt() ?? 0,
        customer: Ref.from(j['customer']),
        scheduledDate: OdooTime.parse(j['scheduled_date']),
        currentDepartment: Ref.from(j['current_department']),
        services: ServiceLine.listFrom(j['services']),
        myHours: (j['my_hours'] as num?)?.toDouble() ?? 0,
      );
}

class MeInfo {
  const MeInfo({
    required this.id,
    required this.name,
    required this.roles,
    this.login,
    this.phone,
    this.company,
    this.isCustomer = false,
    this.gstState,
  });

  final int id;
  final String name;
  final List<String> roles;
  final String? login;
  final String? phone;
  final String? company;
  final bool isCustomer;

  /// `present` / `skipped` / `missing`. A skip is a "not now", never final.
  final String? gstState;

  bool get hasPickupDelivery => roles.contains('pickup_delivery');
  bool get hasJobWork => roles.contains('job_work');
  bool get hasOffice => roles.contains('office');
  bool get canPostOnBehalf => roles.contains('jangad_on_behalf');

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roles': roles,
        'login': login,
        'phone': phone,
        'company': company,
        'is_customer': isCustomer,
        'gst_state': gstState,
      };

  MeInfo withGstState(String state) => MeInfo(
        id: id,
        name: name,
        roles: roles,
        login: login,
        phone: phone,
        company: company,
        isCustomer: isCustomer,
        gstState: state,
      );

  factory MeInfo.fromJson(Map<String, dynamic> j) => MeInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        roles: ((j['roles'] as List?) ?? const []).map((e) => '$e').toList(),
        login: j['login'] as String?,
        phone: j['phone'] as String?,
        company: j['company'] is Map ? '${(j['company'] as Map)['name']}' : j['company'] as String?,
        isCustomer: j['is_customer'] == true,
        gstState: j['gst_state'] as String?,
      );
}

class AddressSuggestion {
  const AddressSuggestion({
    required this.id,
    required this.name,
    required this.address,
    this.isDefault = false,
  });

  final int id;
  final String name;
  final String address;
  final bool isDefault;

  String get label => address.isNotEmpty ? address : name;

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'address': address, 'is_default': isDefault};

  factory AddressSuggestion.fromJson(Map<String, dynamic> j) => AddressSuggestion(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        address: '${j['address'] ?? ''}',
        isDefault: j['is_default'] == true,
      );
}

/// One handset registered to the caller, from `GET /devices`.
///
/// `sync_cursor` is the server's record of how far this phone actually got,
/// which is the number support asks for when an operator says their list looks
/// wrong. It is the server's view, so it can sit behind a phone that is holding
/// unflushed intents — that is the point of showing it.
class RegisteredDevice {
  const RegisteredDevice({
    required this.deviceUid,
    required this.isCurrent,
    required this.revoked,
    required this.syncCursor,
    this.platform,
    this.appVersion,
    this.lastSeenAt,
  });

  final String deviceUid;
  final bool isCurrent;
  final bool revoked;
  final int syncCursor;
  final String? platform;
  final String? appVersion;
  final DateTime? lastSeenAt;

  /// Full uids are 36 characters of hex and mean nothing to a reader; the first
  /// group is enough to tell two handsets apart and to quote down the phone.
  String get shortUid =>
      deviceUid.length <= 8 ? deviceUid : deviceUid.substring(0, 8);

  /// Only a version that starts with a digit gets a `v`, or a server-side
  /// placeholder renders as "vprobe".
  String? get versionLabel {
    final v = appVersion;
    if (v == null || v.isEmpty) return null;
    return RegExp(r'^\d').hasMatch(v) ? 'v$v' : v;
  }

  String get platformLabel => switch (platform) {
        'ios' => 'iPhone',
        'android' => 'Android',
        _ => 'Phone',
      };

  factory RegisteredDevice.fromJson(Map<String, dynamic> j) => RegisteredDevice(
        deviceUid: '${j['device_uid'] ?? ''}',
        isCurrent: j['is_current'] == true,
        revoked: j['revoked'] == true,
        syncCursor: (j['sync_cursor'] as num?)?.toInt() ?? 0,
        platform: j['platform'] as String?,
        appVersion: j['app_version'] as String?,
        lastSeenAt: OdooTime.parse(j['last_seen_at']),
      );
}
