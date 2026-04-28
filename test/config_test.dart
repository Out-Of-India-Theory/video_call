import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/config.dart';
import 'package:oit_video_call/src/models/video_user.dart';

void main() {
  test('OitVideoCallConfig holds api key, user, and tokenProvider', () async {
    Future<String> tokenProvider() async => 'jwt-123';

    final config = OitVideoCallConfig(
      apiKey: 'key',
      user: const VideoUser(id: 'u1', name: 'Foo'),
      tokenProvider: tokenProvider,
    );

    expect(config.apiKey, 'key');
    expect(config.user.id, 'u1');
    expect(await config.tokenProvider(), 'jwt-123');
  });
}
