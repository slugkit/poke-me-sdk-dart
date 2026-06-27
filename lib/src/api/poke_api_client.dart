import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../log.dart';
import 'api_exception.dart';
import 'api_types.dart';
import 'byoa_api_types.dart';
import 'channel_api_types.dart';

/// HTTP client for the poke-me backend's device-facing endpoints.
///
/// All methods throw [PokeApiException] on failure. Transport-level
/// failures (DNS, timeout) come through as exceptions with no
/// `statusCode`; HTTP error responses are decoded from RFC 7807
/// `application/problem+json` bodies when the server provides one.
class PokeApiClient {
  PokeApiClient({
    required this.baseUrl,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 15),
  }) : _client = httpClient ?? http.Client();

  /// Base URL of the API root, **without** a trailing slash. The client
  /// appends `/api/v1/...` to this for each request.
  final Uri baseUrl;

  /// Per-request timeout. Applied to every call individually.
  final Duration timeout;

  final http.Client _client;

  /// Closes the underlying HTTP client. Call when the client is no longer
  /// needed (typically at app shutdown).
  void close() => _client.close();

  // ---------------------------------------------------------------------------
  // BYOA — device registration & identity (identity / unicast axis)
  // ---------------------------------------------------------------------------

  /// `POST /api/v1/apps/{appId}/devices` — register an anonymous install for a
  /// BYOA app, authenticated by the publishable client key (`ck_…`) embedded
  /// in the binary. Returns the device id and the one-time device token
  /// (`dt_…`) the SDK stores locally for subsequent `/devices/me/*` calls.
  ///
  /// **Planned contract** — this endpoint is not yet implemented backend-side
  /// (see the poke-me BYOA model). The shape here matches the design
  /// sketch; it may tighten before the endpoint ships.
  Future<RegisterDeviceResponse> registerDevice({
    required String appId,
    required String clientKey,
    required RegisterDeviceRequest request,
  }) async {
    final body = await _post(
      path: '/api/v1/apps/$appId/devices',
      body: request.toJson(),
      extraHeaders: {'x-client-key': clientKey},
    );
    return RegisterDeviceResponse.fromJson(body);
  }

  /// `POST /api/v1/devices/me/identify` — bind the calling device to a subject
  /// keyed by `(app_id, external_user_id)`, creating the subject on first use.
  /// Idempotent per external id; returns the subject id.
  Future<IdentifyResponse> identify({
    required String deviceToken,
    required IdentifyRequest request,
  }) async {
    final body = await _post(
      path: '/api/v1/devices/me/identify',
      deviceToken: deviceToken,
      body: request.toJson(),
    );
    return IdentifyResponse.fromJson(body);
  }

  /// `POST /api/v1/devices/me/unidentify` — clear the device→subject binding
  /// on logout. The device's app binding is kept; only the user is cleared.
  Future<void> unidentify({required String deviceToken}) async {
    await _post(
      path: '/api/v1/devices/me/unidentify',
      deviceToken: deviceToken,
    );
  }

  // ---------------------------------------------------------------------------
  // Subscribe (no device token yet)
  // ---------------------------------------------------------------------------

  /// `POST /api/v1/subscribe/by-key` — exchanges a join key for a
  /// device subscription on the encoded channel.
  Future<SubscribeResponse> subscribeByJoinKey(
    SubscribeByKeyRequest request,
  ) async {
    final body = await _post(
      path: '/api/v1/subscribe/by-key',
      body: request.toJson(),
    );
    return SubscribeResponse.fromJson(body);
  }

  /// `POST /api/v1/subscribe/{full_routing_key}` — public subscribe
  /// without a join key. The channel must be marked `is_public`.
  Future<SubscribeResponse> subscribeByRoutingKey({
    required String routingKey,
    required SubscribeByRoutingKeyRequest request,
  }) async {
    final body = await _post(
      path: '/api/v1/subscribe/$routingKey',
      body: request.toJson(),
    );
    return SubscribeResponse.fromJson(body);
  }

  // ---------------------------------------------------------------------------
  // Device-authenticated endpoints
  // ---------------------------------------------------------------------------

  /// `GET /api/v1/devices/me` — full device row with the list of
  /// current subscriptions inlined.
  ///
  /// This is the only "what does the device have" endpoint that the
  /// backend currently exposes. The richer dedicated endpoints
  /// ([listDeviceChannels], [getEventsSince], [getChannelHistory]) are
  /// described for the poke-me API but not yet implemented backend-side.
  Future<Device> getDevice(String deviceToken) async {
    final body = await _get(
      path: '/api/v1/devices/me',
      deviceToken: deviceToken,
    );
    return Device.fromJson(body);
  }

  /// `GET /api/v1/devices/me/channels` — current subscriptions for the
  /// device authenticated by [deviceToken].
  ///
  /// **Not yet implemented backend-side**.
  /// Until the endpoint ships, prefer [getDevice] which returns the
  /// subscriptions inline as part of the device row.
  Future<List<DeviceChannel>> listDeviceChannels(String deviceToken) async {
    final body = await _get(
      path: '/api/v1/devices/me/channels',
      deviceToken: deviceToken,
    );
    final items = _expectList(body, 'items');
    return items
        .map((e) => DeviceChannel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `GET /api/v1/devices/me/events?since={message_id}` — system events
  /// affecting this device since the cursor. Pass `null` to get
  /// everything from the beginning of time.
  ///
  /// **Not yet implemented backend-side**.
  Future<List<DeviceSystemEvent>> getEventsSince({
    required String deviceToken,
    String? sinceMessageId,
  }) async {
    final query = sinceMessageId == null ? '' : '?since=$sinceMessageId';
    final body = await _get(
      path: '/api/v1/devices/me/events$query',
      deviceToken: deviceToken,
    );
    final items = _expectList(body, 'items');
    return items
        .map((e) => DeviceSystemEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `GET /api/v1/devices/me/channels/{slug}/history` — slug-history
  /// reconciliation for a single channel.
  ///
  /// **Not yet implemented backend-side**.
  Future<List<ChannelHistoryEntry>> getChannelHistory({
    required String deviceToken,
    required String slug,
  }) async {
    final body = await _get(
      path: '/api/v1/devices/me/channels/$slug/history',
      deviceToken: deviceToken,
    );
    final items = _expectList(body, 'items');
    return items
        .map((e) => ChannelHistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `PUT /api/v1/devices/me/push-token` — rotate the platform push
  /// token associated with this device.
  Future<void> updatePushToken({
    required String deviceToken,
    required UpdatePushTokenRequest request,
  }) async {
    await _put(
      path: '/api/v1/devices/me/push-token',
      deviceToken: deviceToken,
      body: request.toJson(),
    );
  }

  /// `DELETE /api/v1/devices/me/subscriptions/{sub_ref}` — unsubscribe
  /// a single channel for this device.
  Future<void> unsubscribe({
    required String deviceToken,
    required String subscriptionRef,
  }) async {
    await _delete(
      path: '/api/v1/devices/me/subscriptions/$subscriptionRef',
      deviceToken: deviceToken,
    );
  }

  /// `DELETE /api/v1/devices/me` — uninstall: revoke all subscriptions
  /// for this device and mark the device row inactive.
  ///
  /// **Not yet implemented backend-side**.
  /// Currently returns 405 Method Not Allowed.
  Future<void> deleteDevice(String deviceToken) async {
    await _delete(
      path: '/api/v1/devices/me',
      deviceToken: deviceToken,
    );
  }

  // ---------------------------------------------------------------------------
  // HTTP plumbing
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _post({
    required String path,
    Map<String, dynamic>? body,
    String? deviceToken,
    Map<String, String>? extraHeaders,
  }) async {
    return _send(
      method: 'POST',
      path: path,
      body: body,
      deviceToken: deviceToken,
      extraHeaders: extraHeaders,
    );
  }

  Future<Map<String, dynamic>> _put({
    required String path,
    required Map<String, dynamic> body,
    String? deviceToken,
  }) async {
    return _send(
      method: 'PUT',
      path: path,
      body: body,
      deviceToken: deviceToken,
    );
  }

  Future<Map<String, dynamic>> _get({
    required String path,
    String? deviceToken,
  }) async {
    return _send(method: 'GET', path: path, deviceToken: deviceToken);
  }

  Future<Map<String, dynamic>> _delete({
    required String path,
    String? deviceToken,
  }) async {
    return _send(method: 'DELETE', path: path, deviceToken: deviceToken);
  }

  Future<Map<String, dynamic>> _send({
    required String method,
    required String path,
    Map<String, dynamic>? body,
    String? deviceToken,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = baseUrl.resolve(path);
    final headers = <String, String>{
      'accept': 'application/json',
      if (body != null) 'content-type': 'application/json',
      if (deviceToken != null) 'authorization': 'Bearer $deviceToken',
      ...?extraHeaders,
    };
    final encoded = body == null ? null : jsonEncode(body);

    http.Response response;
    try {
      final request = http.Request(method, uri)..headers.addAll(headers);
      if (encoded != null) request.body = encoded;
      final streamed = await _client.send(request).timeout(timeout);
      response = await http.Response.fromStream(streamed);
    } on TimeoutException catch (e) {
      final ex = PokeApiException(
        message: 'Request timed out after ${timeout.inSeconds}s',
        cause: e,
      );
      pokeLog('$method $uri — ${ex.message}',
          error: ex, level: PokeLogLevel.error);
      throw ex;
    } catch (e) {
      final ex = PokeApiException(message: 'Network error: $e', cause: e);
      pokeLog('$method $uri — ${ex.message}',
          error: ex, level: PokeLogLevel.error);
      throw ex;
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return const <String, dynamic>{};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) return decoded;
        // Some endpoints might return a top-level array; wrap it for
        // uniform handling.
        return {'items': decoded};
      } on FormatException catch (e) {
        throw PokeApiException(
          message: 'Malformed JSON response',
          statusCode: response.statusCode,
          cause: e,
        );
      }
    }

    final ex = _decodeError(response);
    pokeLog(
      '$method ${uri.path} → HTTP ${response.statusCode}: ${ex.detail ?? ex.message}',
      error: ex,
      level: PokeLogLevel.error,
    );
    throw ex;
  }

  PokeApiException _decodeError(http.Response response) {
    final contentType = response.headers['content-type'] ?? '';
    if (contentType.contains('application/problem+json') ||
        contentType.contains('application/json')) {
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) {
          // RFC 7807 fields (the spec).
          final type = decoded['type'] as String?;
          final title = decoded['title'] as String?;
          final detail = decoded['detail'] as String?;

          // Fallback fields used by services that haven't migrated to
          // problem+json yet. userver's default error envelope is
          // {"code","message"}; nginx's auth_request 401 page is
          // {"error":"..."}. Lift the human-readable bit out so it
          // surfaces in the UI instead of a bare "HTTP 401".
          final fallback = _extractFallbackMessage(decoded);

          return PokeApiException(
            message: title ?? fallback ?? 'HTTP ${response.statusCode}',
            statusCode: response.statusCode,
            problemType: type,
            title: title,
            detail: detail ?? fallback,
          );
        }
      } on FormatException {
        // Fall through to a generic error.
      }
    }
    return PokeApiException(
      message: 'HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      detail: response.body.isEmpty ? null : response.body,
    );
  }

  /// Extracts a human-readable message from a non-RFC-7807 error body.
  ///
  /// Handles two shapes seen from the current backend:
  /// - userver default: `{"code":"401","message":"..."}` where the
  ///   `message` value may itself be a JSON-encoded `{"error":"..."}`
  /// - nginx auth_request 401: `{"error":"unauthorized"}`
  String? _extractFallbackMessage(Map<String, dynamic> body) {
    final message = body['message'];
    if (message is String) {
      // userver wraps its inner JSON in a string; try to unwrap.
      try {
        final inner = jsonDecode(message);
        if (inner is Map<String, dynamic> && inner['error'] is String) {
          return inner['error'] as String;
        }
      } on FormatException {
        // Plain string message — return as-is.
      }
      return message;
    }
    final error = body['error'];
    if (error is String) return error;
    return null;
  }

  List<dynamic> _expectList(Map<String, dynamic> body, String key) {
    final value = body[key];
    if (value is List) return value;
    throw PokeApiException(
      message: "Expected a list under '$key' but got ${value.runtimeType}",
    );
  }
}
