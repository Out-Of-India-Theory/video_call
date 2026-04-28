/// Reasons a call screen can fail to start.
enum OitVideoCallErrorCode {
  /// [OitVideoCall.init] was not called before [OitVideoCall.callScreen].
  notInitialized,

  /// User denied camera or microphone permission.
  permissionDenied,

  /// The backend has not created a call with the given id yet.
  callNotFound,

  /// The configured `tokenProvider` threw or returned an invalid token.
  tokenFetchFailed,

  /// Stream Video failed to join the call (network, auth, or server error).
  joinFailed,

  /// Catch-all for unexpected failures.
  unknown,
}

/// Thrown by [OitVideoCall] when an internal operation fails irrecoverably.
///
/// In v1 these never escape the public API — the call screen renders an
/// in-screen error UI instead. The type is provided for future use.
class OitVideoCallException implements Exception {
  const OitVideoCallException({
    required this.code,
    required this.message,
    this.cause,
  });

  final OitVideoCallErrorCode code;
  final String message;
  final Object? cause;

  @override
  String toString() => 'OitVideoCallException(${code.name}): $message';
}
