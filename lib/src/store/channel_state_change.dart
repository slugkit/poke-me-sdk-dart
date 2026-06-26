import '../models/channel.dart';

/// Notification emitted by [MessageStore] whenever the local channel state
/// changes.
///
/// Subscribers can listen to [MessageStore.channelChanges] to react to
/// renames, slug rotations, deletions, and revocations. App-level features
/// that key data on channel slug (e.g. user-defined folders, custom display
/// orders) use this stream to keep their own indices in sync without having
/// to poll the SDK.
///
/// The stream is **broadcast** — multiple subscribers are supported. Events
/// fire after the underlying SQLite write commits successfully; failed
/// operations do not emit.
sealed class ChannelStateChange {
  const ChannelStateChange();
}

/// A new channel subscription was added via [MessageStore.joinChannel].
final class ChannelJoinedEvent extends ChannelStateChange {
  const ChannelJoinedEvent({required this.channel});

  final Channel channel;
}

/// A channel was renamed via [MessageStore.handleChannelRenamed].
/// The slug is unchanged.
final class ChannelRenamedEvent extends ChannelStateChange {
  const ChannelRenamedEvent({required this.slug, required this.newName});

  final String slug;
  final String newName;
}

/// A channel's slug was rotated via [MessageStore.handleChannelSlugChanged].
/// The channel name and any messages remain attached, but the slug is now
/// [newSlug]. App-level data keyed by the old slug should be migrated.
final class ChannelSlugChangedEvent extends ChannelStateChange {
  const ChannelSlugChangedEvent({
    required this.oldSlug,
    required this.newSlug,
  });

  final String oldSlug;
  final String newSlug;
}

/// A channel was deleted server-side via
/// [MessageStore.handleChannelDeleted]. Messages have been wiped; the
/// channel row is in tombstone state pending user acknowledgement.
final class ChannelDeletedEvent extends ChannelStateChange {
  const ChannelDeletedEvent({required this.slug});

  final String slug;
}

/// The device's subscription was revoked via
/// [MessageStore.handleSubscriptionRevoked]. Same effect as deletion but
/// distinct for telemetry.
final class ChannelRevokedEvent extends ChannelStateChange {
  const ChannelRevokedEvent({required this.slug});

  final String slug;
}

/// A channel row was hard-deleted by the tombstone sweep in
/// [MessageStore.runMaintenance]. Subscribers can use this as a final
/// cleanup signal — by the time this fires, no further events for [slug]
/// will arrive (until the user joins a new channel with the same slug).
final class ChannelPurgedEvent extends ChannelStateChange {
  const ChannelPurgedEvent({required this.slug});

  final String slug;
}
