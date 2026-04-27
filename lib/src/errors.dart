enum OitVideoCallErrorCode {
  notInitialized,
  permissionDenied,
  callNotFound,
  tokenFetchFailed,
  joinFailed,
  unknown,
}

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
