import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/docs.dart';
import 'api/api_client.dart';
import 'api/api_error.dart';
import 'cache/response_cache.dart';
import 'db/records_dao.dart';

/// Every v2 path, in one place (plan section 5). Relative to the flavor's base
/// path: `/api/field/v1` or `/api/customer/v1`.
class V2Paths {
  const V2Paths._();

  // Shared, no auth.
  static const time = '/time';

  // Shared, signed in.
  static const me = '/auth/me';

  // Field.
  static const jobTypes = '/catalog/job-types';
  static const customers = '/customers';
  static const onBehalfJangad = '/jangads';
  static String timesheets(int pickingId) => '/jobwork/$pickingId/timesheets';
  static const productivity = '/me/productivity';
  static const notices = '/notices';
  static const noticesRead = '/notices/read';
  static String officeLines(int pickingId) => '/receipts/$pickingId/lines';
  static String officeFromRequests(int pickingId) => '/receipts/$pickingId/lines/from-requests';
  static String officeReady(int pickingId) => '/receipts/$pickingId/ready';
  static String jangadPage(int pickingId, int page) => '/pickups/$pickingId/jangad/$page';

  // Customer.
  static const services = '/services';
  static const addresses = '/addresses';
  static const gst = '/gst';
  static const gstSkip = '/gst/skip';
}

/// The reads (and the two online-only office writes) behind the v2 screens.
///
/// Every GET goes through [ResponseCache]: the server's answer is saved, and
/// each `saved*` method hands back the last one so a screen opens at once --
/// online or not -- and swaps in the fresh answer when it lands.
class V2Repository {
  V2Repository(this._api, this._cache, this._pages, this._records);

  final ApiClient _api;
  final ResponseCache _cache;
  final PageCache _pages;
  final RecordsDao _records;

  // ------------------------------------------------------------ generic

  /// GET, save the answer, return it. With [conditional], the last answer's
  /// ETag rides along and a 304 hands the saved copy back.
  Future<Object?> _get(String path, {Map<String, Object?>? query, bool conditional = false}) async {
    final saved = conditional ? await _cache.get(path, query: query) : null;
    final etag = conditional ? await _cache.etag(path, query: query) : null;
    final response = await _api.get<dynamic>(
      path,
      query: query?.map((k, v) => MapEntry(k, v)),
      headers: etag == null ? null : {'If-None-Match': etag},
    );
    if (response.statusCode == 304 && saved != null) return saved.data;
    await _cache.put(path, response.data, query: query, etag: _etagOf(response));
    return response.data;
  }

  Future<T?> _saved<T>(String path, T Function(Object? data) parse,
      {Map<String, Object?>? query}) async {
    try {
      final hit = await _cache.get(path, query: query);
      return hit == null ? null : parse(hit.data);
    } catch (_) {
      // A copy written by an older app: read the server's instead.
      return null;
    }
  }

  static String? _etagOf(Response<dynamic> response) {
    final values = response.headers.map['etag'] ?? response.headers.map['ETag'];
    return (values == null || values.isEmpty) ? null : values.first;
  }

  Future<DateTime?> savedAt(String path, {Map<String, Object?>? query}) async =>
      (await _cache.get(path, query: query))?.at;

  // ------------------------------------------------------------ catalogue

  Future<List<JobTypeInfo>> jobTypes() async =>
      JobTypeInfo.listFrom(await _get(V2Paths.jobTypes, conditional: true));

  Future<List<JobTypeInfo>?> savedJobTypes() => _saved(V2Paths.jobTypes, JobTypeInfo.listFrom);

  /// The directory for posting on a customer's behalf.
  Future<List<CustomerEntry>> customers() async =>
      CustomerEntry.listFrom(await _get(V2Paths.customers, conditional: true));

  Future<List<CustomerEntry>?> savedCustomers() =>
      _saved(V2Paths.customers, CustomerEntry.listFrom);

  // -------------------------------------------------------- productivity

  static Map<String, Object?> rangeQuery(DateTime from, DateTime to) => {
        'date_from': TimeLogRequest.isoDate(from),
        'date_to': TimeLogRequest.isoDate(to),
      };

  Future<Productivity> productivity(DateTime from, DateTime to) async {
    final data = await _get(V2Paths.productivity, query: rangeQuery(from, to));
    return Productivity.fromJson(Map<String, dynamic>.from((data as Map?) ?? const {}));
  }

  Future<Productivity?> savedProductivity(DateTime from, DateTime to) => _saved(
        V2Paths.productivity,
        (d) => Productivity.fromJson(Map<String, dynamic>.from(d as Map)),
        query: rangeQuery(from, to),
      );

  // ------------------------------------------------------------- notices

  /// Not saved here: the notices controller keeps the merged feed itself.
  Future<NoticeList> notices({int? after, int limit = 50}) async {
    final response = await _api.get<Map<String, dynamic>>(
      V2Paths.notices,
      query: {'after': ?after, 'limit': limit},
    );
    return NoticeList.fromJson(response.data ?? const {});
  }

  // -------------------------------------------------------------- office

  /// Replace the item table. **Needs a signal**: the draft stays on the phone
  /// until this succeeds.
  Future<OfficeDoc> saveOfficeLines(int pickingId, List<OfficeLine> lines) async {
    final response = await _api.put<Map<String, dynamic>>(
      V2Paths.officeLines(pickingId),
      body: {'lines': [for (final l in lines) l.toWire()]},
    );
    return _keepOfficeDoc(response.data);
  }

  /// One tap: entries from the requested-services table.
  Future<OfficeDoc> officeLinesFromRequests(int pickingId) async {
    final response = await _api.post<Map<String, dynamic>>(
      V2Paths.officeFromRequests(pickingId),
      body: const {},
    );
    return _keepOfficeDoc(response.data);
  }

  /// Mark READY for job work. Online only, like Finish: it runs the stock
  /// confirmation, whose outcome the phone cannot predict.
  Future<OfficeReadyResult> markReady(int pickingId, {required String idemKey}) async {
    final response = await _api.post<Map<String, dynamic>>(
      V2Paths.officeReady(pickingId),
      body: const {},
      idempotencyKey: idemKey,
    );
    // It has left the office's list; the next pull says so too.
    await _records.removeGone('office', [pickingId]);
    return OfficeReadyResult.fromJson(response.data ?? const {});
  }

  /// The answer is the office document -- bare, or as `record` like the
  /// intents. Either way the local row is replaced at once.
  Future<OfficeDoc> _keepOfficeDoc(Map<String, dynamic>? data) async {
    final raw = data ?? const <String, dynamic>{};
    final doc = raw['record'] is Map ? Map<String, dynamic>.from(raw['record'] as Map) : raw;
    if (doc['id'] == null) {
      throw ApiError(
        code: ApiError.server,
        message: 'The office did not send the receipt back.',
        retryable: true,
      );
    }
    await _records.upsertOffice([doc]);
    return OfficeDoc.fromJson(doc);
  }

  // --------------------------------------------------------- jangad pages

  Future<Uint8List?> savedPage(int pickingId, int page) => _pages.get(pickingId, page);

  /// A page of a receipt's jangad, kept encrypted on the phone once read.
  Future<Uint8List?> jangadPage(int pickingId, int page) async {
    final response = await _api.get<List<int>>(
      V2Paths.jangadPage(pickingId, page),
      responseType: ResponseType.bytes,
    );
    final data = response.data;
    if (data == null) return null;
    final bytes = Uint8List.fromList(data);
    await _pages.put(pickingId, page, bytes);
    return bytes;
  }

  // ------------------------------------------------------------ customer

  Future<List<ServiceInfo>> services() async =>
      ServiceInfo.listFrom(await _get(V2Paths.services, conditional: true));

  Future<List<ServiceInfo>?> savedServices() => _saved(V2Paths.services, ServiceInfo.listFrom);

  Future<List<AddressSuggestion>> addresses() async {
    final data = await _get(V2Paths.addresses);
    return _addresses(data);
  }

  Future<List<AddressSuggestion>?> savedAddresses() => _saved(V2Paths.addresses, _addresses);

  static List<AddressSuggestion> _addresses(Object? data) => (data as List? ?? const [])
      .whereType<Map>()
      .map((m) => AddressSuggestion.fromJson(Map<String, dynamic>.from(m)))
      .toList();
}
