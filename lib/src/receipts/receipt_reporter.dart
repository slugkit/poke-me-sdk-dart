import 'dart:async';
import 'dart:collection';

import '../api/poke_api_client.dart';
import '../api/receipt_api_types.dart';
import '../log.dart';

/// Buffers delivery receipts and reports them in batches.
///
/// Receipts are the only way anyone learns what became of a notification —
/// APNs and Web Push have no receipts, and FCM's live in the publisher's own
/// Firebase project — but they arrive at fan-out volume, on the end-user's
/// battery and data. So the reporting is shaped entirely around not being
/// expensive:
///
/// - **Batched, not streamed.** A receipt joins a buffer and a short debounce
///   coalesces the burst an app-resume produces into one request. Sixty-four
///   per request, which is the backend's cap.
/// - **Retried once, then dropped.** The endpoint is idempotent per
///   (notification, state), so a retry costs nothing — and a receipt is not
///   worth a durable queue. A lost one is a receipt that never happened, which
///   the backend already treats as proving nothing.
/// - **Stops when told.** A `receipts_enabled: false` response means the
///   publisher's plan does not include receipts. That will not change by
///   retrying, so this stops for the rest of the process rather than having a
///   whole fleet of devices poll a billing decision.
/// - **Bounded.** A device that cannot reach the network does not accumulate
///   receipts for ever; past [maxBuffered] the oldest are dropped.
///
/// Reports made before the device has registered are dropped: a receipt is
/// addressed by the device token, and without one there is nothing to report
/// as.
class ReceiptReporter {
  ReceiptReporter({
    required PokeApiClient api,
    required Future<String?> Function() deviceToken,
    this.debounce = const Duration(seconds: 2),
    this.maxBuffered = 512,
  })  : _api = api,
        _deviceToken = deviceToken;

  /// The backend's per-request cap. A larger batch is refused rather than
  /// truncated, so this is split against rather than sent and hoped for.
  static const int maxBatch = 64;

  final PokeApiClient _api;
  final Future<String?> Function() _deviceToken;

  /// How long to wait for more receipts before sending. The burst an app-resume
  /// produces arrives within a few frames of itself, so a short wait turns many
  /// requests into one.
  final Duration debounce;

  /// Ceiling on unsent receipts. Past it the oldest are dropped — a device
  /// that has been offline for a day has newer observations worth more than its
  /// oldest ones, and neither is worth unbounded memory.
  final int maxBuffered;

  final Queue<Receipt> _buffer = Queue<Receipt>();
  final Set<String> _buffered = <String>{};
  Timer? _timer;
  bool _flushing = false;
  bool _flushAgain = false;
  bool _disabled = false;
  bool _closed = false;

  /// Whether reporting has been switched off by the backend for this process.
  /// Diagnostic — a host that shows its own telemetry state can read it.
  bool get disabled => _disabled;

  /// Number of receipts waiting to be sent. Diagnostic.
  int get pending => _buffer.length;

  /// Buffers one observation and schedules a flush.
  ///
  /// Duplicates within the buffer are dropped: the backend is idempotent on
  /// the same pair anyway, so not carrying it twice is simply cheaper.
  void report(String notificationId, ReceiptState state) {
    if (_disabled || _closed || notificationId.isEmpty) return;

    final receipt = Receipt(notificationId: notificationId, state: state);
    if (!_buffered.add(receipt.key)) return;
    _buffer.addLast(receipt);

    while (_buffer.length > maxBuffered) {
      final dropped = _buffer.removeFirst();
      _buffered.remove(dropped.key);
      pokeLog('receipt buffer full — dropped ${dropped.key}',
          level: PokeLogLevel.warning);
    }

    _timer ??= Timer(debounce, () {
      _timer = null;
      unawaited(flush());
    });
  }

  /// Sends everything buffered now, rather than waiting out the debounce.
  ///
  /// Call it when the app goes to the background or is about to be suspended —
  /// that is the moment the buffer is most likely to be lost. Safe to call at
  /// any time, and safe to call concurrently: a flush already in progress
  /// simply runs again afterwards for whatever arrived meanwhile.
  Future<void> flush() async {
    if (_disabled || _buffer.isEmpty) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }

    _timer?.cancel();
    _timer = null;
    _flushing = true;
    try {
      final token = await _deviceToken();
      if (token == null || token.isEmpty) {
        // Nothing to report *as*. These pushes were addressed to a device that,
        // as far as local state knows, does not exist — holding them would mean
        // holding them for ever.
        _discardAll('no device token');
        return;
      }

      while (_buffer.isNotEmpty && !_disabled) {
        final batch = <Receipt>[];
        while (batch.length < maxBatch && _buffer.isNotEmpty) {
          batch.add(_buffer.removeFirst());
        }
        for (final receipt in batch) {
          _buffered.remove(receipt.key);
        }
        await _send(batch);
      }
    } finally {
      _flushing = false;
      if (_flushAgain) {
        _flushAgain = false;
        if (_buffer.isNotEmpty) unawaited(flush());
      }
    }
  }

  /// One batch, with exactly one retry.
  ///
  /// The endpoint is idempotent, so the retry cannot double-count; and a
  /// receipt is not worth more than that, so the second failure drops it.
  Future<void> _send(List<Receipt> batch) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final token = await _deviceToken();
        if (token == null || token.isEmpty) return;
        final response =
            await _api.reportReceipts(deviceToken: token, receipts: batch);
        if (!response.receiptsEnabled) {
          // Not a failure — an answer. The publisher's plan does not include
          // receipts, and no amount of retrying will change that.
          _disable();
        }
        return;
      } catch (e) {
        if (attempt == 2) {
          pokeLog('dropped ${batch.length} receipt(s) after a retry: $e',
              error: e, level: PokeLogLevel.warning);
          return;
        }
      }
    }
  }

  void _disable() {
    _disabled = true;
    pokeLog('receipts are not enabled for this app — reporting stopped',
        level: PokeLogLevel.info);
    _discardAll('receipts disabled');
  }

  void _discardAll(String reason) {
    if (_buffer.isEmpty) return;
    pokeLog('discarded ${_buffer.length} buffered receipt(s): $reason',
        level: PokeLogLevel.info);
    _buffer.clear();
    _buffered.clear();
  }

  /// Stops accepting receipts and makes one last attempt to send what is
  /// buffered. Failures here are swallowed — the instance is going away and
  /// there is nobody left to tell.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    try {
      await flush();
    } catch (_) {
      // Best effort by construction.
    }
    _closed = true;
    _buffer.clear();
    _buffered.clear();
  }
}
