/// poke-me SDK — core surface.
///
/// The identity/unicast layer every consumer needs: platform push-token
/// retrieval, the HTTP client, incoming-push parsing, and local persistence.
/// A BYOA app (register → identify → receive) depends on this barrel alone.
///
/// The v1 channel/join-key consumer surface (subscribe, channels, the
/// [Subscriber] orchestrator) lives in `package:pokeme/channels.dart`, which
/// re-exports this barrel.
library;

export 'src/push_token_service.dart';
export 'src/apns_token_service.dart';

export 'src/models/message.dart';

export 'src/storage/database.dart';
export 'src/storage/messages_dao.dart';
export 'src/storage/sync_state_dao.dart';

export 'src/store/message_store.dart';
export 'src/store/channel_state_change.dart';

export 'src/receiver/push_payload.dart';
export 'src/receiver/push_receiver.dart';
export 'src/receiver/push_message_channel.dart';
export 'src/receiver/push_service.dart';

export 'src/api/api_exception.dart';
export 'src/api/api_types.dart';
export 'src/api/byoa_api_types.dart';
export 'src/api/poke_api_client.dart';

export 'src/identity/identity_client.dart';

export 'src/poke_error.dart';
export 'src/log.dart' show pokemeLoggingEnabled, PokeLogLevel;

export 'src/poke_me.dart';
