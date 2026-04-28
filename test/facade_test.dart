import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/facade.dart';
import 'package:oit_video_call/src/models/video_user.dart';

void main() {
  setUp(() async {
    // Ensure a clean slate between tests.
    await OitVideoCall.reset();
  });

  group('OitVideoCall lifecycle', () {
    test('isInitialized is false before init', () {
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('isInitialized becomes true after init', () {
      OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });

    test('reset clears initialization', () async {
      OitVideoCall.init(
        apiKey: 'key',
        user: const VideoUser(id: 'u1', name: 'Foo'),
        tokenProvider: () async => 'jwt',
      );
      await OitVideoCall.reset();
      expect(OitVideoCall.isInitialized, isFalse);
    });

    test('init can be called twice (idempotent replace)', () {
      OitVideoCall.init(
        apiKey: 'k1',
        user: const VideoUser(id: 'u1', name: 'A'),
        tokenProvider: () async => 't1',
      );
      OitVideoCall.init(
        apiKey: 'k2',
        user: const VideoUser(id: 'u2', name: 'B'),
        tokenProvider: () async => 't2',
      );
      expect(OitVideoCall.isInitialized, isTrue);
    });
  });
}
