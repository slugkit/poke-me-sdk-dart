import 'dart:developer' as developer;

/// Diagnostic log levels, matching `package:logging` / `dart:developer`
/// conventions so they slot into a host app's logging if it forwards them.
class PokeLogLevel {
  const PokeLogLevel._();

  /// Routine information (e.g. a dropped non-conformant push).
  static const int info = 800;

  /// Something went wrong but the SDK recovered or surfaced an exception.
  static const int warning = 900;

  /// A service error (HTTP 4xx/5xx or transport failure).
  static const int error = 1000;
}

/// When false, the SDK emits no [pokeLog] output. Enabled by default so
/// failures are visible during development; set to false in production builds
/// that route errors elsewhere (e.g. via try/catch around awaited calls).
///
/// Exposed through `package:pokeme/pokeme.dart` as [pokemeLoggingEnabled].
bool pokemeLoggingEnabled = true;

/// Emits a structured SDK log line under the `pokeme` name via
/// `dart:developer`, visible in the console and DevTools. No-op when
/// [pokemeLoggingEnabled] is false.
///
/// This never replaces throwing — service errors are still raised to callers;
/// logging exists so failures from fire-and-forget operations don't vanish.
void pokeLog(
  String message, {
  Object? error,
  StackTrace? stackTrace,
  int level = PokeLogLevel.info,
}) {
  if (!pokemeLoggingEnabled) return;
  developer.log(
    message,
    name: 'pokeme',
    level: level,
    error: error,
    stackTrace: stackTrace,
  );
}
