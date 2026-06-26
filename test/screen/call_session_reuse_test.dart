import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';
import 'package:oit_video_call/src/screen/call_session.dart';
import 'package:stream_video_flutter/stream_video_flutter.dart';

void main() {
  setUp(() => StreamRingService.instance.debugActive = false);
  tearDown(() => StreamRingService.instance.debugActive = false);

  test('connect() does not construct StreamVideo when ring active', () async {
    StreamRingService.instance.debugActive = true;
    final session = StreamCallSession();
    // If connect tried to construct StreamVideo, native bindings would throw
    // in the test VM. The reuse path must NOT construct, so this completes.
    await session.connect(
      apiKey: 'k',
      user: User.regular(userId: 'u'),
      token: 't',
    );
  });

  test('dispose() does not reset the SDK when ring active', () async {
    StreamRingService.instance.debugActive = true;
    final session = StreamCallSession();
    await session.dispose();
  });
}
