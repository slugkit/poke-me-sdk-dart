// Delivery-receipt DTOs for the poke-me backend HTTP API.
//
// `delivery.accepted` means a push provider took the message. Nothing
// server-side can say more: APNs and Web Push have no receipts, and FCM's live
// in the publisher's own Firebase project. This device is the only party that
// knows what actually happened, so it reports.
//
// Field naming follows the wire format (snake_case in JSON, camelCase in Dart).

/// What the device observed about a notification it was sent.
///
/// Three **independent** observations, not a progression. A silent push is
/// [delivered] and never anything else; a push the OS coalesced or suppressed
/// may be [delivered] and never [shown]; a tap that relaunches the app can
/// produce [opened] with no [shown] before it. Report what actually happened
/// rather than inferring one state from another — the backend stores them
/// separately and a consumer reconciling them cannot undo a guess made here.
enum ReceiptState {
  /// The push arrived at the device and the SDK ran.
  delivered,

  /// The OS displayed it — a banner, or an entry in the notification centre.
  shown,

  /// The user acted on it.
  opened;

  String get wireValue => name;
}

/// One receipt: a notification, and what became of it.
class Receipt {
  Receipt({
    required this.notificationId,
    required this.state,
    DateTime? at,
  }) : at = at ?? DateTime.now();

  /// The `id` from the push envelope ([PushPayload.id]). Opaque — the SDK does
  /// not construct or interpret it, only echoes it back. The device half of the
  /// delivery comes from the device token, so it is never sent.
  final String notificationId;

  final ReceiptState state;

  /// When this device observed it. Sent as milliseconds since the epoch, the
  /// same unit the push envelope's `sent_at` uses.
  ///
  /// The backend stores it but does **not** trust it — an end-user's clock can
  /// be set to anything — and records its own arrival time alongside.
  final DateTime at;

  /// Identity for in-buffer deduplication. The backend is idempotent on the
  /// same pair, so reporting one twice is harmless; not buffering it twice is
  /// simply cheaper.
  String get key => '$notificationId/${state.wireValue}';

  Map<String, dynamic> toJson() => {
        'notification_id': notificationId,
        'state': state.wireValue,
        'at': at.millisecondsSinceEpoch,
      };
}

/// Response from `POST /api/v1/devices/me/receipts`.
class ReportReceiptsResponse {
  const ReportReceiptsResponse({
    required this.recorded,
    required this.ignored,
    required this.receiptsEnabled,
  });

  /// Receipts stored. Excludes ones already reported — the backend is
  /// idempotent per (notification, state), so a retried batch records zero and
  /// that is success, not failure.
  final int recorded;

  /// Receipts not stored: for a notification this device was never sent, for a
  /// kind that cannot be receipted, or because the publisher's plan does not
  /// include receipts.
  final int ignored;

  /// False only when the publisher's plan is what stopped every receipt in the
  /// batch. The SDK stops reporting for the rest of the process when it sees
  /// this: it is a business condition, not a transient one, and a whole fleet
  /// retrying it is the failure this flag exists to prevent.
  final bool receiptsEnabled;

  factory ReportReceiptsResponse.fromJson(Map<String, dynamic> json) =>
      ReportReceiptsResponse(
        recorded: (json['recorded'] as num?)?.toInt() ?? 0,
        ignored: (json['ignored'] as num?)?.toInt() ?? 0,
        // Absent means enabled: an older backend that does not know about the
        // flag is one where receipts work.
        receiptsEnabled: json['receipts_enabled'] as bool? ?? true,
      );
}
