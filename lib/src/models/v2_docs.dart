import '../core/clock/odoo_time.dart';
import 'docs.dart';

/// Every v2 request and response shape, in one place, so field names can be
/// reconciled with the backend's OpenAPI in one sitting
/// (`design/v2/MOBILE_V2_PERSONAS_PLAN.md` section 5, and `sudi_api/schemas.py`
/// in sudi_20). Paths live next to these in `core/v2_repository.dart`.
///
/// Wire keys are written out literally in each `fromJson` / `toJson`; nothing
/// here derives a key from a Dart name.

// ---------------------------------------------------------------- figures

/// Pieces, carats and hours as the screens print them. **Never round a figure
/// the server sent**: carats show at least two decimals and keep any more.
class Fig {
  const Fig._();

  static String pcs(num? v) {
    if (v == null) return '—';
    final d = v.toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : _trimmed(d);
  }

  static String ct(num? v) {
    if (v == null) return '—';
    final d = v.toDouble();
    final two = d.toStringAsFixed(2);
    // toStringAsFixed rounds; if that lost a digit, print the full value.
    return double.parse(two) == d ? two : _trimmed(d);
  }

  static String _trimmed(double d) {
    // Six places is finer than anything the office enters, and drops the binary
    // noise of summed lines (61.45 + 26.07 printed as 87.52000000000001 on the
    // phone, against the migrated prod data).
    return d
        .toStringAsFixed(6)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  /// `120 pcs`, `6.20 ct`, or the bare number for a service with no unit.
  static String qty(num quantity, String unit) => switch (unit) {
        'ct' => '${ct(quantity)} ct',
        'pcs' => '${pcs(quantity)} pcs',
        _ => pcs(quantity),
      };

  /// `1 h 30`, `45 min`, `0 h`.
  static String hours(num hours) {
    final minutes = (hours * 60).round();
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0 && m > 0) return '$m min';
    return m == 0 ? '$h h' : '$h h ${m.toString().padLeft(2, '0')}';
  }
}

// --------------------------------------------------------------- services

/// One requested service on a receipt (`services` on the pickup, job-work and
/// office documents). A request, not an item: nothing has been counted yet.
class ServiceLine {
  const ServiceLine({
    required this.id,
    required this.quantity,
    required this.unit,
    this.jobType,
    this.remarks,
    this.moveId,
  });

  final int id;
  final Ref? jobType;
  final double quantity;

  /// `pcs`, `ct` or empty.
  final String unit;
  final String? remarks;

  /// Set once an item line was entered from this request.
  final int? moveId;

  String get name => jobType?.name ?? 'Service';
  String get quantityLabel => Fig.qty(quantity, unit);

  factory ServiceLine.fromJson(Map<String, dynamic> j) => ServiceLine(
        id: (j['id'] as num?)?.toInt() ?? 0,
        jobType: Ref.from(j['job_type']),
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        unit: '${j['unit'] ?? ''}',
        remarks: j['remarks'] as String?,
        moveId: (j['move_id'] as num?)?.toInt(),
      );

  static List<ServiceLine> listFrom(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => ServiceLine.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

/// `GET /catalog/job-types` (staff): a service, which is also a department.
class JobTypeInfo {
  const JobTypeInfo({required this.id, required this.name, this.unit = '', this.sequence = 0});

  final int id;
  final String name;
  final String unit;
  final int sequence;

  factory JobTypeInfo.fromJson(Map<String, dynamic> j) => JobTypeInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        unit: '${j['unit'] ?? ''}',
        sequence: (j['sequence'] as num?)?.toInt() ?? 0,
      );

  static List<JobTypeInfo> listFrom(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => JobTypeInfo.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

/// `GET /services` (customer): the dashboard.
class ServiceInfo {
  const ServiceInfo({required this.id, required this.name, this.unit = '', this.description});

  final int id;
  final String name;
  final String unit;
  final String? description;

  factory ServiceInfo.fromJson(Map<String, dynamic> j) => ServiceInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        unit: '${j['unit'] ?? ''}',
        description: j['description'] as String?,
      );

  static List<ServiceInfo> listFrom(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => ServiceInfo.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

/// One service picked for a request -- by the customer on the dashboard, or by
/// an operator posting on their behalf. `services: [...]` on `POST /jangad` and
/// `POST /jangads`.
class ServiceRequest {
  const ServiceRequest({
    required this.jobTypeId,
    required this.name,
    this.unit = '',
    this.quantity = 0,
    this.remarks,
  });

  final int jobTypeId;

  /// Kept for drawing the request offline; not sent.
  final String name;
  final String unit;
  final double quantity;
  final String? remarks;

  String get quantityLabel => Fig.qty(quantity, unit);

  ServiceRequest copyWith({double? quantity, String? remarks, bool clearRemarks = false}) =>
      ServiceRequest(
        jobTypeId: jobTypeId,
        name: name,
        unit: unit,
        quantity: quantity ?? this.quantity,
        remarks: clearRemarks ? null : (remarks ?? this.remarks),
      );

  /// The wire shape (`ServiceRequestInput`).
  Map<String, dynamic> toWire() => {
        'job_type_id': jobTypeId,
        'quantity': quantity,
        if (remarks != null && remarks!.trim().isNotEmpty) 'remarks': remarks!.trim(),
      };

  /// The draft shape: the wire shape plus what the screen needs offline.
  Map<String, dynamic> toDraft() => {...toWire(), 'name': name, 'unit': unit};

  factory ServiceRequest.fromDraft(Map<String, dynamic> j) => ServiceRequest(
        jobTypeId: (j['job_type_id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        unit: '${j['unit'] ?? ''}',
        quantity: (j['quantity'] as num?)?.toDouble() ?? 0,
        remarks: j['remarks'] as String?,
      );

  static List<ServiceRequest> listFromDraft(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => ServiceRequest.fromDraft(Map<String, dynamic>.from(m)))
      .toList();

  /// `2 services · 160 pcs` -- pieces and carats summed separately.
  static String summary(List<ServiceRequest> list) {
    final pcs = list.where((s) => s.unit != 'ct').fold<double>(0, (a, s) => a + s.quantity);
    final ct = list.where((s) => s.unit == 'ct').fold<double>(0, (a, s) => a + s.quantity);
    final parts = [
      '${list.length} service${list.length == 1 ? '' : 's'}',
      if (pcs > 0) '${Fig.pcs(pcs)} pcs',
      if (ct > 0) '${Fig.ct(ct)} ct',
    ];
    return parts.join(' · ');
  }
}

// -------------------------------------------------- posting for a customer

/// `GET /customers` (role `jangad_on_behalf`).
class CustomerAddress {
  const CustomerAddress({
    required this.id,
    required this.label,
    required this.address,
    this.isDefault = false,
  });

  final int id;
  final String label;
  final String address;
  final bool isDefault;

  factory CustomerAddress.fromJson(Map<String, dynamic> j) => CustomerAddress(
        id: (j['id'] as num?)?.toInt() ?? 0,
        label: '${j['label'] ?? j['name'] ?? ''}',
        address: '${j['address'] ?? ''}',
        isDefault: j['is_default'] == true,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'address': address, 'is_default': isDefault};
}

class CustomerEntry {
  const CustomerEntry({
    required this.id,
    required this.name,
    required this.phone,
    this.gstState = 'missing',
    this.addresses = const [],
  });

  final int id;
  final String name;
  final String phone;

  /// `present` / `skipped` / `missing`.
  final String gstState;
  final List<CustomerAddress> addresses;

  bool get hasGst => gstState == 'present';

  /// A contact created from a WhatsApp number carries the number as its name
  /// and nothing else. Shown by its phone, labelled "Unnamed contact".
  bool get isNumberOnly => !RegExp(r'[A-Za-z\u0900-\u0DFF]').hasMatch(name);

  /// What a picker shows as the title.
  String get displayName => isNumberOnly ? (phone.isNotEmpty ? phone : name) : name;

  /// Real names first, alphabetically; number-only contacts after them.
  static int byName(CustomerEntry a, CustomerEntry b) {
    if (a.isNumberOnly != b.isNumberOnly) return a.isNumberOnly ? 1 : -1;
    return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  }

  /// `98200 •••45`: enough to tell two customers apart over a shoulder.
  String get maskedPhone {
    final digits = phone.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 7) return phone;
    final ten = digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    return '${ten.substring(0, 5)} •••${ten.substring(ten.length - 2)}';
  }

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final digits = q.replaceAll(RegExp(r'\D'), '');
    return name.toLowerCase().contains(q) ||
        (digits.length >= 3 && phone.replaceAll(RegExp(r'\D'), '').contains(digits));
  }

  factory CustomerEntry.fromJson(Map<String, dynamic> j) => CustomerEntry(
        id: (j['id'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        phone: '${j['phone'] ?? ''}',
        gstState: '${j['gst_state'] ?? 'missing'}',
        addresses: ((j['addresses'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => CustomerAddress.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'phone': phone,
        'gst_state': gstState,
        'addresses': [for (final a in addresses) a.toJson()],
      };

  static List<CustomerEntry> listFrom(Object? json) => (json as List? ?? const [])
      .whereType<Map>()
      .map((m) => CustomerEntry.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}

/// `POST /jangads` -- everything but the envelope and `upload_ids`, which the
/// outbox adds (the pages are staged locally and only get their server
/// references when they upload).
class OnBehalfRequest {
  const OnBehalfRequest({
    this.partnerId,
    this.phone,
    this.newCustomerName,
    this.pickupAddressId,
    this.manualPickupAddress,
    this.services = const [],
    this.note,
  });

  /// A directory customer, or ...
  final int? partnerId;

  /// ... a number typed in, with the name on the jangad.
  final String? phone;
  final String? newCustomerName;

  final int? pickupAddressId;
  final String? manualPickupAddress;
  final List<ServiceRequest> services;
  final String? note;

  Map<String, dynamic> toWire() => {
        'customer': partnerId != null
            ? {'partner_id': partnerId}
            : {
                'phone': phone,
                if (newCustomerName != null && newCustomerName!.trim().isNotEmpty)
                  'name': newCustomerName!.trim(),
              },
        if (pickupAddressId != null) 'pickup_address_id': pickupAddressId,
        if (pickupAddressId == null) 'manual_pickup_address': manualPickupAddress,
        'services': [for (final s in services) s.toWire()],
        if (note != null && note!.trim().isNotEmpty) 'note': note!.trim(),
      };
}

/// The answer to `POST /jangads`.
class OnBehalfResult {
  const OnBehalfResult({required this.pickingId, required this.reference, this.pickup});

  final int pickingId;
  final String reference;
  final Map<String, dynamic>? pickup;

  static OnBehalfResult? from(Map<String, dynamic> j) {
    final id = (j['picking_id'] as num?)?.toInt();
    if (id == null) return null;
    final pickup = j['pickup'];
    return OnBehalfResult(
      pickingId: id,
      reference: '${j['reference'] ?? ''}',
      pickup: pickup is Map ? Map<String, dynamic>.from(pickup) : null,
    );
  }
}

// ---------------------------------------------------------- productivity

/// `POST /jobwork/{id}/timesheets` without the envelope.
class TimeLogRequest {
  const TimeLogRequest({
    required this.jobTypeId,
    required this.hours,
    this.description,
    this.date,
  });

  final int jobTypeId;
  final double hours;
  final String? description;
  final DateTime? date;

  Map<String, dynamic> toWire() => {
        'job_type_id': jobTypeId,
        'hours': hours,
        if (description != null && description!.trim().isNotEmpty)
          'description': description!.trim(),
        if (date != null) 'date': isoDate(date!),
      };

  static String isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.date,
    required this.hours,
    this.picking,
    this.jobType,
    this.description,
    this.running = false,
    this.onThisPhone = false,
  });

  final int id;
  final DateTime? date;
  final Ref? picking;
  final Ref? jobType;
  final double hours;
  final String? description;
  final bool running;

  /// A manual entry still in the outbox.
  final bool onThisPhone;

  factory TimeEntry.fromJson(Map<String, dynamic> j) => TimeEntry(
        id: (j['id'] as num?)?.toInt() ?? 0,
        date: DateTime.tryParse('${j['date'] ?? ''}'),
        picking: Ref.from(j['picking']),
        jobType: Ref.from(j['job_type']),
        hours: (j['hours'] as num?)?.toDouble() ?? 0,
        description: j['description'] as String?,
        running: j['running'] == true,
      );
}

class DayHours {
  const DayHours(this.date, this.hours);
  final DateTime date;
  final double hours;
}

class JobTypeHours {
  const JobTypeHours(this.jobType, this.hours);
  final Ref? jobType;
  final double hours;
}

/// `GET /me/productivity?date_from&date_to`.
class Productivity {
  const Productivity({
    required this.totalHours,
    this.dateFrom,
    this.dateTo,
    this.byDay = const [],
    this.byJobType = const [],
    this.entries = const [],
  });

  final DateTime? dateFrom;
  final DateTime? dateTo;
  final double totalHours;
  final List<DayHours> byDay;
  final List<JobTypeHours> byJobType;
  final List<TimeEntry> entries;

  factory Productivity.fromJson(Map<String, dynamic> j) => Productivity(
        dateFrom: DateTime.tryParse('${j['date_from'] ?? ''}'),
        dateTo: DateTime.tryParse('${j['date_to'] ?? ''}'),
        totalHours: (j['total_hours'] as num?)?.toDouble() ?? 0,
        byDay: [
          for (final m in ((j['by_day'] as List?) ?? const []).whereType<Map>())
            if (DateTime.tryParse('${m['date']}') != null)
              DayHours(DateTime.parse('${m['date']}'), (m['hours'] as num?)?.toDouble() ?? 0),
        ],
        byJobType: [
          for (final m in ((j['by_job_type'] as List?) ?? const []).whereType<Map>())
            JobTypeHours(Ref.from(m['job_type']), (m['hours'] as num?)?.toDouble() ?? 0),
        ],
        entries: [
          for (final m in ((j['entries'] as List?) ?? const []).whereType<Map>())
            TimeEntry.fromJson(Map<String, dynamic>.from(m)),
        ],
      );
}

// ---------------------------------------------------------------- notices

/// One row of `GET /notices`.
class NoticeInfo {
  const NoticeInfo({
    required this.id,
    required this.kind,
    required this.title,
    this.body,
    this.pickingId,
    this.scope,
    this.createdAt,
    this.read = false,
  });

  final int id;

  /// `pickup_new`, `office_validate`, `jobwork_ready`, `department_transfer`,
  /// `delivery_ready`.
  final String kind;
  final String title;
  final String? body;
  final int? pickingId;

  /// The worklist to open when it is tapped.
  final String? scope;
  final DateTime? createdAt;
  final bool read;

  NoticeInfo asRead() => NoticeInfo(
        id: id,
        kind: kind,
        title: title,
        body: body,
        pickingId: pickingId,
        scope: scope,
        createdAt: createdAt,
        read: true,
      );

  factory NoticeInfo.fromJson(Map<String, dynamic> j) => NoticeInfo(
        id: (j['id'] as num?)?.toInt() ?? 0,
        kind: '${j['kind'] ?? ''}',
        title: '${j['title'] ?? ''}',
        body: j['body'] as String?,
        pickingId: (j['picking_id'] as num?)?.toInt(),
        scope: j['scope'] as String?,
        createdAt: OdooTime.parse(j['created_at']),
        read: j['read'] == true,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'title': title,
        'body': body,
        'picking_id': pickingId,
        'scope': scope,
        'created_at': createdAt?.toUtc().toIso8601String(),
        'read': read,
      };
}

/// `GET /notices?after=<id>&limit=`.
class NoticeList {
  const NoticeList({
    required this.notices,
    required this.lastId,
    required this.unread,
    this.hasMore = false,
  });

  /// Newest first.
  final List<NoticeInfo> notices;
  final int lastId;
  final int unread;
  final bool hasMore;

  factory NoticeList.fromJson(Map<String, dynamic> j) {
    final notices = [
      for (final m in ((j['notices'] as List?) ?? const []).whereType<Map>())
        NoticeInfo.fromJson(Map<String, dynamic>.from(m)),
    ];
    final maxId = notices.fold<int>(0, (a, n) => n.id > a ? n.id : a);
    return NoticeList(
      notices: notices,
      lastId: (j['last_id'] as num?)?.toInt() ?? maxId,
      unread: (j['unread'] as num?)?.toInt() ?? notices.where((n) => !n.read).length,
      hasMore: j['has_more'] == true,
    );
  }
}

// ----------------------------------------------------------------- office

/// Scope `office`: a collected jangad awaiting validation. The pickup document
/// plus the item table being built, the requested services, and where the
/// jangad came from.
class OfficeDoc {
  const OfficeDoc({
    required this.id,
    required this.rev,
    required this.name,
    required this.jangadPages,
    this.customer,
    this.contactPhone,
    this.pickupAddress,
    this.createdAt,
    this.collectedAt,
    this.collectedBy,
    this.services = const [],
    this.items = const [],
    this.jangadSource,
    this.postedBy,
  });

  final int id;
  final int rev;
  final String name;
  final int jangadPages;
  final Ref? customer;
  final String? contactPhone;
  final String? pickupAddress;
  final DateTime? createdAt;
  final DateTime? collectedAt;
  final Ref? collectedBy;
  final List<ServiceLine> services;
  final List<ItemLine> items;

  /// `customer_app` / `customer_web` / `on_behalf` / `office`.
  final String? jangadSource;
  final Ref? postedBy;

  String get customerLabel => customer?.name ?? 'Not yet on the office records';

  /// The chip on the list: who started this receipt.
  String get sourceLabel => switch (jangadSource) {
        'customer_app' => 'Customer app',
        'customer_web' => 'Website jangad',
        'on_behalf' => postedBy == null ? 'Posted for the customer' : 'Posted by ${postedBy!.name.split(' ').first}',
        'office' => 'Entered at the office',
        _ => 'Jangad',
      };

  double get requestedPcs =>
      services.where((s) => s.unit != 'ct').fold(0, (a, s) => a + s.quantity);

  factory OfficeDoc.fromJson(Map<String, dynamic> j) => OfficeDoc(
        id: (j['id'] as num).toInt(),
        rev: (j['rev'] as num?)?.toInt() ?? 0,
        name: '${j['name'] ?? ''}',
        jangadPages: (j['jangad_pages'] as num?)?.toInt() ?? 0,
        customer: Ref.from(j['customer']),
        contactPhone: j['contact_phone'] as String?,
        pickupAddress: j['pickup_address'] as String?,
        createdAt: OdooTime.parse(j['created_at']),
        collectedAt: OdooTime.parse(j['collected_at']),
        collectedBy: Ref.from(j['collected_by']),
        services: ServiceLine.listFrom(j['services']),
        items: ItemLine.listFrom(j['items']),
        jangadSource: j['jangad_source'] as String?,
        postedBy: Ref.from(j['posted_by']),
      );
}

/// One row of the office's editable item table (`OfficeLineInput`).
class OfficeLine {
  const OfficeLine({
    this.moveId,
    this.size = '',
    this.pcs = 0,
    this.carats = 0,
    this.jobTypeId,
    this.jobTypeName,
    this.remarks,
    this.requestId,
  });

  final int? moveId;
  final String size;
  final double pcs;
  final double carats;
  final int? jobTypeId;

  /// For drawing; not sent.
  final String? jobTypeName;
  final String? remarks;
  final int? requestId;

  bool get hasService => jobTypeId != null;
  bool get hasPieces => pcs > 0;

  OfficeLine copyWith({
    String? size,
    double? pcs,
    double? carats,
    int? jobTypeId,
    String? jobTypeName,
    String? remarks,
  }) =>
      OfficeLine(
        moveId: moveId,
        size: size ?? this.size,
        pcs: pcs ?? this.pcs,
        carats: carats ?? this.carats,
        jobTypeId: jobTypeId ?? this.jobTypeId,
        jobTypeName: jobTypeName ?? this.jobTypeName,
        remarks: remarks ?? this.remarks,
        requestId: requestId,
      );

  factory OfficeLine.fromItem(ItemLine line) => OfficeLine(
        moveId: line.moveId,
        size: line.size,
        pcs: line.pcs ?? 0,
        carats: line.carats ?? 0,
        jobTypeId: line.jobType?.id,
        jobTypeName: line.jobType?.name,
        remarks: line.remarks,
      );

  /// The rule the server applies in `_sudi_add_lines_from_requests`, used when
  /// the office adds entries with no signal: the quantity lands in pieces, or
  /// in carats when the service is billed by the carat.
  factory OfficeLine.fromRequest(ServiceLine request) => OfficeLine(
        pcs: request.unit == 'ct' ? 0 : request.quantity,
        carats: request.unit == 'ct' ? request.quantity : 0,
        jobTypeId: request.jobType?.id,
        jobTypeName: request.jobType?.name,
        remarks: request.remarks,
        requestId: request.id,
      );

  Map<String, dynamic> toWire() => {
        if (moveId != null) 'move_id': moveId,
        'size': size.trim().isEmpty ? null : size.trim(),
        'pcs': pcs,
        'carats': carats,
        'job_type_id': jobTypeId,
        'remarks': (remarks == null || remarks!.trim().isEmpty) ? null : remarks!.trim(),
        if (requestId != null) 'request_id': requestId,
      };

  Map<String, dynamic> toDraft() => {...toWire(), 'job_type_name': jobTypeName};

  factory OfficeLine.fromDraft(Map<String, dynamic> j) => OfficeLine(
        moveId: (j['move_id'] as num?)?.toInt(),
        size: '${j['size'] ?? ''}',
        pcs: (j['pcs'] as num?)?.toDouble() ?? 0,
        carats: (j['carats'] as num?)?.toDouble() ?? 0,
        jobTypeId: (j['job_type_id'] as num?)?.toInt(),
        jobTypeName: j['job_type_name'] as String?,
        remarks: j['remarks'] as String?,
        requestId: (j['request_id'] as num?)?.toInt(),
      );
}

/// The answer to `POST /receipts/{id}/ready`.
class OfficeReadyResult {
  const OfficeReadyResult({required this.code, required this.state, required this.reference});

  final String code;
  final String state;
  final String reference;

  factory OfficeReadyResult.fromJson(Map<String, dynamic> j) => OfficeReadyResult(
        code: '${j['code'] ?? 'OK'}',
        state: '${j['state'] ?? ''}',
        reference: '${j['reference'] ?? ''}',
      );
}
