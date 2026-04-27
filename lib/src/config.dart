import 'models/video_user.dart';

/// Asynchronously produces a Stream Video user token.
///
/// Invoked once per [OitVideoCall.callScreen] mount; if your token is
/// short-lived, ensure this returns a fresh JWT each call.
typedef TokenProvider = Future<String> Function();

/// Stored configuration for [OitVideoCall].
///
/// Created internally by [OitVideoCall.init]; not constructed by callers.
class OitVideoCallConfig {
  const OitVideoCallConfig({
    required this.apiKey,
    required this.user,
    required this.tokenProvider,
  });

  final String apiKey;
  final VideoUser user;
  final TokenProvider tokenProvider;
}
