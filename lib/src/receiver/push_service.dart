import 'dart:async';

import '../api/receipt_api_types.dart';
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
///
/// ## Receipt signals
///
/// The native layer tags what it observed with [signalKey]. Two shapes arrive
/// on the same channel:
///
/// - A **payload** — the full envelope, as before, tagged `delivered` (it
///   arrived) or `shown` (the OS presented it in the foreground). Parsed and
///   re-broadcast on [pushes] exactly as it always was.
/// - A **bare signal** — `{_pokeme_signal, id}` and nothing else, for something
///   that happened to a notification whose payload was already delivered: the
///   OS displayed it, or the user tapped it. Reported and **not** re-broadcast,
///   because it is not a new push and a consumer that saw it once should not
///   see it twice.
///
/// Both feed [onObserved], which is how [ReceiptReporter] learns what to
/// report. A source that sends neither tag still works: an untagged payload is
/// a delivery, which is what every payload was before this existed.
class PushService {
  PushService({
    Stream<Map<String, dynamic>>? source,
    this.onObserved,
  }) : _source = source ?? PushMessageChannel().messages;

  /// Key the native layer tags each event with. Must match the plugin's
  /// Kotlin/Swift constant.
  static const String signalKey = '_pokeme_signal';

  /// Called for every observation, with the notification's id and what was
  /// observed. Wired to the receipt reporter; null when receipts are off.
  final void Function(String notificationId, ReceiptState state)? onObserved;

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
    final signal = _parseSignal(raw[signalKey]);

    // A bare signal: something happened to a notification already delivered.
    // It carries an id and nothing else, so there is no envelope to parse and
    // nothing new to hand a consumer.
    if (signal != null && !raw.containsKey('kind')) {
      final id = raw['id'];
      if (id is String && id.isNotEmpty) {
        onObserved?.call(id, signal);
      }
      return;
    }

    final PushPayload payload;
    try {
      payload = parsePushPayload(raw);
    } on FormatException catch (e) {
      // Not a conformant poke-me push — drop, but log so it isn't invisible.
      pokeLog('dropped non-conformant push payload: ${e.message}',
          error: e, level: PokeLogLevel.warning);
      return;
    }
    // An untagged payload is a delivery — which is what every payload was
    // before signals existed, so an older native layer keeps working.
    onObserved?.call(payload.id, signal ?? ReceiptState.delivered);
    if (!_controller.isClosed) _controller.add(payload);
  }

  /// Reads the native tag. An unknown value is ignored rather than thrown on:
  /// a newer native layer must not be able to break the push pump.
  static ReceiptState? _parseSignal(dynamic value) {
    if (value is! String) return null;
    for (final state in ReceiptState.values) {
      if (state.wireValue == value) return state;
    }
    pokeLog('ignoring unknown receipt signal \'$value\'',
        level: PokeLogLevel.warning);
    return null;
  }

  /// Cancels the source subscription and closes the [pushes] stream. The
  /// service must not be used afterwards.
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    if (!_controller.isClosed) await _controller.close();
  }
}
