/// An error raised by a [PokeMe] operation, delivered on `PokeMe.errors`.
///
/// The SDK still **throws** from each operation, so awaiting callers can handle
/// failures inline. [PokeError] exists so that errors also surface for
/// **fire-and-forget** calls (e.g. `unawaited(poke.registerOnLaunch(...))`) and
/// can be routed to a host's telemetry (Sentry, logs, a banner) from one place.
class PokeError {
  const PokeError({
    required this.operation,
    required this.error,
    this.stackTrace,
  });

  /// The SDK operation that failed — e.g. `registerOnLaunch`, `identify`,
  /// `unidentify`, `refreshPushToken`, or `receive`.
  final String operation;

  /// The underlying error, typically a `PokeApiException` (HTTP/transport) or a
  /// `PushTokenException` (platform push registration).
  final Object error;

  /// Stack trace captured where the error was caught, when available.
  final StackTrace? stackTrace;

  @override
  String toString() => 'PokeError($operation): $error';
}
