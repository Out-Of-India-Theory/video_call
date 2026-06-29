import 'package:flutter_test/flutter_test.dart';
import 'package:oit_video_call/oit_video_call.dart';
import 'package:oit_video_call/src/ring/stream_ring_service.dart';

void main() {
  tearDown(() => StreamRingService.instance.debugActive = false);

  test('isRingingRegistered reflects the service flag', () {
    StreamRingService.instance.debugActive = false;
    expect(OitVideoCall.isRingingRegistered, isFalse);
    StreamRingService.instance.debugActive = true;
    expect(OitVideoCall.isRingingRegistered, isTrue);
  });

  test('StreamRingProviderNames is exported from the barrel', () {
    const names = StreamRingProviderNames(apnVoip: 'a', firebase: 'b');
    expect(names.apnVoip, 'a');
    expect(names.firebase, 'b');
  });
}
