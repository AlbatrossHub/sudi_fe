import 'dart:convert';

/// Every write the app can make. `finishJobWork` is deliberately absent: it
/// runs Odoo's stock validation chain, whose outcome cannot be predicted on the
/// device, so queueing it would mean showing a success that may not happen.
enum IntentKind {
  confirmPickup('confirm_pickup', 'Confirm pickup'),
  cancelPickup('cancel_pickup', 'Cannot collect'),
  takeDeliveries('take_deliveries', 'Take for delivery'),
  releaseDelivery('release_delivery', 'Hand parcel back'),
  markDelivered('mark_delivered', 'Mark delivered'),
  timer('timer', 'Timer'),
  department('department', 'Move department'),
  submitJangad('submit_jangad', 'Send jangad');

  const IntentKind(this.wire, this.label);
  final String wire;
  final String label;

  static IntentKind parse(String wire) =>
      IntentKind.values.firstWhere((k) => k.wire == wire, orElse: () => IntentKind.timer);
}

enum OutboxState {
  /// Waiting for a flush.
  pending,

  /// In flight right now.
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
    this.recordLabel,
    this.state = OutboxState.pending,
    this.attempts = 0,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastErrorMessage,
  });

  final String localId;
  final IntentKind kind;

  /// Null for the customer's jangad, which creates a record rather than acting
  /// on one. The flush chain then keys on [localId].
  final int? recordId;
  final String? recordLabel;

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

  /// Deliveries and pickups chain per record; a jangad chains on itself.
  String get chainKey => recordId != null ? '${kind.wire.split('_').first}:$recordId' : localId;

  bool get isOpen => state != OutboxState.done;
  bool get isWaiting => state == OutboxState.pending || state == OutboxState.retrying;

  OutboxItem copyWith({
    OutboxState? state,
    int? attempts,
    DateTime? nextAttemptAt,
    String? lastErrorCode,
    String? lastErrorMessage,
    Map<String, dynamic>? body,
  }) =>
      OutboxItem(
        localId: localId,
        kind: kind,
        recordId: recordId,
        recordLabel: recordLabel,
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
        'record_label': recordLabel,
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
    return OutboxItem(
      localId: row['local_id'] as String,
      kind: IntentKind.parse(row['kind'] as String),
      recordId: (row['record_id'] as num?)?.toInt(),
      recordLabel: row['record_label'] as String?,
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
