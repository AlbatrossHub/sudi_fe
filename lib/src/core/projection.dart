import '../models/docs.dart';
import 'outbox/outbox.dart';

/// The world as the operator left it: the server's documents with the phone's
/// queued intents played on top. Nothing here writes; the outbox stays the only
/// writer of intent and the cache stays the server's copy.
///
/// A projected state always travels with a queued chip -- "Collect queued",
/// "On this phone" -- because an operator who sees a bare tick assumes the
/// office has it.
class PickupView {
  PickupView.server(PickupDoc this.doc, this.pending) : posted = null;
  PickupView.onPhone(OutboxItem this.posted, this.pending) : doc = null;

  /// The receipt the server sent, or null for a jangad posted on this phone
  /// that has not reached the office yet.
  final PickupDoc? doc;

  /// The on-behalf jangad behind an [onThisPhone] card.
  final OutboxItem? posted;

  /// Open intents on this receipt (for [posted]: the ones chained behind it).
  final List<OutboxItem> pending;

  bool get onThisPhone => posted != null;

  Iterable<OutboxItem> get _live => pending.where((p) => p.state != OutboxState.needsAttention);

  OutboxItem? get queuedConfirm =>
      _live.where((p) => p.kind == IntentKind.confirmPickup).lastOrNull;
  OutboxItem? get queuedCancel =>
      _live.where((p) => p.kind == IntentKind.cancelPickup).lastOrNull;

  List<OutboxItem> get refused =>
      [for (final p in pending) if (p.state == OutboxState.needsAttention) p];

  /// A queued confirm moves the card to "Collected" straight away.
  bool get collected => (doc?.isCollected ?? false) || queuedConfirm != null;

  DateTime? get collectedAt => doc?.collectedAt ?? queuedConfirm?.occurredAt.toLocal();

  /// For sorting and the "posted at" line.
  DateTime? get postedAt => posted?.occurredAt.toLocal();

  String get customerName =>
      doc?.customerLabel ?? '${posted?.meta['customer_name'] ?? 'Customer'}';

  int get pages => doc?.jangadPages ?? ((posted?.meta['pages'] as num?)?.toInt() ?? 0);

  List<ServiceRequest> get postedServices =>
      ServiceRequest.listFromDraft(posted?.meta['services']);

  /// Services as one-line chips: from the receipt, or from what was posted.
  List<String> get serviceChips => doc != null
      ? [for (final s in doc!.services) '${s.name} · ${s.quantityLabel}']
      : [for (final s in postedServices) '${s.name} · ${s.quantityLabel}'];

  int get serviceCount => doc?.services.length ?? postedServices.length;

  static List<PickupView> build(
    List<PickupDoc> docs,
    Map<int, List<OutboxItem>> pendingByRecord,
    List<OutboxItem> open,
  ) {
    final views = [for (final d in docs) PickupView.server(d, pendingByRecord[d.id] ?? const [])];
    for (final item in open) {
      if (item.kind != IntentKind.submitOnBehalf || item.state == OutboxState.done) continue;
      views.insert(
        0,
        PickupView.onPhone(item, [
          for (final o in open)
            if (o.dependsOn == item.localId && o.recordId == null) o,
          // Its own refusal shows on the card too.
          if (item.state == OutboxState.needsAttention) item,
        ]),
      );
    }
    return views;
  }
}

class Projection {
  const Projection._();

  /// A queued start shows running from the moment it was tapped; a queued stop
  /// shows stopped.
  static TimerInfo timer(JobWorkDoc doc, List<OutboxItem> pending) {
    final last = pending
        .where((p) => p.kind == IntentKind.timer && p.state != OutboxState.needsAttention)
        .lastOrNull;
    if (last == null) return doc.timer;
    if (last.body['action'] == 'start') {
      return doc.timer.running
          ? doc.timer
          : TimerInfo(running: true, startedAt: last.occurredAt.toLocal());
    }
    return const TimerInfo(running: false);
  }

  static bool timerQueued(List<OutboxItem> pending) =>
      pending.any((p) => p.kind == IntentKind.timer && p.isWaiting);

  /// A queued move shows the department it is moving to.
  static Ref? department(JobWorkDoc doc, List<OutboxItem> pending) {
    final last = pending
        .where((p) => p.kind == IntentKind.department && p.state != OutboxState.needsAttention)
        .lastOrNull;
    if (last == null) return doc.currentDepartment;
    final id = (last.body['department_id'] as num?)?.toInt();
    final name = last.meta['department_name'] as String?;
    return id == null ? doc.currentDepartment : Ref(id: id, name: name ?? 'New department');
  }

  /// Taken, handed back or delivered on this phone: the parcel shows where the
  /// operator put it.
  static String deliveryStage(DeliveryDoc doc, List<OutboxItem> pending) {
    final last = pending
        .where((p) =>
            p.state != OutboxState.needsAttention &&
            (p.kind == IntentKind.takeDeliveries ||
                p.kind == IntentKind.releaseDelivery ||
                p.kind == IntentKind.markDelivered))
        .lastOrNull;
    return switch (last?.kind) {
      IntentKind.takeDeliveries => 'out',
      IntentKind.releaseDelivery => 'awaiting',
      IntentKind.markDelivered => 'delivered',
      _ => doc.stage,
    };
  }

  /// Manual entries still on the phone, for My work.
  static List<TimeEntry> queuedTimeLogs(List<OutboxItem> open) => [
        for (final item in open)
          if (item.kind == IntentKind.logTime && item.state != OutboxState.needsAttention)
            TimeEntry(
              id: -item.seq,
              date: DateTime.tryParse('${item.body['date'] ?? ''}') ?? item.occurredAt.toLocal(),
              picking: item.recordId == null
                  ? null
                  : Ref(id: item.recordId!, name: item.recordLabel ?? ''),
              jobType: (item.body['job_type_id'] as num?) == null
                  ? null
                  : Ref(
                      id: (item.body['job_type_id'] as num).toInt(),
                      name: '${item.meta['job_type_name'] ?? ''}',
                    ),
              hours: (item.body['hours'] as num?)?.toDouble() ?? 0,
              description: item.body['description'] as String?,
              onThisPhone: true,
            ),
      ];
}
