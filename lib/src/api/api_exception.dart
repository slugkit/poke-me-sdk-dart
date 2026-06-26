/// Thrown by [PokeApiClient] when a request fails.
///
/// Wraps both transport-level failures (no response, timeout, DNS) and
/// HTTP error responses (4xx / 5xx). For HTTP errors, [statusCode] is
/// the response status and [problemType] / [title] / [detail] are
/// extracted from the RFC 7807 `application/problem+json` body when
/// present.
class PokeApiException implements Exception {
  const PokeApiException({
    required this.message,
    this.statusCode,
    this.problemType,
    this.title,
    this.detail,
    this.cause,
  });

  /// Short human-readable summary.
  final String message;

  /// HTTP status code, or `null` for transport failures.
  final int? statusCode;

  /// `type` field from the problem+json body — the stable error class URL
  /// clients should match against. Null if the body wasn't problem+json.
  final String? problemType;

  /// `title` field from the problem+json body.
  final String? title;

  /// `detail` field from the problem+json body. Often the most useful
  /// human-readable bit.
  final String? detail;

  /// Underlying cause for transport failures.
  final Object? cause;

  /// True if the error is a transport-level failure (no HTTP response).
  bool get isTransportError => statusCode == null;

  /// True for 4xx responses.
  bool get isClientError => statusCode != null && statusCode! >= 400 && statusCode! < 500;

  /// True for 5xx responses.
  bool get isServerError => statusCode != null && statusCode! >= 500 && statusCode! < 600;

  @override
  String toString() {
    final parts = <String>['PokeApiException'];
    if (statusCode != null) parts.add('HTTP $statusCode');
    parts.add(message);
    if (detail != null) parts.add('— $detail');
    return parts.join(' ');
  }
}
