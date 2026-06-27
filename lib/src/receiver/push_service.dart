import 'dart:async';

import '../log.dart';
import 'push_message_channel.dart';
import 'push_payload.dart';

/// Lifecycle-managed entry point for incoming pushes.
///
/// Subscribes to the native incoming-message source on [start], parses each raw
/// payload against the wire envelope (see the poke-me message envelope spec), and
/// re-broadcasts the typed [PushPayload] on [pushes]. A consumer listens to
/// [pushes] to react to a notification (display, navigate, refresh). For a BYOA
/// app, subject-origin alerts arrive here with their [AlertPayload.externalUserId]
/// so the app can correlate and route.
///
/// Payloads that do not conform to the envelope (e.g. a non-poke-me FCM message
/// the host app also receives, or a future generation this SDK can't read) are
/// dropped rather than surfaced.
///
/// The payload source is injectable so the pump is testable without the
/// platform channel. By default it is [PushMessageChannel].
class PushService {
  PushService({Stream<Map<String, dynamic>>? source})
      : _source = source ?? PushMessageChannel().messages;

  final Stream<Map<String, dynamic>> _source;
  final StreamController<PushPayload> _controller =
      StreamController<PushPayload>.broadcast();
  StreamSubscription<Map<String, dynamic>>? _sub;

  /// Broadcast stream of parsed incoming pushes. Multiple listeners are
  /// supported; late subscribers do not receive payloads delivered before they
  /// subscribed.
  Stream<PushPayload> get pushes => _controller.stream;

  /// Begins consuming the source. Idempotent — a second call is a no-op while
  /// already running.
  void start() {
    _sub ??= _source.listen(_onRaw, onError: _controller.addError);
  }

  void _onRaw(Map<String, dynamic> raw) {
    final PushPayload payload;
    try {
      payload = parsePushPayload(raw);
    } on FormatException catch (e) {
      // Not a conformant poke-me push — drop, but log so it isn't invisible.
      pokeLog('dropped non-conformant push payload: ${e.message}',
          error: e, level: PokeLogLevel.warning);
      return;
    }
    if (!_controller.isClosed) _controller.add(payload);
  }

  /// Cancels the source subscription and closes the [pushes] stream. The
  /// service must not be used afterwards.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (!_controller.isClosed) await _controller.close();
  }
}
