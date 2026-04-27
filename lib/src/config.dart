import 'models/video_user.dart';

typedef TokenProvider = Future<String> Function();

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
