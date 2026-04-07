import 'package:sqflite/sqflite.dart';

import '../models/channel.dart';
import '../models/message.dart';
import '../storage/channels_dao.dart';
import '../storage/database.dart';
import '../storage/messages_dao.dart';
import '../storage/sync_state_dao.dart';

/// Outcome of [MessageStore.receiveMessage].
enum MessageReceiveResult {
  /// The message was new and is now persisted.
  inserted,

  /// The message was a duplicate (already in the store, identified by id).
  duplicate,

  /// The message was dropped because the channel is unknown locally or not
  /// in the active state. Reconciliation with the backend may be needed
  /// (the SDK push handler decides — see design-docs/MESSAGES.md).
  dropped,
}

/// Result of [MessageStore.runMaintenance].
class MaintenanceResult {
  const MaintenanceResult({
    required this.messagesPruned,
    required this.tombstonesRemoved,
  });

  /// Number of messages deleted by the retention sweep.
  final int messagesPruned;

  /// Number of channel rows hard-deleted by the tombstone sweep.
  final int tombstonesRemoved;

  @override
  String toString() =>
      'MaintenanceResult(messagesPruned: $messagesPruned, tombstonesRemoved: $tombstonesRemoved)';
}

/// High-level local persistence facade for the standard poke receiver.
///
/// Wraps the [PokemeDatabase] and its DAOs with operations that enforce
/// the cross-DAO invariants from `design-docs/mobile/STORAGE.md`:
///
/// - Messages may only exist for channels in the active state.
///   [receiveMessage] is the only insertion path; messages for unknown
///   or inactive channels are silently dropped.
/// - Revocation/deletion atomically wipes messages **and** updates the
///   channel state in a single transaction.
///
/// Higher-level concerns (parsing wire payloads, calling reconciliation
/// endpoints, dispatching to the OS notification UI) live in the SDK
/// push handler that sits on top of this store.
class MessageStore {
  MessageStore._(this._db);

  final PokemeDatabase _db;

  /// How long an acknowledged tombstone lingers before the sweep removes
  /// the channel row. The user has this long to revisit the notice before
  /// the channel disappears entirely.
  static const tombstoneTtl = Duration(days: 1);

  /// Opens the store at [path]. See [PokemeDatabase.open] for parameter
  /// semantics.
  static Future<MessageStore> open({
    required String path,
    DatabaseFactory? databaseFactory,
  }) async {
    final db = await PokemeDatabase.open(
      path: path,
      databaseFactory: databaseFactory,
    );
    return MessageStore._(db);
  }

  /// Closes the underlying database. The store must not be used afterwards.
  Future<void> close() => _db.close();

  // ---------------------------------------------------------------------------
  // Subscriptions
  // ---------------------------------------------------------------------------

  /// Records a new channel subscription. Used after the device successfully
  /// exchanges a join key for a device token.
  Future<void> joinChannel(Channel channel) {
    return _db.channels.upsert(channel);
  }

  /// Lists channels currently subscribed to (state = active). Pass
  /// [includeTombstones] to also return channels in revoked/deleted state.
  Future<List<Channel>> listChannels({bool includeTombstones = false}) {
    if (includeTombstones) {
      return _db.channels.list();
    }
    return _db.channels.list(state: ChannelState.active);
  }

  /// Returns the channel with [slug], or `null` if it isn't tracked locally.
  Future<Channel?> getChannel(String slug) => _db.channels.findBySlug(slug);

  // ---------------------------------------------------------------------------
  // System event handlers
  // ---------------------------------------------------------------------------

  /// Handles a `channel_renamed` system event by updating the local channel
  /// name. No-op if the channel isn't tracked locally.
  Future<void> handleChannelRenamed(String slug, String newName) async {
    await _db.channels.rename(slug, newName);
  }

  /// Handles a `channel_slug_changed` system event by replacing the slug
  /// in place. Messages keep their relationship through SQLite's foreign
  /// key cascade.
  Future<void> handleChannelSlugChanged(String oldSlug, String newSlug) async {
    await _db.channels.changeSlug(oldSlug, newSlug);
  }

  /// Handles a `channel_deleted` system event. **Atomically wipes all
  /// messages for the channel and marks the channel as deleted** in a
  /// single transaction. The tombstone row remains so the user can be
  /// shown a "this channel is gone" notice.
  Future<void> handleChannelDeleted(String slug, {DateTime? at}) async {
    await _markInactiveAndPurge(
      slug,
      newState: ChannelState.deleted,
      at: at ?? DateTime.now(),
    );
  }

  /// Handles a `subscription_revoked` system event. Same effect as
  /// [handleChannelDeleted] but tagged distinctly for telemetry.
  Future<void> handleSubscriptionRevoked(String slug, {DateTime? at}) async {
    await _markInactiveAndPurge(
      slug,
      newState: ChannelState.revoked,
      at: at ?? DateTime.now(),
    );
  }

  Future<void> _markInactiveAndPurge(
    String slug, {
    required ChannelState newState,
    required DateTime at,
  }) async {
    await _db.raw.transaction((txn) async {
      final messages = MessagesDao(txn);
      final channels = ChannelsDao(txn);
      await messages.purgeChannel(slug);
      await channels.markInactive(
        slug,
        newState: newState,
        stateChangedAt: at,
      );
    });
  }

  // ---------------------------------------------------------------------------
  // Message ingestion
  // ---------------------------------------------------------------------------

  /// Persists a received user-facing alert.
  ///
  /// **Gating rules** (per `design-docs/mobile/STORAGE.md`):
  /// - If the channel is unknown locally, the message is dropped. The
  ///   higher-level push handler is expected to attempt reconciliation
  ///   via the backend history endpoint and call this method again after
  ///   updating the local channel state.
  /// - If the channel is in `revoked` or `deleted` state, the message is
  ///   dropped. Late-arriving pushes after a server-side revocation are
  ///   not allowed to leak content.
  /// - If the message id is already present, it's a duplicate (FCM/APNs
  ///   sometimes redeliver) and silently ignored.
  Future<MessageReceiveResult> receiveMessage(Message message) async {
    final channel = await _db.channels.findBySlug(message.channelSlug);
    if (channel == null || channel.state != ChannelState.active) {
      return MessageReceiveResult.dropped;
    }
    final inserted = await _db.messages.insert(message);
    return inserted
        ? MessageReceiveResult.inserted
        : MessageReceiveResult.duplicate;
  }

  // ---------------------------------------------------------------------------
  // Message queries
  // ---------------------------------------------------------------------------

  /// Returns messages in [channelSlug], newest first.
  Future<List<Message>> listMessages(
    String channelSlug, {
    int limit = 50,
    int offset = 0,
  }) {
    return _db.messages
        .listByChannel(channelSlug, limit: limit, offset: offset);
  }

  /// Cross-channel inbox: all messages, newest first.
  Future<List<Message>> listAllMessages({int limit = 50, int offset = 0}) {
    return _db.messages.listRecent(limit: limit, offset: offset);
  }

  /// Unread messages, newest first.
  Future<List<Message>> listUnread({int limit = 50}) {
    return _db.messages.listUnread(limit: limit);
  }

  /// Counts unread messages, optionally restricted to a single channel.
  Future<int> countUnread({String? channelSlug}) {
    return _db.messages.countUnread(channelSlug: channelSlug);
  }

  /// Returns the message with [id], or `null` if absent.
  Future<Message?> getMessage(String id) => _db.messages.findById(id);

  // ---------------------------------------------------------------------------
  // Read state
  // ---------------------------------------------------------------------------

  /// Marks a single message as read. No-op if already read.
  Future<void> markRead(String id, {DateTime? at}) async {
    await _db.messages.markRead(id, at: at ?? DateTime.now());
  }

  /// Marks all unread messages in a channel as read.
  Future<void> markChannelRead(String channelSlug, {DateTime? at}) async {
    await _db.messages.markChannelRead(channelSlug, at: at ?? DateTime.now());
  }

  // ---------------------------------------------------------------------------
  // Tombstone notices
  // ---------------------------------------------------------------------------

  /// Returns channels in a non-active state that haven't yet been
  /// acknowledged by the user. The UI displays "this channel was deleted"
  /// or "you were unsubscribed" notices for these.
  Future<List<Channel>> listPendingNotices() {
    return _db.channels.findPendingNotices();
  }

  /// Marks the deletion/revocation notice as seen by the user. Starts
  /// the [tombstoneTtl] clock until the channel row is hard-deleted.
  Future<void> acknowledgeNotice(String slug, {DateTime? at}) async {
    await _db.channels.acknowledge(slug, at: at ?? DateTime.now());
  }

  // ---------------------------------------------------------------------------
  // Maintenance
  // ---------------------------------------------------------------------------

  /// Runs both the message retention sweep and the tombstone sweep.
  /// Safe to call on app launch and periodically.
  Future<MaintenanceResult> runMaintenance({DateTime? now}) async {
    final at = now ?? DateTime.now();

    final defaultRetention =
        await _db.syncState.getInt(SyncStateKeys.defaultRetentionDays);
    final messagesPruned = await _db.messages.retentionSweep(
      now: at,
      defaultRetentionDays: defaultRetention,
    );

    final expired = await _db.channels.findExpiredTombstones(
      now: at,
      maxAge: tombstoneTtl,
    );
    var tombstonesRemoved = 0;
    for (final slug in expired) {
      tombstonesRemoved += await _db.channels.hardDelete(slug);
    }

    return MaintenanceResult(
      messagesPruned: messagesPruned,
      tombstonesRemoved: tombstonesRemoved,
    );
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  /// Returns the user-set global default retention in days.
  /// `null` or `0` means unlimited.
  Future<int?> getDefaultRetentionDays() {
    return _db.syncState.getInt(SyncStateKeys.defaultRetentionDays);
  }

  /// Sets the global default retention. Pass `null` to clear it (unlimited).
  /// Pass `0` for the same effect (also unlimited).
  Future<void> setDefaultRetentionDays(int? days) async {
    if (days == null) {
      await _db.syncState.remove(SyncStateKeys.defaultRetentionDays);
      return;
    }
    await _db.syncState.setInt(SyncStateKeys.defaultRetentionDays, days);
  }

  // ---------------------------------------------------------------------------
  // Reconciliation cursor
  // ---------------------------------------------------------------------------

  /// Records the id of the last successfully processed system event.
  /// Used as the `since` cursor for the reconciliation endpoint when the
  /// device comes back online after an absence.
  Future<void> recordLastSystemEventId(String eventId) async {
    await _db.syncState.set(SyncStateKeys.lastSystemEventId, eventId);
  }

  /// Returns the id of the last successfully processed system event,
  /// or `null` if none has been recorded yet.
  Future<String?> getLastSystemEventId() {
    return _db.syncState.get(SyncStateKeys.lastSystemEventId);
  }

  // ---------------------------------------------------------------------------
  // Activity
  // ---------------------------------------------------------------------------

  /// Records that the user opened the app. Updates the
  /// [SyncStateKeys.lastUserOpenAt] bookkeeping value.
  Future<void> recordUserOpen({DateTime? at}) async {
    await _db.syncState.setInt(
      SyncStateKeys.lastUserOpenAt,
      (at ?? DateTime.now()).millisecondsSinceEpoch,
    );
  }
}
