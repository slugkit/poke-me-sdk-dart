/// poke-me SDK — channels surface (v1 consumer model).
///
/// The join-key / routing-key subscription layer on top of the core SDK:
/// the [Channel] model, channel storage, the channel-centric device DTOs,
/// and the [Subscriber] orchestrator. Re-exports `package:pokeme/pokeme.dart`,
/// so a channels consumer imports this barrel alone.
///
/// A BYOA identity/unicast consumer does **not** need this layer — it depends
/// on the core barrel directly.
library;

export 'pokeme.dart';

export 'src/models/channel.dart';

export 'src/storage/channels_dao.dart';

export 'src/api/channel_api_types.dart';

export 'src/subscriber/subscriber.dart';
