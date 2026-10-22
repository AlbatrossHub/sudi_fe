import 'dart:convert';

/// Every write the app can make. `finishJobWork` and the office's Mark READY
/// are deliberately absent: they run stock validation whose outcome cannot be
/// predicted on the device, so queueing them would mean showing a success that
/// may not happen.
enum IntentKind {
  confirmPickup('confirm_pickup', 'Confirm pickup'),
  cancelPickup('cancel_pickup', 'Cannot collect'),
  takeDeliveries('take_deliveries', 'Take for delivery'),
  releaseDelivery('release_delivery', 'Hand parcel back'),
  markDelivered('mark_delivered', 'Mark delivered'),
  timer('timer', 'Timer'),
  department('department', 'Move department'),
  submitJangad('submit_jangad', 'Send jangad'),
  submitOnBehalf('submit_on_behalf', 'Jangad for a customer'),
  logTime('log_time', 'Log time'),
  noticesRead('notices_read', 'Notifications read');

  const IntentKind(this.wire, this.label);
  final String wire;
  final String label;

  static IntentKind parse(String wire) =>
      IntentKind.values.firstWhere((k) => k.wire == wire, orElse: () => IntentKind.timer);
}

enum OutboxState {
  /// Waiting for a flush.
  pending,

  /// In flight right now. A row still in this state at boot was cut off by a
  /// killed app and goes back to [pending] (`recoverInterrupted`).
  sending,

  /// Retryable failure; `nextAttemptAt` holds the backoff.
  retrying,

  /// Permanently refused, or expired. Never discarded silently — it becomes a
  /// visible item the operator can read and act on.
  needsAttention,

  /// Acknowledged, including `ALREADY_DONE`.
  done;

  static OutboxState parse(String raw) =>
      OutboxState.values.firstWhere((s) => s.name == raw, orElse: () => OutboxState.pending);
}

class OutboxItem {
  OutboxItem({
    required this.localId,
    required this.kind,
    required this.idemKey,
    required this.occurredAt,
    required this.createdAt,
    required this.body,
    this.recordId,
    this.recordIds = const [],
    this.recordLabel,
    this.chain,
    this.dependsOn,
    this.meta = const {},
    this.seq = 0,
    this.state = OutboxState.pending,
    this.attempts = 0,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastErrorMessage,
  });

  final String localId;
  final IntentKind kind;

  /// The record this acts on. Null for a jangad, which creates a record rather
  /// than acting on one, and for a confirm still waiting on the jangad it was
  /// chained behind (the id is filled in when that jangad lands).
  final int? recordId;

  /// Every record a multi-record intent touches (`take`). Each of them joins
  /// this intent's chain, and each shows it queued.
  final List<int> recordIds;
  final String? recordLabel;

  /// An explicit chain: an on-behalf jangad and the confirm taken straight
  /// after it travel together, in order, before either has a record id.
  final String? chain;

  /// The local id of the intent this one waits for, and whose answer carries
  /// the record id it acts on.
  final String? dependsOn;

  /// What the screens draw for an intent with no record yet. Never sent.
  final Map<String, dynamic> meta;

  /// Capture order, independent of any clock.
  final int seq;

  /// Generated **at capture time** and reused on every retry, forever. This is
  /// what makes "the response was lost on a train" safe: the server replays its
  /// first answer instead of acting twice. Generating a fresh key on retry
  /// defeats the whole mechanism.
  final String idemKey;

  final DateTime occurredAt;
  final DateTime createdAt;
  final Map<String, dynamic> body;
  final OutboxState state;
  final int attempts;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;

  /// Every record this intent touches.
  Set<int> get touchedIds => {?recordId, ...recordIds};

  /// The chains this intent belongs to. **One chain per record, whatever the
  /// verb**: a confirm and a cancel on pickup 42 are one queue, so they go in
  /// the order they were captured. A multi-record intent belongs to the chain
  /// of every record it names, which joins those chains together. An explicit
  /// [chain] wins; an intent with no record chains on itself.
  List<String> get chainKeys {
    if (chain != null) return [chain!];
    final ids = touchedIds.toList()..sort();
    if (ids.isEmpty) return [localId];
    return [for (final id in ids) 'rec:$id'];
  }

  String get chainKey => chainKeys.first;

  bool get isOpen => state != OutboxState.done;
  bool get isWaiting => state == OutboxState.pending || state == OutboxState.retrying;

  OutboxItem copyWith({
    OutboxState? state,
    int? attempts,
    DateTime? nextAttemptAt,
    String? lastErrorCode,
    String? lastErrorMessage,
    Map<String, dynamic>? body,
    Map<String, dynamic>? meta,
  }) =>
      OutboxItem(
        localId: localId,
        kind: kind,
        recordId: recordId,
        recordIds: recordIds,
        recordLabel: recordLabel,
        chain: chain,
        dependsOn: dependsOn,
        meta: meta ?? this.meta,
        seq: seq,
        idemKey: idemKey,
        occurredAt: occurredAt,
        createdAt: createdAt,
        body: body ?? this.body,
        state: state ?? this.state,
        attempts: attempts ?? this.attempts,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        lastErrorCode: lastErrorCode ?? this.lastErrorCode,
        lastErrorMessage: lastErrorMessage ?? this.lastErrorMessage,
      );

  Map<String, Object?> toRow() => {
        'local_id': localId,
        'kind': kind.wire,
        'record_id': recordId,
        'record_ids': jsonEncode(recordIds),
        'record_label': recordLabel,
        'chain': chain,
        'depends_on': dependsOn,
        'meta': jsonEncode(meta),
        'seq': seq,
        'idem_key': idemKey,
        'occurred_at': occurredAt.toIso8601String(),
        'created_at': createdAt.toIso8601String(),
        'body': jsonEncode(body),
        'state': state.name,
        'attempts': attempts,
        'next_attempt_at': nextAttemptAt?.toIso8601String(),
        'last_error': lastErrorCode == null
            ? null
            : jsonEncode({'code': lastErrorCode, 'message': lastErrorMessage}),
      };

  static OutboxItem fromRow(Map<String, Object?> row) {
    final error = row['last_error'] == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(row['last_error'] as String) as Map);
    List<int> ids() {
      final raw = row['record_ids'];
      if (raw is! String || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      return decoded is List ? [for (final v in decoded) if (v is num) v.toInt()] : const [];
    }

    Map<String, dynamic> meta() {
      final raw = row['meta'];
      if (raw is! String || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    }

    return OutboxItem(
      localId: row['local_id'] as String,
      kind: IntentKind.parse(row['kind'] as String),
      recordId: (row['record_id'] as num?)?.toInt(),
      recordIds: ids(),
      recordLabel: row['record_label'] as String?,
      chain: row['chain'] as String?,
      dependsOn: row['depends_on'] as String?,
      meta: meta(),
      seq: (row['seq'] as num?)?.toInt() ?? 0,
      idemKey: row['idem_key'] as String,
      occurredAt: DateTime.parse(row['occurred_at'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
      body: Map<String, dynamic>.from(jsonDecode(row['body'] as String) as Map),
      state: OutboxState.parse(row['state'] as String),
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      nextAttemptAt: row['next_attempt_at'] == null
          ? null
          : DateTime.tryParse(row['next_attempt_at'] as String),
      lastErrorCode: error['code'] as String?,
      lastErrorMessage: error['message'] as String?,
    );
  }
}

/// Groups intents into chains: two intents are in one chain when they share a
/// chain key, directly or through a multi-record intent that names both
/// records. Each chain comes back in capture order. Chains are independent of
/// each other and flush in parallel.
List<List<OutboxItem>> outboxChains(List<OutboxItem> items) {
  final parent = <String, String>{};
  String find(String k) {
    var root = parent.putIfAbsent(k, () => k);
    while (root != parent[root]) {
      root = parent[root]!;
    }
    // Path compression.
    var node = k;
    while (parent[node] != root) {
      final next = parent[node]!;
      parent[node] = root;
      node = next;
    }
    return root;
  }

  void union(String a, String b) {
    final ra = find(a);
    final rb = find(b);
    if (ra != rb) parent[ra] = rb;
  }

  for (final item in items) {
    final keys = item.chainKeys;
    for (final k in keys) {
      find(k);
    }
    for (var i = 1; i < keys.length; i++) {
      union(keys.first, keys[i]);
    }
  }
  final groups = <String, List<OutboxItem>>{};
  for (final item in items) {
    (groups[find(item.chainKey)] ??= []).add(item);
  }
  for (final group in groups.values) {
    group.sort(compareCaptureOrder);
  }
  return groups.values.toList();
}

int compareCaptureOrder(OutboxItem a, OutboxItem b) {
  final bySeq = a.seq.compareTo(b.seq);
  return bySeq != 0 ? bySeq : a.createdAt.compareTo(b.createdAt);
}

enum UploadState { staged, uploading, uploaded, failed }

class UploadItem {
  UploadItem({
    required this.localId,
    required this.filePath,
    required this.bytes,
    required this.createdAt,
    this.sha256,
    this.reference,
    this.state = UploadState.staged,
    this.pageIndex = 0,
    this.intentLocalId,
    this.lastError,
  });

  final String localId;
  final String filePath;
  final int bytes;
  final DateTime createdAt;
  final String? sha256;

  /// The server's handle, quoted by the intent in page order.
  final String? reference;
  final UploadState state;
  final int pageIndex;
  final String? intentLocalId;
  final String? lastError;

  UploadItem copyWith({
    String? sha256,
    String? reference,
    UploadState? state,
    String? intentLocalId,
    String? lastError,
  }) =>
      UploadItem(
        localId: localId,
        filePath: filePath,
        bytes: bytes,
        createdAt: createdAt,
        sha256: sha256 ?? this.sha256,
        reference: reference ?? this.reference,
        state: state ?? this.state,
        pageIndex: pageIndex,
        intentLocalId: intentLocalId ?? this.intentLocalId,
        lastError: lastError ?? this.lastError,
      );

  Map<String, Object?> toRow() => {
        'local_id': localId,
        'file_path': filePath,
        'sha256': sha256,
        'bytes': bytes,
        'reference': reference,
        'state': state.name,
        'page_index': pageIndex,
        'intent_local_id': intentLocalId,
        'created_at': createdAt.toIso8601String(),
        'last_error': lastError,
      };

  static UploadItem fromRow(Map<String, Object?> row) => UploadItem(
        localId: row['local_id'] as String,
        filePath: row['file_path'] as String,
        bytes: (row['bytes'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.parse(row['created_at'] as String),
        sha256: row['sha256'] as String?,
        reference: row['reference'] as String?,
        state: UploadState.values
            .firstWhere((s) => s.name == row['state'], orElse: () => UploadState.staged),
        pageIndex: (row['page_index'] as num?)?.toInt() ?? 0,
        intentLocalId: row['intent_local_id'] as String?,
        lastError: row['last_error'] as String?,
      );
}
